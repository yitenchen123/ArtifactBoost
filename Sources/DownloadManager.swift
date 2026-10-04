import Foundation
import UIKit

@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case idle
        case resolving
        case downloading(DownloadProgress)
        case finished(URL)
        case failed(String)
    }

    /// 以下载项 id 为键：状态 / 通道说明 / 下载项本体
    @Published var states: [String: State] = [:]
    @Published var routeSummary: [String: String] = [:]
    @Published private(set) var order: [String] = []
    @Published private(set) var items: [String: DownloadItem] = [:]

    private var engines: [String: DownloadEngine] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]

    /// 未完成任务的落盘：进程被杀后靠它自动续下
    private let taskStore = DownloadTaskStore()

    let session: SessionManager

    init(session: SessionManager) {
        self.session = session
    }

    // MARK: - 查询

    func state(for item: DownloadItem) -> State {
        states[item.id] ?? .idle
    }

    var activeCount: Int {
        states.values.filter {
            if case .downloading = $0 { return true }
            if case .resolving = $0 { return true }
            return false
        }.count
    }

    var orderedItems: [DownloadItem] {
        order.compactMap { items[$0] }
    }

    // MARK: - 操作

    func start(_ item: DownloadItem, settings: AccelerationSettings) {
        guard let client = session.client else { return }
        switch state(for: item) {
        case .resolving, .downloading:
            return
        default:
            break
        }

        if items[item.id] == nil {
            order.insert(item.id, at: 0)
        }
        items[item.id] = item
        states[item.id] = .resolving
        routeSummary[item.id] = nil
        // 先落盘再开工：中途进程被杀，下次启动能按这份记录续下
        taskStore.save(TaskRecord(item: item, settings: settings))

        let engine = DownloadEngine()
        engines[item.id] = engine
        beginBackgroundTask(for: item.id)

        let itemID = item.id
        let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch self.states[itemID] {
                case .resolving?, .downloading?, .none:
                    self.states[itemID] = .downloading(progress)
                default:
                    break
                }
            }
        }

        tasks[item.id] = Task {
            do {
                let url = try await performDownload(item: item,
                                                    client: client,
                                                    engine: engine,
                                                    settings: settings,
                                                    onProgress: onProgress)
                states[item.id] = .finished(url)
                // 下完了：清掉落盘记录，避免重启后复活
                taskStore.remove(id: item.id)
            } catch {
                if Self.isCancellation(error) {
                    states[item.id] = .idle
                } else {
                    states[item.id] = .failed(error.localizedDescription)
                    // 失败不自动续下：清记录，用户手动重试时会重新落盘
                    taskStore.remove(id: item.id)
                }
            }
            engines[item.id] = nil
            tasks[item.id] = nil
            endBackgroundTask(for: item.id)
        }
    }

    /// 取消下载。
    ///
    /// 三件事必须一起做，否则会出现「点了取消还要等很久才停」：
    ///  1. `engine.cancel()` —— 掐断在飞的 URLSessionDataTask，让挂起的 await 立刻返回；
    ///  2. `Task.cancel()` —— 唤醒下载协程本身；
    ///  3. 立刻把状态改回 `.idle` —— 用户点完马上看到反馈，而不是等网络层慢慢收尾。
    func cancel(_ item: DownloadItem) {
        engines[item.id]?.cancel()
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        engines[item.id] = nil
        endBackgroundTask(for: item.id)
        // 用户主动取消：清记录，不恢复
        taskStore.remove(id: item.id)
        states[item.id] = .idle
    }

    func remove(_ item: DownloadItem) {
        engines[item.id]?.cancel()
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        engines[item.id] = nil
        endBackgroundTask(for: item.id)
        taskStore.remove(id: item.id)
        states[item.id] = nil
        routeSummary[item.id] = nil
        items[item.id] = nil
        order.removeAll { $0 == item.id }
    }

    func clearFinished() {
        for id in order {
            guard let item = items[id] else { continue }
            switch states[id] {
            case .finished, .failed, .none:
                remove(item)
            default:
                continue
            }
        }
    }

    /// 后台恢复：进程重启后把上次没下完的任务自动续上。
    ///
    /// 必须在登录态恢复之后调（无 client 时直接返回，记录保留待下次启动）。
    /// 签名地址有时效，恢复即重新解析，不沿用死时的旧地址。
    ///
    /// - Returns: 实际重新入队的任务数。
    @discardableResult
    func restorePending() -> Int {
        let records = taskStore.loadAll()
        guard !records.isEmpty, session.client != nil else { return 0 }
        for record in records {
            start(record.item, settings: record.settings)
        }
        return records.count
    }

    // MARK: - 下载主流程

    /// 解析签名地址单次限时 30s（与安卓端同步），重试前退避 1.5s
    static let resolveTimeout: TimeInterval = 30
    static let resolveRetryDelay: TimeInterval = 1.5

    /// 解析签名地址 → 选通道 → 下载。签名地址有时效，整体失败后重新解析再试一次。
    ///
    /// 解析阶段永远直连 api.github.com（通道只影响下载阶段），弱网下单次可达 30s；
    /// 这里做了三件事避免“一直转”：单次 30s 限时、重试前退避 1.5s、重试时刷出明确文案。
    private func performDownload(item: DownloadItem,
                                 client: GitHubClient,
                                 engine: DownloadEngine,
                                 settings: AccelerationSettings,
                                 onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        var lastError: Error = DownloadError.badResponse
        for attempt in 0..<2 {
            do {
                if attempt > 0 {
                    // 让用户看出来是在重试，而不是卡死
                    routeSummary[item.id] = "正在解析下载地址（重试 \(attempt)/1）…"
                    try await Task.sleep(nanoseconds: UInt64(Self.resolveRetryDelay * 1_000_000_000))
                }
                let signed = try await Self.resolveWithTimeout(client: client, source: item.source)
                // 解析成功：清掉可能存在的“重试…”文案，后面下载会刷自己的说明
                routeSummary[item.id] = nil
                return try await run(item: item,
                                     engine: engine,
                                     signedURL: signed,
                                     settings: settings,
                                     onProgress: onProgress)
            } catch {
                if !Self.shouldRetry(error) { throw error }
                lastError = error
                if attempt == 0 { states[item.id] = .resolving }
            }
        }
        throw lastError
    }

    /// 30s 内拿不到签名地址就抛 requestTimeout（中文文案见 GitHubError）。
    /// 取消优先透出 CancellationError，不会被包装成超时再白跑一次重试。
    private static func resolveWithTimeout(client: GitHubClient, source: DownloadSource) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask { try await client.resolveDownloadURL(for: source) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(resolveTimeout * 1_000_000_000))
                throw GitHubError.requestTimeout
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return first
        }
    }

    private func run(item: DownloadItem,
                     engine: DownloadEngine,
                     signedURL: URL,
                     settings: AccelerationSettings,
                     onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        // ghfast 这类镜像只认 github.com 原始地址，套签名地址会被拒，
        // 所以「这条通道该套哪个 URL」必须逐条算，不能统一用 signedURL。
        let githubURL = item.source.ghfastEligibleURL.flatMap { URL(string: $0) }

        // 无测速：候选通道直接全部并行，初始权重均等，
        // 引擎下载中按实时吞吐动态调整分配。
        let candidates = settings.candidateRoutes(isPrivateRepo: item.isPrivate, githubURL: githubURL)
        let plan = candidates.map { ScoredRoute(route: $0, speed: 1) }
        let note = (item.isPrivate && settings.mode == .smart)
            ? "直连（私有仓库不走镜像）"
            : Self.describe(plan)

        let connections = settings.clampedConnections
        // 逐条通道算出它该用的 URL：ghfast 用 github.com 地址，其余用签名地址
        let routeURLs = Self.resolveRouteURLs(plan, signedURL: signedURL, githubURL: githubURL)

        do {
            let result = try await engine.download(routeURLs: routeURLs,
                                                   routes: plan,
                                                   fileName: item.fileName,
                                                   connections: connections,
                                                   allowChunking: item.source.supportsChunkedDownload,
                                                   progress: onProgress)
            routeSummary[item.id] = "\(note) · 平均 \(formatSpeed(result.averageSpeed))"
            return result.fileURL
        } catch {
            // 通道可能失效/被限流，整体回退直连再试一次
            guard Self.shouldRetry(error), plan.contains(where: { !$0.route.isDirect }) else { throw error }
            let result = try await engine.download(routeURLs: [signedURL],
                                                   routes: [ScoredRoute(route: .direct, speed: 1)],
                                                   fileName: item.fileName,
                                                   connections: connections,
                                                   allowChunking: item.source.supportsChunkedDownload,
                                                   progress: onProgress)
            routeSummary[item.id] = "直连（\(note) 失败已回退） · 平均 \(formatSpeed(result.averageSpeed))"
            return result.fileURL
        }
    }

    /// 给每条通道算出实际请求的 URL。
    ///
    /// - `.githubOnly`（ghfast）：套 `https://github.com/...` 稳定地址；
    ///   若这次下载没有稳定地址，就把这条通道剔掉（避免送上去必然 400）。
    /// - 其余通道：套已签名的真实地址（原来的行为）。
    private static func resolveRouteURLs(_ plan: [ScoredRoute],
                                         signedURL: URL,
                                         githubURL: URL?) -> [URL] {
        let urls = plan.compactMap { scored -> URL? in
            switch scored.route.scope {
            case .any:
                return scored.route.apply(to: signedURL)
            case .githubOnly:
                guard let githubURL else { return nil }
                return scored.route.apply(to: githubURL)
            }
        }
        // 全被剔掉（理论上不会，因为直连永远是 .any）时至少保底直连
        return urls.isEmpty ? [signedURL] : urls
    }

    /// 通道描述，例如「多通道 gh-proxy.com + slink.ltd」
    private static func describe(_ plan: [ScoredRoute]) -> String {
        let names = plan.map { $0.route.isDirect ? "直连" : $0.route.name }
        return plan.count > 1 ? "多通道 " + names.joined(separator: " + ") : names[0]
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? DownloadError) == .cancelled { return true }
        return (error as NSError).code == NSURLErrorCancelled
    }

    /// 只有网络类错误才值得重试；权限、产物已删除等错误直接抛出
    private static func shouldRetry(_ error: Error) -> Bool {
        if isCancellation(error) { return false }
        guard let ghError = error as? GitHubError else { return true }
        switch ghError {
        case .badResponse, .requestTimeout:
            return true
        case .http(let code, _):
            return code >= 500 || code == 429
        case .artifactExpired, .downloadURLNotFound, .badURL:
            return false
        }
    }

    // MARK: - 后台任务申请，避免切到后台后下载被立即挂起

    private func beginBackgroundTask(for id: String) {
        let task = UIApplication.shared.beginBackgroundTask(withName: "ArtifactBoost-\(id)") { [weak self] in
            Task { @MainActor [weak self] in
                self?.endBackgroundTask(for: id)
            }
        }
        if task != .invalid {
            backgroundTasks[id] = task
        }
    }

    private func endBackgroundTask(for id: String) {
        guard let task = backgroundTasks.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }
}