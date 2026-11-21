import Foundation
import UIKit

@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case idle
        case resolving
        case downloading(DownloadProgress)
        /// 用户主动暂停：半成品与续传账本都保留，点「继续」从断点接着下
        case paused(DownloadProgress)
        /// 达到「同时下载数」上限，排队等前面的完成
        case queued
        case finished(URL)
        case failed(String)
    }

    /// 以下载项 id 为键：状态 / 通道说明 / 下载项本体
    @Published var states: [String: State] = [:]
    @Published var routeSummary: [String: String] = [:]
    @Published private(set) var order: [String] = []
    @Published private(set) var items: [String: DownloadItem] = [:]
    /// 最近一帧进度：暂停时用它渲染「已下 X%，点继续接着下」
    @Published private(set) var lastProgress: [String: DownloadProgress] = [:]

    private var engines: [String: DownloadEngine] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var backgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    /// 每次 start 递增：暂停后立刻「继续」时，旧任务的收尾不能误删新一代的引擎/任务引用
    private var generations: [String: Int] = [:]

    /// 下载队列：超过「同时下载数」的任务排在这里，前面的完成 / 取消 / 暂停后自动补位
    private var pending: [(id: String, settings: AccelerationSettings)] = []

    /// 未完成任务的落盘：进程被杀后靠它自动续下
    private let taskStore = DownloadTaskStore()

    /// 通道探测缓存（按 host 复用 5 分钟），解决「每次下载都要重新试一遍死镜像」
    private let probeCache = RouteProbeCache.shared

    let session: SessionManager

    init(session: SessionManager) {
        self.session = session
        // 清掉 7 天都没动静的续传残留，避免半成品永久占着磁盘
        ResumeStore.shared.prune()
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
    var queuedCount: Int {
        states.values.filter {
            if case .queued = $0 { return true }
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
        case .resolving, .downloading, .queued:
            return
        default:
            break
        }

        // 达到「同时下载数」上限：排队，等前面的下完自动开始（IDM 的下载队列）
        if activeCount >= settings.clampedMaxConcurrent {
            if items[item.id] == nil {
                order.insert(item.id, at: 0)
            }
            items[item.id] = item
            states[item.id] = .queued
            routeSummary[item.id] = "排队中 · 等待前面的下载完成"
            taskStore.save(TaskRecord(item: item, settings: settings))
            if !pending.contains(where: { $0.id == item.id }) {
                pending.append((item.id, settings))
            }
            return
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
        let generation = (generations[item.id] ?? 0) + 1
        generations[item.id] = generation
        beginBackgroundTask(for: item.id)

        let itemID = item.id
        let onProgress: @Sendable (DownloadProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastProgress[itemID] = progress
                switch self.states[itemID] {
                case .resolving?, .downloading?, .paused?, .none:
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
                lastProgress[item.id] = nil
                // 下完了：清掉落盘记录，避免重启后复活
                taskStore.remove(id: item.id)
            } catch {
                if Self.isCancellation(error) {
                    // 取消有两种：用户点了暂停（状态已由 pause 设好，别覆盖），
                    // 以及用户点了取消（pause 之外的分支）。这里只在还是「下载中」时回 idle。
                    if case .paused? = states[item.id] {
                        // 暂停状态保持不动
                    } else {
                        states[item.id] = .idle
                    }
                } else {
                    states[item.id] = .failed(error.localizedDescription)
                    // 失败不自动续下：清记录，用户手动重试时会重新落盘
                    taskStore.remove(id: item.id)
                }
            }
            // 只有「还是这一代任务」才清理；否则会把用户刚点「继续」新建的那一代误删
            if generations[item.id] == generation {
                generations[item.id] = nil
                engines[item.id] = nil
                tasks[item.id] = nil
                endBackgroundTask(for: item.id)
            }
            // 让出一个名额：队列里的下一个自动开始
            drainQueue()
        }
    }

    /// 从队列里补一个任务进来（一次只补一个：每次调用都对应一个被让出的名额）
    private func drainQueue() {
        guard let index = pending.firstIndex(where: { entry in
            guard let item = items[entry.id] else { return false }
            if case .queued = state(for: item) { return true }
            return false
        }) else { return }
        let entry = pending.remove(at: index)
        guard let item = items[entry.id] else { return }
        // start 会把状态推到 resolving；先复位，免得被自己的 .queued 守卫挡回来
        states[entry.id] = .idle
        start(item, settings: entry.settings)
    }

    private func removeFromQueue(_ id: String) {
        pending.removeAll { $0.id == id }
    }

    /// 暂停：掐断连接但**保留**半成品与续传账本，点「继续」从断点接着下。
    ///
    /// 与 `cancel` 的区别就在这里 —— 取消是「我不要了」（连同半成品一起删），
    /// 暂停是「等会儿再下」（几百 MB 不能白下）。
    func pause(_ item: DownloadItem) {
        guard engines[item.id] != nil else { return }
        let snapshot = lastProgress[item.id] ?? DownloadProgress()
        states[item.id] = .paused(snapshot)
        engines[item.id]?.cancel()
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        engines[item.id] = nil
        endBackgroundTask(for: item.id)
        // 任务记录保留：进程重启后仍能自动续上
        routeSummary[item.id] = nil
        removeFromQueue(item.id)
        drainQueue()
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
        // 用户主动取消：连同半成品一起清掉，不恢复
        taskStore.remove(id: item.id)
        ResumeStore.shared.discard(key: item.id)
        lastProgress[item.id] = nil
        states[item.id] = .idle
        removeFromQueue(item.id)
        drainQueue()
    }

    func remove(_ item: DownloadItem) {
        engines[item.id]?.cancel()
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        engines[item.id] = nil
        endBackgroundTask(for: item.id)
        taskStore.remove(id: item.id)
        ResumeStore.shared.discard(key: item.id)
        lastProgress[item.id] = nil
        states[item.id] = nil
        removeFromQueue(item.id)
        drainQueue()
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

    /// IDM 式的下载流程：**没有「解析地址」这一阶段**。
    ///
    /// 第一个带 Range 的请求直接打到「github.com 稳定地址 / codeload / api.github.com」，
    /// 由引擎在同一个往返里完成：跟随 302 拿到签名地址、读出文件体积、拿回首块数据。
    /// 用户点下去到出速度只差一个 RTT，而不是老实现那样排四段队。
    private func performDownload(item: DownloadItem,
                                 client: GitHubClient,
                                 engine: DownloadEngine,
                                 settings: AccelerationSettings,
                                 onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let request = try makeRequest(item: item, client: client, settings: settings)

        var lastError: Error = DownloadError.badResponse
        for attempt in 0..<2 {
            do {
                if attempt > 0 {
                    routeSummary[item.id] = "网络抖动，正在重试…"
                    try await Task.sleep(nanoseconds: 800_000_000)
                }
                let result = try await engine.download(request, progress: onProgress)
                // 长度对不代表内容对：压缩包再验一次结构/CRC，坏包当场重试而不是留给用户解压时才发现
                if let reason = ArtifactVerifier.verify(result.fileURL) {
                    try? FileManager.default.removeItem(at: result.fileURL)
                    throw DownloadError.verificationFailed(reason)
                }
                routeSummary[item.id] = "\(Self.describe(request.routes)) · 平均 \(formatSpeed(result.averageSpeed))"
                return result.fileURL
            } catch {
                if Self.isCancellation(error) { throw error }
                lastError = error
                if !Self.shouldRetry(error) { throw error }
            }
        }
        throw lastError
    }

    /// 组装引擎输入。**全程零网络请求**：地址是拼出来的，不是问出来的。
    private func makeRequest(item: DownloadItem,
                             client: GitHubClient,
                             settings: AccelerationSettings) throws -> DownloadEngine.Request {
        let start = try client.startURL(for: item.source, isPrivate: item.isPrivate)
        let stableURL = item.source.ghfastEligibleURL.flatMap { URL(string: $0) }
        let candidates = settings.candidateRoutes(isPrivateRepo: item.isPrivate, githubURL: stableURL)

        // 探测结果只做「锦上添花」：有缓存就直接用（0 延迟），
        // 没缓存也绝不为了排序把开始时间往后推 —— 引擎会边下边学。
        var plan = candidates.map { ScoredRoute(route: $0, speed: 1) }
        if candidates.count > 1, let host = start.url.host, let cached = probeCache.cached(for: host) {
            let names = Set(candidates.map { $0.name })
            plan = Self.plan(from: cached.filter { names.contains($0.route.name) }, candidates: candidates)
        } else if candidates.count > 1, item.source.supportsChunkedDownload {
            warmProbeCandidates(startURL: start.url, routes: candidates, stableURL: stableURL)
        }

        return DownloadEngine.Request(startURL: start.url,
                                      stableURL: stableURL,
                                      routes: plan,
                                      authToken: client.token,
                                      startHeaders: start.headers,
                                      fileName: item.fileName,
                                      connections: settings.clampedConnections,
                                      allowChunking: item.source.supportsChunkedDownload,
                                      resumeKey: item.id)
    }

    /// 后台预热通道探测：不阻塞本次下载，只为下一次（或下一个附件）省掉试错。
    private func warmProbeCandidates(startURL: URL,
                                     routes: [DownloadRoute],
                                     stableURL: URL?) {
        guard let host = startURL.host else { return }
        let urls = routes.map { route -> URL in
            switch route.scope {
            case .any: return route.apply(to: startURL)
            case .githubOnly: return route.apply(to: stableURL ?? startURL)
            }
        }
        Task.detached(priority: .utility) { [cache = probeCache] in
            let probes = await cache.probe(routes: routes, routeURLs: urls)
            guard probes.contains(where: { $0.ok }) else { return }
            cache.store(probes, for: host)
        }
    }

    /// 把探测结果映射成「带初始权重的通道计划」。
    ///
    /// 规则：
    ///  - 探测可用的通道按实测速度给权重（引擎一开始就把活儿压到真正的快线上）；
    ///  - 探测不可用的通道剔除，但**直连永远保留**（引擎的最终兜底依赖它，
    ///    而且探测失败也可能只是那一次握手抖动）；
    ///  - 全部不可用时保留原样，让引擎自己按老逻辑兜底。
    private static func plan(from probes: [RouteProbe],
                             candidates: [DownloadRoute]) -> [ScoredRoute] {
        guard !probes.isEmpty else { return candidates.map { ScoredRoute(route: $0, speed: 1) } }
        var usable = probes.filter { $0.ok }
        // 直连必须留在计划里（兜底通道）
        if !usable.contains(where: { $0.route.isDirect }),
           let directProbe = probes.first(where: { $0.route.isDirect }) {
            usable.append(directProbe)
        }
        let source = usable.isEmpty ? probes : usable
        return source.map { ScoredRoute(route: $0.route, speed: max($0.speed, 1)) }
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