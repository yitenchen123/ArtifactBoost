import Foundation

/// 一条通道的实测探测结果
struct RouteProbe: Sendable {
    let route: DownloadRoute
    /// 从发出请求到收到首个响应头的耗时（秒）
    let latency: TimeInterval
    /// 探测拿到的首块速度（字节/秒），探测失败为 0
    let speed: Double
    /// 是否可用（能连通、且没有立刻被拒）
    let ok: Bool
    /// 服务端回的 HTTP 状态码（诊断用）
    let status: Int?
}

/// 通道并发探测 + 结果缓存：解决「解析下载地址有点慢」里的后半段 ——
/// 以前是「按列表顺序挑通道」，4 个镜像里前 3 个是死的就得串行超时三次；
/// 现在同时打所有通道，谁先给出可用响应谁上岗，死的立刻剔除。
///
/// 结果按「主机名」缓存 5 分钟：同一个域名下次直接复用排序，
/// 不再重复探测，第二次打开同一个仓库基本是瞬发。
final class RouteProbeCache: @unchecked Sendable {
    static let shared = RouteProbeCache()

    private struct Entry {
        let routes: [RouteProbe]
        let at: Date
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// 缓存有效期：镜像的可用性变化很快，5 分钟是个折中
    private let ttl: TimeInterval = 300

    /// 探测超时（秒）：探测本身必须快，慢了就等于把「解析慢」原样搬过来
    private let timeout: TimeInterval = 2.5
    /// 探测时只拉一小段，够判断连通性和粗测速度就行
    private let probeBytes = 32 * 1024

    func cached(for host: String) -> [RouteProbe]? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[host] else { return nil }
        guard Date().timeIntervalSince(entry.at) < ttl else {
            entries.removeValue(forKey: host)
            return nil
        }
        return entry.routes
    }

    func store(_ probes: [RouteProbe], for host: String) {
        guard !probes.isEmpty else { return }
        lock.lock(); entries[host] = Entry(routes: probes, at: Date()); lock.unlock()
    }

    /// 清空缓存（用户切换下载源时调用：换源后旧的排序不再适用）
    func invalidateAll() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }

    /// 并发探测所有通道。
    ///
    /// 每条通道都发一个 `Range: bytes=0-<probeBytes>` 的小请求，
    /// 立刻量出「首个响应头延迟」和「这一小段的速度」。
    /// 全部并行，总耗时约等于最快那条的耗时（≈ RTT），而不是最慢那条。
    ///
    /// - Parameter routeURLs: 与 `routes` 一一对应的实际请求地址
    /// - Returns: 按「可用优先 → 速度快优先 → 延迟低优先」排好序的探测结果
    func probe(routes: [DownloadRoute], routeURLs: [URL]) async -> [RouteProbe] {
        guard routes.count == routeURLs.count, !routes.isEmpty else { return [] }

        // 先把参数取出来，避免在并发闭包里捕获 self
        let bytes = probeBytes
        let limit = timeout

        var results: [RouteProbe] = []
        results.reserveCapacity(routes.count)

        await withTaskGroup(of: RouteProbe.self) { group in
            for (index, route) in routes.enumerated() {
                let url = routeURLs[index]
                group.addTask {
                    await RouteProbeCache.probeOne(route: route, url: url,
                                                   bytes: bytes, timeout: limit)
                }
            }
            for await probe in group { results.append(probe) }
        }

        return results.sorted { lhs, rhs in
            if lhs.ok != rhs.ok { return lhs.ok }
            if lhs.speed != rhs.speed { return lhs.speed > rhs.speed }
            return lhs.latency < rhs.latency
        }
    }

    /// 单条通道探测。任何失败都返回 `ok: false`，绝不抛错 —— 探测不该影响主流程。
    private static func probeOne(route: DownloadRoute,
                                 url: URL,
                                 bytes: Int,
                                 timeout: TimeInterval) async -> RouteProbe {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("ArtifactBoost", forHTTPHeaderField: "User-Agent")

        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let elapsed = max(Date().timeIntervalSince(started), 0.001)
            guard let http = response as? HTTPURLResponse else {
                return RouteProbe(route: route, latency: elapsed, speed: 0, ok: false, status: nil)
            }
            // 429/503 也算「活着但被限流」：标记不可用，让别的通道先上
            let usable = (http.statusCode == 206 || http.statusCode == 200) && !data.isEmpty
            let speed = usable ? Double(data.count) / elapsed : 0
            return RouteProbe(route: route, latency: elapsed, speed: speed,
                              ok: usable, status: http.statusCode)
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            return RouteProbe(route: route, latency: elapsed, speed: 0, ok: false, status: nil)
        }
    }
}
