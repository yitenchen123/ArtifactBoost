import Foundation

struct DownloadProgress: Equatable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var fraction: Double = 0
    var speedBytesPerSecond: Double = 0
    /// 按当前平滑速度估算的剩余秒数；速度为 0 或体积未知时为 0
    var etaSeconds: Double = 0
    /// 本次是从断点续传开始的：这个值是「上次已经下好、这次直接跳过」的字节数
    var resumedBytes: Int64 = 0
    /// 分段的实时明细，用于「详细信息」面板；未开始分段时为 nil
    var diagnostics: DownloadDiagnostics? = nil
}

/// 单个分段的连接状态
enum SegmentState: String, Equatable, Sendable {
    case pending
    case downloading
    case retrying
    case done
    case failed

    var label: String {
        switch self {
        case .pending: return "等待中"
        case .downloading: return "下载中"
        case .retrying: return "重试中"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }
}

/// 一条「车道」的实时快照 —— 也就是一个 worker 当前正在啃的区间。
///
/// 这是「详细信息」面板的数据源：用户在界面上一眼能看到哪条连接在跑、
/// 跑到哪个区间、当前多快、有没有在重试、服务端回了什么状态码。
struct LaneSnapshot: Equatable, Identifiable, Sendable {
    let laneId: Int
    let routeName: String
    let url: String
    let start: Int64
    let end: Int64
    let downloaded: Int64
    let speedBytesPerSecond: Double
    let state: SegmentState
    let attempt: Int
    let lastStatus: Int?

    var id: Int { laneId }
    var length: Int64 { end - start + 1 }
    var fraction: Double {
        guard length > 0 else { return 0 }
        return min(max(Double(downloaded) / Double(length), 0), 1)
    }
}

/// 某条通道的实测速度与占用情况
struct RouteStats: Equatable, Identifiable, Sendable {
    let name: String
    let speedBytesPerSecond: Double
    let isActive: Bool
    var id: String { name }
}

/// 整次下载的诊断快照
struct DownloadDiagnostics: Equatable, Sendable {
    let lanes: [LaneSnapshot]
    let targetLanes: Int
    /// 已经完成的切片数 / 累计切出的切片总数
    let doneSlices: Int
    let totalSlices: Int
    let retries: Int
    let throttles: Int
    let splits: Int
    let routes: [RouteStats]
    /// 当前正在用的下载地址（可复制）
    let activeUrl: String
    /// 自适应并发窗口：引擎自己爬到的「服务器愿意给的并发」。
    /// 用户设的是上限，这个值才是当前实际在用的档位。
    var adaptiveWindow: Int = 0
    /// 是否检测到卡住（看门狗触发）
    var stalled: Bool = false
    /// AIMD 窗口的涨/缩次数与峰值（诊断面板用）
    var windowIncreases: Int = 0
    var windowDecreases: Int = 0
    var windowPeak: Int = 0
}

enum DownloadError: LocalizedError, Equatable {
    case badResponse
    case cancelled
    case incomplete
    /// 下载完成但**字节覆盖校验**没过：有区间缺口或重复写入。
    /// 带上账本给出的差异描述，方便定位（而不是只说一句「校验不通过」）。
    case incompleteDetailed(String)
    /// 服务器忽略 Range 头（回 200 全量）：这条地址不能用于分段下载
    case noRangeSupport
    /// 服务器明确要求我们慢一点（429 / 503 等），需要按 Retry-After 退避
    case throttled(code: Int, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "下载失败：服务器响应异常"
        case .cancelled: return "下载已取消"
        case .incomplete: return "下载失败：数据校验不通过（可能断流），请重试"
        case .incompleteDetailed(let detail):
            return "下载失败：文件字节校验不通过（\(detail)），请重试"
        case .noRangeSupport: return "下载失败：该通道不支持分段下载"
        case .throttled(let code, _): return "下载失败：服务器限流（\(code)）"
        }
    }

    static func == (lhs: DownloadError, rhs: DownloadError) -> Bool {
        switch (lhs, rhs) {
        case (.badResponse, .badResponse), (.cancelled, .cancelled), (.incomplete, .incomplete),
             (.noRangeSupport, .noRangeSupport):
            return true
        case let (.incompleteDetailed(a), .incompleteDetailed(b)):
            return a == b
        case let (.throttled(a, _), .throttled(b, _)):
            return a == b
        default:
            return false
        }
    }
}

struct DownloadResult {
    let fileURL: URL
    let averageSpeed: Double
    /// 本次实际吃满的并发数
    let lanes: Int
}

/// 起步请求的产物：把 **302 重定向后的真实地址 + 文件体积 + 首块数据**
/// 在一个 RTT 里全部拿到。
///
/// 这是 IDM 式做法的核心：不再有独立的「解析地址」「探测体积」两步，
/// 第一个带 Range 的请求本身就是下载的开始 —— 用户点下去到出速度只差一个往返。
struct EngineBootstrap: Sendable {
    let data: Data
    let total: Int64
    let chunked: Bool
    let etag: String?
    let lastModified: String?
    let finalURL: URL
    let status: Int
}

/// 一个待下载的区间（左闭右闭）。区间只记 start/end，砍成两半不需要给任何 worker 重新编号。
private struct Chunk: Sendable {
    let start: Int64
    let end: Int64
    /// 这一片被推迟到什么时候才能再被取走（失败退避用）。
    /// nil 表示立刻可取 —— 正常切分/续做出来的区间都是 nil。
    var notBefore: Date? = nil

    var length: Int64 { end - start + 1 }
}

/// 待下载区间的池子（滑动窗口 + 失败退避）。
///
/// 关键修复：老实现里失败的片直接 `insert(at: 0)` 插回队首，
/// 下一个空闲 worker 立刻又把它捞走重试 —— 服务器正在限流时，
/// 这就成了一个「疯狂撞墙」的热循环：连接数不掉、吞吐为零、
/// 用户看到的正是「卡住」。现在失败区间带 `notBefore` 退避时间，
/// 在到点之前对 `take()` 不可见，调度器自然会去干别的活儿。
private final class SlicePool: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Chunk] = []
    private let total: Int64

    /// 每次「把末尾区间砍一刀」记一笔
    private(set) var splits = 0
    /// 已完成的字节数：用来估算剩余量、决定分片粒度
    private var completed: Int64 = 0
    private(set) var failures = 0
    private(set) var throttles = 0
    /// 已成功取走的片数 / 仍在排队的片数（诊断用）
    private(set) var dispatched = 0

    var backlog: Int {
        lock.lock(); defer { lock.unlock() }
        return queue.count
    }

    /// - Parameter gaps: 直接指定「要下的区间」（断点续传时就是上次没下完的缺口）；
    ///   不传就是从 0 到末尾的整段。
    /// - Parameter completed: 断点续传时已经下好的字节数，计入总进度。
    init(total: Int64, gaps: [ClosedRange<Int64>]? = nil, completed: Int64 = 0) {
        self.total = total
        self.completed = completed
        if let gaps {
            queue = gaps.compactMap { range in
                guard range.lowerBound >= 0, range.upperBound < total,
                      range.lowerBound <= range.upperBound else { return nil }
                return Chunk(start: range.lowerBound, end: range.upperBound)
            }
        } else {
            queue = total > 0 ? [Chunk(start: 0, end: total - 1)] : []
        }
    }

    func downloaded() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return completed
    }

    func recordDone(_ bytes: Int64) {
        lock.lock(); completed += bytes; lock.unlock()
    }

    func recordFailure() {
        lock.lock(); failures += 1; lock.unlock()
    }

    /// 重置失败计数（缺口修复轮开始前调用）。
    ///
    /// 主循环可能已经因为连续失败攒满预算；不重置的话，补漏这一轮
    /// 第一次失败就会直接掀桌 —— 而补漏恰恰最需要「允许零星失败」。
    func resetFailures() {
        lock.lock(); failures = 0; lock.unlock()
    }

    func failureCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return failures
    }

    func recordThrottle() {
        lock.lock(); throttles += 1; lock.unlock()
    }

    /// 取一段活儿；没有（或都在退避中）就返回 nil，由调度循环决定要不要切分。
    ///
    /// 会跳过还在退避期的区间 —— 这是修「失败片立刻被重取」热循环的关键。
    func take() -> Chunk? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard let index = queue.firstIndex(where: { ($0.notBefore ?? .distantPast) <= now }) else {
            return nil
        }
        let chunk = queue.remove(at: index)
        dispatched += 1
        checkInvariantsLocked()
        return chunk
    }

    /// 退避中的区间还剩几个（调度器据此决定等多久）
    func deferredCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return queue.filter { ($0.notBefore ?? .distantPast) > now }.count
    }

    /// 把没下完的区间插回队列最前面。
    ///
    /// - Parameter backoff: 多久之后才允许再被取走。失败重派时必须给非零值，
    ///   否则就是老实现那个「立刻重取、疯狂撞墙」的热循环。
    func putBack(_ chunk: Chunk, backoff: TimeInterval = 0) {
        lock.lock()
        var scheduled = chunk
        if backoff > 0 {
            scheduled.notBefore = Date().addingTimeInterval(backoff)
        }
        queue.insert(scheduled, at: 0)
        checkInvariantsLocked()
        lock.unlock()
    }

    /// 池子空了、但还有连接闲着时调用：从队列末尾挑一段砍成两半。
    ///
    /// 只砍「立刻可取」的区间；正在退避的区间不动它们，
    /// 免得把一块还没到期的坏区间砍碎后到处散落。
    func splitTail(live: Int, target: Int) -> Chunk? {
        guard live > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard let index = queue.lastIndex(where: { ($0.notBefore ?? .distantPast) <= now })
        else { return nil }
        let victim = queue[index]
        guard victim.length > Int64(target) else { return nil }
        let half = victim.length / 2
        queue[index] = Chunk(start: victim.start + half, end: victim.end)
        splits += 1
        checkInvariantsLocked()
        return Chunk(start: victim.start, end: victim.start + half - 1)
    }

    /// 区间所有权不变量自检（仅 Debug 构建生效，Release 下函数体被优化掉）。
    ///
    /// 校验两件事：
    ///  1. 池内所有区间两两不重叠 —— 一旦重叠，两个 worker 会下同一段、重复写盘；
    ///  2. 所有区间都落在 `[0, total)` 内 —— 越界写会直接损坏文件。
    ///
    /// 这条断言就是为「派发总字节超过文件体积」那个 bug 加的防线：
    /// 以后谁再动调度逻辑，测试没覆盖到的地方也能在 Debug 跑挂暴露出来。
    /// 调用方必须已持有 `lock`。
    private func checkInvariantsLocked() {
        #if DEBUG
        var prevEnd: Int64 = -1
        for chunk in queue.sorted(by: { $0.start < $1.start }) {
            assert(chunk.start >= 0 && chunk.start < total,
                   "区间起点越界: \(chunk.start) 不在 [0, \(total))")
            assert(chunk.end >= 0 && chunk.end < total,
                   "区间终点越界: \(chunk.end) 不在 [0, \(total))")
            assert(chunk.start <= chunk.end, "区间非法: \(chunk.start) > \(chunk.end)")
            assert(chunk.start > prevEnd,
                   "区间重叠: 上一段结束于 \(prevEnd)，这一段却从 \(chunk.start) 开始")
            prevEnd = chunk.end
        }
        #endif
    }
}

/// 「还没到 deadline 就已经不动了」的看门狗。
///
/// URLSession 的 `timeoutIntervalForRequest` 是 **idle 超时**，理想情况下
/// 卡住的连接能自己超时。但现实里两层代理/CDN 会持续吐心跳字节（KEEPALIVE），
/// idle 计时器不断被重置，那条连接就「看着在动、实际一动不动」地挂着 ——
/// 用户看到的就是「时不时卡住」。这里用「进度没涨」而不是「没收到字节」来判：
/// 只有真正写入文件的字节才重置计时器，心跳字节不算。
private final class StallWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Int64 = 0
    private var lastProgressAt = Date()
    /// 多久没有任何一片写完就判定「卡住」（秒）
    private let stallWindow: TimeInterval

    init(stallWindow: TimeInterval = 12) {
        self.stallWindow = stallWindow
    }

    func noteProgress(_ bytes: Int64) {
        lock.lock()
        progress += bytes
        lastProgressAt = Date()
        lock.unlock()
    }

    var totalProgress: Int64 {
        lock.lock(); defer { lock.unlock() }
        return progress
    }

    var stalledFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastProgressAt)
    }

    var isStalled: Bool { stalledFor > stallWindow }

    /// 恢复进度（卡住后重新派活了，计时器重置）
    func reset() {
        lock.lock(); lastProgressAt = Date(); lock.unlock()
    }
}

/// 汇总各分块进度，节流后回调给 UI
private actor ProgressAccumulator {
    private var downloaded: Int64 = 0
    private let total: Int64
    private let handler: @Sendable (DownloadProgress) -> Void
    /// 快照来源：每拍现取一次车道看板，拿到的就是「此刻」而不是「启动时」的明细
    private let diagnostics: (@Sendable () -> DownloadDiagnostics?)?
    /// 断点续传跳过的字节数：界面据此显示「已续传 X」
    private let resumedBytes: Int64
    private var lastEmit = Date.distantPast
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedSpeed: Double = 0
    private var zeroStreak = 0

    init(total: Int64,
         initial: Int64 = 0,
         resumedBytes: Int64 = 0,
         handler: @escaping @Sendable (DownloadProgress) -> Void,
         diagnostics: (@Sendable () -> DownloadDiagnostics?)? = nil) {
        self.total = total
        self.downloaded = initial
        self.resumedBytes = resumedBytes
        self.lastSampleBytes = initial
        self.handler = handler
        self.diagnostics = diagnostics
    }

    /// 速度用滑动平均避免数字乱跳；但连续几拍零增长时必须往下压，
    /// 否则界面会一直挂着峰值速度、而实际已经掉下去了。
    private func snapshot(_ current: Int64) -> DownloadProgress {
        let now = Date()
        let dt = now.timeIntervalSince(lastSampleTime)
        if dt > 0.05 {
            let delta = current - lastSampleBytes
            if delta <= 0 {
                zeroStreak += 1
                // 连续 3 拍没涨（约 0.75s 零吞吐）：平滑值必须往下压
                if zeroStreak >= 3 { smoothedSpeed *= 0.4 }
            } else {
                zeroStreak = 0
                let instant = Double(delta) / dt
                smoothedSpeed = smoothedSpeed <= 0 ? instant : smoothedSpeed * 0.6 + instant * 0.4
            }
            lastSampleTime = now
            lastSampleBytes = current
        }
        let remaining = max(total - current, 0)
        let eta = smoothedSpeed > 64 ? Double(remaining) / smoothedSpeed : 0
        return DownloadProgress(
            downloadedBytes: current,
            totalBytes: total,
            fraction: total > 0 ? min(Double(current) / Double(total), 1) : 0,
            speedBytesPerSecond: max(smoothedSpeed, 0),
            etaSeconds: eta,
            resumedBytes: resumedBytes,
            diagnostics: diagnostics?()
        )
    }

    func advance(_ bytes: Int64) {
        downloaded += bytes
        let now = Date()
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { return }
        lastEmit = now
        handler(snapshot(downloaded))
    }

    func finish(downloaded: Int64) {
        self.downloaded = downloaded
        var progress = snapshot(downloaded)
        progress.totalBytes = max(total, downloaded)
        progress.downloadedBytes = progress.totalBytes
        progress.fraction = 1
        handler(progress)
    }
}

/// 一次分片请求的结果
private struct SliceOutcome: Sendable {
    let data: Data
    let elapsed: TimeInterval
}

/// 通道列表的回填盒子：accumulator 的快照闭包要先于通道建好，
/// 于是先用一个盒子占位，通道一建好就塞进去。
private final class ChannelsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: [RouteChannel] = []

    var value: [RouteChannel] {
        lock.lock(); defer { lock.unlock() }
        return _value
    }

    func set(_ channels: [RouteChannel]) {
        lock.lock(); _value = channels; lock.unlock()
    }
}

/// 一个通道：独立 URLSession（独立连接池）+ 地址列表 + 实时吞吐
///
/// `urls` 不可变：`urls[0]` 是主地址，`urls.last` 是兜底（直连）。
/// 多 lane 共享同一个 channel，旧的 `rotate()` 会全局变异 `urls`，
/// 并发重试时 A 切到直连、B 又切回去，兜底形同虚设。
/// 现在重试只用局部下标选地址，不再变异共享状态。
private final class RouteChannel: @unchecked Sendable {
    let session: URLSession
    /// 展示名（直连 / gh-proxy.com / …），用于诊断面板
    let name: String
    private let lock = NSLock()
    let urls: [URL]
    private var speed: Double
    private var _throttled = false

    init(session: URLSession, urls: [URL], speedHint: Double, name: String) {
        self.session = session
        self.urls = urls.isEmpty ? [] : urls
        self.speed = max(speedHint, 1)
        self.name = name
    }

    /// 是否本通道处于「被限流降额」状态
    var throttled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _throttled
    }

    func setThrottled(_ value: Bool) {
        lock.lock(); _throttled = value; lock.unlock()
    }

    var current: URL {
        urls[0]
    }

    /// 主地址（`urls[0]`）
    var primary: URL { urls[0] }
    /// 兜底地址（直连）；单地址通道时与主地址相同
    var fallback: URL { urls.last ?? urls[0] }

    /// 该 URL 是否走了兜底（主备不同且命中了最后一个）
    func isFallback(_ url: URL) -> Bool {
        urls.count > 1 && url == urls.last && url != urls[0]
    }

    var measuredSpeed: Double {
        lock.lock(); defer { lock.unlock() }
        return speed
    }

    func demote() {
        lock.lock(); speed = max(speed * 0.5, 1); lock.unlock()
    }

    func observe(elapsed: TimeInterval, bytes: Int64) {
        guard elapsed > 0.02, bytes > 0 else { return }
        let instant = Double(bytes) / elapsed
        lock.lock()
        speed = speed <= 0 ? instant : speed * 0.7 + instant * 0.3
        lock.unlock()
    }
}

/// 车道状态看板：所有 worker 把自己的实时状态登记在这里，
/// 由进度回调按既有的 250ms 节流节奏取走 —— 不额外起轮询、不加网络开销。
///
/// 同时兼任「通道级并发配额」的计数：命中 429/503 的通道会被临时降额，
/// 免得在同一根被限流的线路上继续加压、越限越死。
private final class LaneBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var lanes: [Int: LaneSnapshot] = [:]
    private var penalties: [String: Int] = [:]

    let target: Int

    private(set) var doneSlices = 0
    private(set) var totalSlices = 0
    private(set) var retries = 0
    private(set) var throttles = 0
    private(set) var splits = 0
    private var _activeUrl = ""
    /// 自适应窗口 / 卡住标志：由调度循环每拍写入，UI 直接读走
    private var _adaptiveWindow = 0
    private var _stalled = false
    /// AIMD 窗口统计（调度循环写入，快照读出）
    private var _windowIncreases = 0
    private var _windowDecreases = 0
    private var _windowPeak = 0

    /// 调度循环每拍把 AIMD 的实时状态同步进看板
    func syncWindow(current: Int, increases: Int, decreases: Int, peak: Int) {
        lock.lock()
        _adaptiveWindow = current
        _windowIncreases = increases
        _windowDecreases = decreases
        _windowPeak = peak
        lock.unlock()
    }

    var adaptiveWindow: Int {
        get { lock.lock(); defer { lock.unlock() }; return _adaptiveWindow }
        set { lock.lock(); _adaptiveWindow = newValue; lock.unlock() }
    }

    var stalled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stalled }
        set { lock.lock(); _stalled = newValue; lock.unlock() }
    }

    init(target: Int) { self.target = target }

    var activeUrl: String {
        get { lock.lock(); defer { lock.unlock() }; return _activeUrl }
        set { lock.lock(); _activeUrl = newValue; lock.unlock() }
    }

    func update(_ snapshot: LaneSnapshot) {
        lock.lock(); lanes[snapshot.laneId] = snapshot; lock.unlock()
    }

    func remove(_ laneId: Int) {
        lock.lock(); lanes.removeValue(forKey: laneId); lock.unlock()
    }

    func bumpDoneSlice() { lock.lock(); doneSlices += 1; lock.unlock() }
    func bumpTotalSlice() { lock.lock(); totalSlices += 1; lock.unlock() }
    func bumpRetry() { lock.lock(); retries += 1; lock.unlock() }
    func bumpThrottle() { lock.lock(); throttles += 1; lock.unlock() }
    func bumpSplit() { lock.lock(); splits += 1; lock.unlock() }

    /// 通道被限流：记一笔惩罚，通道跑顺后再衰减回去
    func penalize(_ routeName: String) {
        lock.lock(); penalties[routeName, default: 0] += 1; lock.unlock()
    }

    func reward(_ routeName: String) {
        lock.lock()
        if let value = penalties[routeName], value > 0 { penalties[routeName] = value - 1 }
        lock.unlock()
    }

    func penalty(of routeName: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return penalties[routeName] ?? 0
    }

    /// 只取在跑的车道（供「哪条通道正在干活」判断用）
    func liveLanes() -> [LaneSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return Array(lanes.values)
    }

    func snapshot(routes: [RouteStats]) -> DownloadDiagnostics {
        lock.lock()
        let laneValues = lanes.values.sorted { $0.start < $1.start }
        let d = doneSlices, t = totalSlices, r = retries, th = throttles, sp = splits, url = _activeUrl
        let win = _adaptiveWindow, st = _stalled
        let inc = _windowIncreases, dec = _windowDecreases, pk = _windowPeak
        lock.unlock()
        return DownloadDiagnostics(lanes: laneValues,
                                   targetLanes: target,
                                   doneSlices: d,
                                   totalSlices: t,
                                   retries: r,
                                   throttles: th,
                                   splits: sp,
                                   routes: routes,
                                   activeUrl: url,
                                   adaptiveWindow: win,
                                   stalled: st,
                                   windowIncreases: inc,
                                   windowDecreases: dec,
                                   windowPeak: pk)
    }
}

/// 多线程分段下载引擎（滑动窗口 + 分片续做）。
///
/// 产物实际托管在 Azure Blob Storage，支持 Range 请求；单连接被限速时，
/// 多并发能显著提升总速度——这正是本引擎存在的意义。
///
/// 与「一次性切块 + 固定分配给各连接」的老做法相比，这里的调度是自适应的：
///
///  1. **滑动窗口**：并发跑满 `connections` 个任务，每个任务只取「一小片」；
///     而不是开 N 个协程去啃又大又不均匀的一大块。
///  2. **分片续做（steal）**：任何时刻若只剩少量区间在跑、而空闲 worker 还很多，
///     就把末尾那段区间再砍一半。下载最后阶段不再是「一个慢连接收尾、
///     其它连接全部闲着」，而是所有连接一起把剩下的数据吃完。
///  3. **动态分片大小**：剩余数据多就取大一点（少发请求），接近尾声就取小一点
///     （让所有连接都能分到收尾的活儿）。
///  4. **区间即偏移**：区间只记 (start, end)，砍分时不需要重编号，写盘可以乱序并发。
///  5. **指数退避 + Retry-After**：命中 Azure 的 503 ServerBusy / 429 时限速时按官方
///     建议退避，而不是火上浇油地硬重试，否则会被越限越死。
///  6. **实时吞吐反馈**：某个通道早就慢下来了，就少给它派活
///     （旧的「一次性按测速结果分配」正是慢通道拖死整体进度的原因之一）。
final class DownloadEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [URLSession] = []
    private let cancelledFlag = CancelledFlag()

    /// 在飞的下载任务：取消时必须逐个 cancel，否则挂起的 `await` 会一直等下去
    private let inflight = TaskRegistry()

    /// 取消下载。
    ///
    /// 「点了就停」需要三件事一起做：置标志位 → 取消每个在飞的 URLSessionDataTask
    /// → 让上层 actor 里的等待被唤醒。只置标志位是不够的：
    /// 已经挂起的 `await session.data(for:)` 不会自己返回，得靠 task.cancel() 打断。
    func cancel() {
        cancelledFlag.set()
        inflight.cancelAll()
        lock.lock()
        let current = sessions
        lock.unlock()
        current.forEach { $0.invalidateAndCancel() }
    }

    private var isCancelled: Bool { cancelledFlag.value }

    /// 可取消的一次请求。
    ///
    /// `URLSession.data(for:)` 挂起时，协程取消不会让它返回；必须拿到 task 调 `cancel()`。
    /// 这里用 continuation 自己控制，把 task 登记进 [inflight]，
    /// 这样 `engine.cancel()` 和「上层 Task 取消」两条路径都能立刻掐断等待。
    private func send(_ request: URLRequest, on session: URLSession) async throws -> (Data, URLResponse) {
        if isCancelled || inflight.isCancelling { throw DownloadError.cancelled }

        let holder = TaskHolder()
        do {
            let result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                    let task = session.dataTask(with: request) { data, response, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else if let data, let response {
                            continuation.resume(returning: (data, response))
                        } else {
                            continuation.resume(throwing: DownloadError.badResponse)
                        }
                    }
                    holder.task = task
                    inflight.register(task)
                    // 注册后立刻再查一次：取消可能恰好发生在这两步之间
                    if isCancelled || inflight.isCancelling {
                        task.cancel()
                    } else {
                        task.resume()
                    }
                }
            } onCancel: {
                holder.task?.cancel()
            }
            if let task = holder.task { inflight.release(task) }
            return result
        } catch {
            if let task = holder.task { inflight.release(task) }
            throw error
        }
    }

    private func setSessions(_ newValue: [URLSession]) {
        lock.lock()
        sessions = newValue
        lock.unlock()
    }

    /// 一次下载的全部输入。
    struct Request: Sendable {
        /// 第一个请求直接打这个地址（github.com 稳定地址 / api.github.com / codeload）
        let startURL: URL
        /// 该下载在 github.com 上的稳定地址：ghfast 这类只认原始地址的镜像要用
        let stableURL: URL?
        /// 通道计划（含直连）；顺序即初始权重顺序
        let routes: [ScoredRoute]
        /// 仅用于首个请求的 Token：**绝不发给第三方镜像**
        let authToken: String?
        /// 首个请求需要的额外请求头（例如附件接口要 Accept）
        let startHeaders: [String: String]
        let fileName: String
        let connections: Int
        /// 目标是否可能支持分段（源码包由 GitHub 现场打包，不支持）
        let allowChunking: Bool
        /// 断点续传的键（下载项 id）
        let resumeKey: String?
    }

    /// 多通道并行下载（IDM 式单请求起步）。
    func download(_ request: Request,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> DownloadResult {
        cancelledFlag.reset()
        inflight.reset()
        let startedAt = Date()
        let plan = request.routes.isEmpty ? [ScoredRoute(route: .direct, speed: 1)] : request.routes
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let outDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artifacts", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var outURL = outDir.appendingPathComponent(request.fileName)
        if fm.fileExists(atPath: outURL.path) {
            outURL = outDir.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(request.fileName)")
        }

        // 极限档并发意味着几百条 socket：先把 fd soft limit 顶到 hard 上限，
        // 否则默认值（常见 256）会在建连一半时报 too many open files。
        Self.raiseFileLimit()

        // **按可用内存限制并发**（大文件的关键修复）。
        let requestedLanes = max(1, min(request.connections, Self.maxLanes))
        let lanes = Self.safeLanes(requested: requestedLanes,
                                   bytesPerLane: Int(Self.maxSliceTarget))

        // ---- 起步：一个请求同时完成「解析 / 探体积 / 拿首块」----
        var boot: EngineBootstrap? = nil
        if request.allowChunking {
            boot = try await fetchBootstrap(url: request.startURL,
                                            authToken: request.authToken,
                                            headers: request.startHeaders)
        }
        if let status = boot?.status, !(200...299).contains(status) {
            // 把常见的 GitHub 错误码翻译成人话，而不是笼统的「服务器响应异常」
            switch status {
            case 401, 403, 404, 410:
                throw GitHubError.http(status, "")
            default:
                throw DownloadError.badResponse
            }
        }
        let finalURL = boot?.finalURL ?? request.startURL
        let total = boot?.total ?? 0

        // 不支持分段 / 体积太小 / 探测不到体积：单连接（但依然带真实进度）
        if boot?.chunked != true || total < Self.minChunkedTotal {
            if let key = request.resumeKey { ResumeStore.shared.discard(key: key) }
            let single = try await downloadSingle(url: finalURL,
                                                 into: outURL,
                                                 expectedTotal: total,
                                                 progress: progress)
            return DownloadResult(fileURL: single.url,
                                  averageSpeed: Self.speed(bytes: single.bytes, since: startedAt),
                                  lanes: 1)
        }

        // 断点续传：上次没下完的区间接着下，而不是从 0 重来。
        // 没有可用记录时也保留一个空上下文 —— 这样本次的进度会周期性落盘，
        // 用户中途被杀进程 / 点暂停后，下次能直接续上。
        var resume: ResumeContext? = nil
        if let resumeKey = request.resumeKey {
            if var prepared = ResumeStore.shared.prepare(key: resumeKey,
                                                         total: total,
                                                         etag: boot?.etag,
                                                         lastModified: boot?.lastModified,
                                                         fileName: request.fileName) {
                // 元数据里可能残留已越界的区间（文件被截断过），这里再夹一次
                prepared = ResumeContext(key: prepared.key,
                                         partURL: prepared.partURL,
                                         etag: prepared.etag,
                                         lastModified: prepared.lastModified,
                                         covered: prepared.covered.filter { $0.upperBound < total })
                resume = prepared
            } else {
                resume = ResumeContext(key: resumeKey,
                                       partURL: ResumeStore.shared.partURL(key: resumeKey),
                                       etag: boot?.etag,
                                       lastModified: boot?.lastModified,
                                       covered: [])
            }
        }

        // 通道地址：用**重定向后的真实地址**给镜像套前缀。
        // 这样连构建产物这种必须先拿签名地址的情况，也只需要一次解析（就在上面那个起步请求里）。
        let channelURLs: [URL] = plan.map { scored in
            switch scored.route.scope {
            case .any:
                return scored.route.apply(to: finalURL)
            case .githubOnly:
                guard let stable = request.stableURL else { return scored.route.apply(to: finalURL) }
                return scored.route.apply(to: stable)
            }
        }

        let fileURL = try await segmentDownload(urls: channelURLs,
                                                plan: plan,
                                                total: total,
                                                outURL: outURL,
                                                lanes: lanes,
                                                resume: resume,
                                                prefill: (boot?.data.isEmpty == false) ? boot?.data : nil,
                                                progress: progress)
        return DownloadResult(fileURL: fileURL,
                              averageSpeed: Self.speed(bytes: total, since: startedAt),
                              lanes: lanes)
    }

    private static func speed(bytes: Int64, since start: Date) -> Double {
        Double(bytes) / max(Date().timeIntervalSince(start), 0.05)
    }

    // MARK: - 分段下载主循环

    /// 滑动窗口 + 分片续做（work stealing）的调度器。
    ///
    /// `lanes` 是目标并发数，同时也是「同时在跑的区间数」上限。
    /// 每个区间按 `sliceTarget` 的粒度取数据，写完一片就接着取下一片；
    /// 一旦池子里没活儿而还有连接闲着，就从末尾区间切一刀 —— 空闲连接立刻有活干。
    ///
    /// 这样就不会再出现「刚开始很快、到后面掉到几十 KB」：
    /// 那正是老实现里「一条慢连接独自收尾，其余连接全部空转」造成的。
    private func segmentDownload(urls: [URL],
                                 plan: [ScoredRoute],
                                 total: Int64,
                                 outURL: URL,
                                 lanes: Int,
                                 resume: ResumeContext?,
                                 prefill: Data?,
                                 progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        // 车道状态看板：worker 实时登记，进度回调每拍取走一份快照。
        // 先于 accumulator 建好，因为 accumulator 的快照闭包要读它。
        let board = LaneBoard(target: lanes)
        // 通道列表要等 session 建好才有，这里先留一个可回填的盒子。
        let channelsBox = ChannelsBox()

        // 续传时「已经下好的字节」要算进进度起点，否则界面会从 0% 开始跳
        var seededCovered = resume?.covered ?? []
        var prefillOffset: Int64 = 0
        var prefillData: Data? = nil
        if let prefill, !prefill.isEmpty {
            // 起步请求已经下好的那一小块直接算作已完成：
            // 少发一次请求，用户也能立刻看到进度条动起来。
            prefillOffset = 0
            // 如果 0 这段本来就在续传记录里，就不用重复写了
            let alreadyCovered = seededCovered.contains { $0.contains(0) && $0.upperBound >= Int64(prefill.count - 1) }
            if !alreadyCovered {
                let end = Int64(prefill.count) - 1
                if end < total {
                    prefillData = prefill
                    seededCovered.append(0...end)
                }
            }
        }
        let seededBytes = seededCovered.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound + 1) }
        let accumulator = ProgressAccumulator(total: total,
                                              initial: seededBytes,
                                              resumedBytes: resume?.coveredBytes ?? 0,
                                              handler: progress) {
            let active = Set(board.liveLanes().map { $0.routeName })
            return board.snapshot(routes: channelsBox.value.map {
                RouteStats(name: $0.name,
                           speedBytesPerSecond: $0.measuredSpeed,
                           isActive: active.contains($0.name))
            })
        }

        // 关键：Cloudflare 这类 CDN 会协商 HTTP/2，所有请求被多路复用到同一条 TCP 连接上，
        // 长链路下单连接带宽就是天花板，开再多"连接"也没用。
        // 每个 URLSession 有独立的连接池，拆成多个会话才能真正拿到多条并行连接。
        let sessionCount = min(8, max(1, lanes / 8))
        let perSessionLimit = max(1, lanes / sessionCount)
        var sessions: [URLSession] = []
        for _ in 0..<sessionCount {
            let config = URLSessionConfiguration.ephemeral
            // **关键**：`timeoutIntervalForRequest` 是 **idle 超时** —— 它按
            // 「两次收到数据之间的间隔」计时，而 CDN 的心跳字节会不断重置它，
            // 结果就是「看着在动、实际一动不动」的连接永远不超时。
            // 以前设 60s，配合 3600s 的资源总时长，一条挂住的连接能占着
            // 一条 lane 一小时。现在收紧到 20s，并靠 StallWatchdog + 单片
            // 总时长上限双重兜底，最坏情况也只是丢掉这一片、换线重试。
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 1800
            config.httpMaximumConnectionsPerHost = perSessionLimit
            sessions.append(URLSession(configuration: config))
        }
        setSessions(sessions)
        defer {
            sessions.forEach { $0.invalidateAndCancel() }
            setSessions([])
        }

        let directIndex = plan.firstIndex(where: { $0.route.isDirect }) ?? 0
        let direct = urls[min(directIndex, urls.count - 1)]
        let channels: [RouteChannel] = plan.enumerated().map { index, scored in
            let primary = urls[min(index, urls.count - 1)]
            // 镜像挂掉/被限流时自动退回直连
            let endpoints = primary == direct ? [primary] : [primary, direct]
            return RouteChannel(session: sessions[index % sessions.count],
                                urls: endpoints,
                                speedHint: max(scored.speed, 1),
                                name: scored.route.name)
        }
        channelsBox.set(channels)

        // 每条通道分到的并发额度（单通道配额）：通道数少就给得多，
        // 免得 4 条镜像时每条只剩 4 个并发、根本压不满带宽。
        let perChannelQuota = max(1, lanes / max(channels.count, 1))
        // 车道编号只增不减：worker 收工后编号不复用，
        // 这样诊断面板上「车道 #7 干了什么」不会因为复用而张冠李戴。
        let laneCounter = Counter()

        let fm = FileManager.default
        // 续传时写的是稳定的半成品文件（Application Support 下，系统不会清），
        // 下载完成后才原子地挪到最终的成品目录；这样中途被杀也不会丢数据。
        let writeURL = resume?.partURL ?? outURL
        if resume == nil {
            try? fm.removeItem(at: writeURL)
            guard fm.createFile(atPath: writeURL.path, contents: nil) else { throw DownloadError.badResponse }
        } else if !fm.fileExists(atPath: writeURL.path) {
            guard fm.createFile(atPath: writeURL.path, contents: nil) else { throw DownloadError.badResponse }
        }
        let handle = try FileHandle(forWritingTo: writeURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(total))

        let pool = SlicePool(total: total,
                             gaps: Self.gaps(total: total, covered: seededCovered),
                             completed: seededBytes)
        let sink = WriteSink(handle: handle)
        // 覆盖账本：记录「哪些字节真的被写进文件了」。
        // 以前收尾只校验 size == total（总量），而「重复写一段 + 漏写一段」
        // 的总量可能相等 —— 文件大小对、内容错，症状就是「能下完但解压不了」。
        let ledger = WriteLedger(total: total)
        // 续传的旧区间 + 起步请求拿到的首块，都先记进账本
        ledger.seed(seededCovered)
        if let prefillData {
            sink.write(prefillData, at: prefillOffset)
        }

        // 周期性 checkpoint：进程被杀时内存里的账本会丢，
        // 每 1.5s 把「已覆盖区间」写进磁盘，重启后最多只重下 1.5 秒的量。
        let store = ResumeStore.shared
        var lastCheckpoint = Date()
        func checkpoint(force: Bool = false) {
            guard let resume else { return }
            let now = Date()
            if !force, now.timeIntervalSince(lastCheckpoint) < 1.5 { return }
            lastCheckpoint = now
            let meta = ResumeMeta(total: total,
                                  etag: resume.etag,
                                  lastModified: resume.lastModified,
                                  ranges: ledger.rangesSnapshot(),
                                  updatedAt: now)
            if force {
                store.saveNow(meta, key: resume.key)
            } else {
                store.save(meta, key: resume.key)
            }
        }
        // 非正常退出（取消 / 失败 / 校验不过）时补一次同步落盘：
        // 已经下好的字节不能因为这次失败就作废。
        var finished = false
        defer { if !finished { checkpoint(force: true) } }

        try await withThrowingTaskGroup(of: Void.self) { group in
            // 并发计数：worker 结束时自己递减（见 addTask 闭包尾部）。
            // 调度循环因此**绝不阻塞等待 worker 退出** —— 每一轮都能重新
            // 尝试派活，worker 把尾部区间还回池子的瞬间，新 worker 就能补位。
            let active = ConcurrencyCounter()
            let limiter = AdaptiveConcurrency(ceiling: lanes)
            // 卡住看门狗：12s 没有任何字节落盘就判定「卡住」并主动拆掉重连
            let watchdog = StallWatchdog(stallWindow: Self.stallWindow)
            var roundRobin = 0

            // 无进展保护：所有 worker 都在「失败→重派→再失败」里空转、
            // 文件一个字节都没涨，这种状态持续 90 秒就判定全线失败。
            // 没有它，全线断网/磁盘写挂时调度器会永远空转下去。
            var lastProgressBytes = pool.downloaded()
            var lastProgressAt = Date()
            // 卡住时的强制重建：掐掉所有在飞连接，让调度器用新连接重来
            var lastStallBreak = Date.distantPast

            while true {
                // 取消后立刻退出调度循环，不再派新活儿
                if isCancelled || inflight.isCancelling { break }
                // 每 1.5s 把账本落一次盘：被杀进程时最多损失 1.5 秒的下载量
                checkpoint()

                // 无进展保护（worker 失败时是让位退出而不是抛错，全靠这里兜底）。
                // 判据是「池子里还有活儿（在跑 或 在退避）却一直没涨」，
                // 不能只看 active.current —— 全部区间都在退避时 active 可能是 0，
                // 那种情况下同样不能永远等下去。
                let downloaded = pool.downloaded()
                if downloaded != lastProgressBytes {
                    lastProgressBytes = downloaded
                    lastProgressAt = Date()
                } else if (active.current > 0 || pool.deferredCount() > 0 || pool.backlog > 0),
                          Date().timeIntervalSince(lastProgressAt) > 90 {
                    throw DownloadError.incomplete
                }

                // 0) 卡住检测：有连接在飞、但一个字节都没落盘超过 12 秒。
                //
                // 这正是用户说的「时不时卡住」：CDN 的心跳字节让 URLSession 的
                // idle 超时永远不触发，那条连接就这么挂着。这里由看门狗主动出手 ——
                // 掐掉所有在飞请求（含它们各自的 20s+ 单片超时），调度循环下一轮
                // 会用全新的连接重新派活；同时把窗口砍一刀，避免再扑上去撞同一堵墙。
                if active.current > 0, watchdog.isStalled,
                   Date().timeIntervalSince(lastStallBreak) > 5 {
                    lastStallBreak = Date()
                    board.stalled = true
                    inflight.abortAll()
                    limiter.noteFailure()
                    watchdog.reset()
                    lastProgressAt = Date()
                    // 给被掐掉的 worker 一点时间退出，再重新评估
                    try? await Task.sleep(for: .milliseconds(120))
                    continue
                } else if !watchdog.isStalled {
                    board.stalled = false
                }

                // 1) 把并发顶到「当前允许值」；通道被限流时按配额收缩。
                //
                // 这里的 allowed 不再来自固定时间片的爬坡，而是 AIMD 窗口：
                // 顺畅时自己涨（≈ 用户设的上限封顶），命中限流立刻砍半。
                // 用户把并发拉到 128 只会让「上限」更高，不会真的盲目砸 128 条连接。
                var assigned = false
                // 尾段只派快通道：剩的不够全员分时，再按权重抽中慢线，
                // 整体完成时间就被最慢那一片 gate 住（与安卓端一致）。
                let tailIsolated = Self.isTailRemaining(remaining: max(total - pool.downloaded(), 0),
                                                        lanes: lanes)
                let windowNow = limiter.currentWindow
                board.syncWindow(current: windowNow,
                                 increases: limiter.increases,
                                 decreases: limiter.decreases,
                                 peak: limiter.peakWindow)
                while active.current < windowNow, limiter.canDispatch(inflight: active.current) {
                    // 此刻实际可用的并发额度：被限流的通道要临时降额，
                    // 免得在同一根已经饱和的线路上继续加压、越限越死。
                    let quota = channels.reduce(0) { partial, channel in
                        if channel.throttled || board.penalty(of: channel.name) > 0 {
                            return partial + max(1, perChannelQuota / 2)
                        }
                        return partial + perChannelQuota
                    }
                    if active.current >= quota { break }

                    guard let work = nextWork(pool: pool, live: active.current, lanes: lanes, total: total) else { break }
                    let channelIndex = pickChannel(channels, roundRobin: roundRobin, excludeThrottled: tailIsolated)
                    let channel = channels[channelIndex]
                    roundRobin = (roundRobin + 1) % channels.count

                    let laneId = laneCounter.next()
                    // 先登记一条 pending，让面板立刻能看到「这条车道已就位」
                    board.update(LaneSnapshot(laneId: laneId,
                                              routeName: channel.name,
                                              url: channel.current.absoluteString,
                                              start: work.start,
                                              end: work.end,
                                              downloaded: 0,
                                              speedBytesPerSecond: 0,
                                              state: .pending,
                                              attempt: 1,
                                              lastStatus: nil))

                    limiter.noteDispatch()
                    active.increment()
                    assigned = true
                    let capturedChannels = channels
                    group.addTask { [self] in
                        await runSlice(laneId: laneId,
                                       channel: channel,
                                       channels: capturedChannels,
                                       initial: work,
                                       pool: pool,
                                       lanes: lanes,
                                       total: total,
                                       sink: sink,
                                       ledger: ledger,
                                       accumulator: accumulator,
                                       board: board,
                                       watchdog: watchdog,
                                       limiter: limiter)
                        board.remove(laneId)
                        // worker 自己结算并发名额：调度循环永远不需要
                        // 阻塞收割（group.next() 等一个 worker 干到退出
                        // 才返回 —— 那会让整条下载退化成单连接）
                        active.decrement()
                    }
                }

                // 2) 完成判定：所有 worker 都收工、且池子里再也切不出新活儿。
                //
                // 注意要把「正在退避的区间」算作「还有活儿」：否则一个失败片
                // 正在退避、恰好所有 worker 都收工的那一刻，会被误判成完成而提前退出，
                // 最后文件缺一块（下面的 size 校验会抛 incomplete，等于白下）。
                if active.current == 0,
                   pool.deferredCount() == 0,
                   nextWork(pool: pool, live: 0, lanes: lanes, total: total) == nil {
                    break
                }

                // 3) 没活儿可派：等一小会儿再评估，别忙等烧 CPU。
                // 如果只是「区间都在失败退避中」，等的时间要跟退避对齐，
                // 否则会空转几十轮；其余情况按尾段/非尾段收紧窗口。
                if !assigned {
                    let deferred = pool.deferredCount()
                    if deferred > 0 {
                        // 退避中的片还没到期：睡到最近一片到期（封顶 250ms）
                        try await Task.sleep(for: .milliseconds(120))
                    } else {
                        let tail = Self.isTailRemaining(remaining: max(total - pool.downloaded(), 0),
                                                        lanes: lanes)
                        try await Task.sleep(for: .milliseconds(tail ? 25 : 60))
                    }
                }
            }
            // 取消时把还在跑的子任务一起掐掉，别让它们继续占用连接
            if isCancelled || inflight.isCancelling { group.cancelAll() }
        }

        if isCancelled { throw DownloadError.cancelled }
        if sink.failed { throw DownloadError.incomplete }

        // 完整性校验：不只是「文件大小对」，而是「每个字节恰好被写过一次」。
        //
        // 老实现只有 size == total 这一句，而总量相等并不能保证内容正确
        //（重复写一段 + 漏写一段，总量照样相等）——
        // 症状就是「能下完但解压不了」。
        //
        // 不过「校验不过就直接判死」有点粗暴：多数情况下只是个别区间因为
        // 连接抖动没落盘。这里补一轮**缺口修复** —— 把账本里还没覆盖的区间
        // 重新塞回池子再下一次，能救回来的就不该让用户重下几百 MB。
        var repairRound = 0
        while !ledger.isComplete() && repairRound < Self.maxRepairRounds {
            if isCancelled { throw DownloadError.cancelled }
            let gaps = ledger.gaps(limit: Self.maxRepairRanges)
            if gaps.isEmpty { break }
            repairRound += 1
            board.stalled = false
            // 重置失败计数：上一轮主循环可能已经攒满失败预算，
            // 不重置的话这一轮补漏的第一次失败就会直接掀桌。
            pool.resetFailures()

            gaps.forEach { gap in
                pool.putBack(Chunk(start: gap.lowerBound, end: gap.upperBound))
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                let repairActive = ConcurrencyCounter()
                let repairLimiter = AdaptiveConcurrency(ceiling: min(lanes, 32))
                let repairWatchdog = StallWatchdog(stallWindow: Self.stallWindow)
                var repairRoundRobin = 0
                var lastGapBytes = ledger.coveredBytes
                var lastGapAt = Date()

                while true {
                    if isCancelled || inflight.isCancelling { break }
                    checkpoint()

                    let coveredNow = ledger.coveredBytes
                    if coveredNow != lastGapBytes {
                        lastGapBytes = coveredNow
                        lastGapAt = Date()
                    } else if repairActive.current > 0,
                              Date().timeIntervalSince(lastGapAt) > 30 {
                        break   // 这一轮补漏没有进展，交给下一轮或最终报错
                    }

                    var dispatched = false
                    while repairActive.current < repairLimiter.currentWindow,
                          repairLimiter.canDispatch(inflight: repairActive.current) {
                        guard let work = pool.take() else { break }
                        let channel = channels[repairRoundRobin % channels.count]
                        repairRoundRobin += 1
                        repairLimiter.noteDispatch()
                        repairActive.increment()
                        dispatched = true
                        group.addTask { [self] in
                            await runSlice(laneId: 0,
                                           channel: channel,
                                           channels: channels,
                                           initial: work,
                                           pool: pool,
                                           lanes: min(lanes, 32),
                                           total: total,
                                           sink: sink,
                                           ledger: ledger,
                                           accumulator: accumulator,
                                           board: board,
                                           watchdog: repairWatchdog,
                                           limiter: repairLimiter)
                            repairActive.decrement()
                        }
                    }

                    if repairActive.current == 0 && pool.backlog == 0 { break }
                    if !dispatched {
                        try await Task.sleep(for: .milliseconds(repairActive.current == 0 ? 100 : 60))
                    }
                }
                group.cancelAll()
            }
        }

        let size = ((try? fm.attributesOfItem(atPath: writeURL.path))?[.size] as? Int64) ?? 0
        guard size == total, ledger.isComplete() else {
            // 校验不过：续传模式下保留半成品与账本，下次只补缺口；
            // 非续传模式（没有稳定半成品路径）才把半成品删掉，免得被误当成成品。
            if resume == nil { try? fm.removeItem(at: outURL) }
            throw DownloadError.incompleteDetailed(ledger.describe())
        }

        // 校验通过：半成品原子地挪到成品目录，并清掉续传记录
        if let resume {
            try? fm.removeItem(at: outURL)
            do {
                try fm.moveItem(at: resume.partURL, to: outURL)
            } catch {
                throw DownloadError.badResponse
            }
            store.discard(key: resume.key)
        }

        finished = true
        await accumulator.finish(downloaded: total)
        return outURL
    }

    // MARK: - 一个 worker 的生命周期

    /// 攥着一段区间，一小片一小片地取数据；取完就要新活儿，绝不空转。
    /// 重试走跨通道（首轮初始线、后续换线、末轮直连兜底），成功按实际通道归因。
    private func runSlice(laneId: Int,
                          channel: RouteChannel,
                          channels: [RouteChannel],
                          initial: Chunk,
                          pool: SlicePool,
                          lanes: Int,
                          total: Int64,
                          sink: WriteSink,
                          ledger: WriteLedger,
                          accumulator: ProgressAccumulator,
                          board: LaneBoard,
                          watchdog: StallWatchdog,
                          limiter: AdaptiveConcurrency) async {
        var current = initial

        while !isCancelled {
            // 被取消就立刻收工，不再取新数据
            if Task.isCancelled { return }

            let remaining = max(total - pool.downloaded(), 0)
            // 快通道按 BDP 取大片：摊薄每片一次 HTTP 往返的 RTT 税，尾段 QPS 也顺势降下来
            //（与安卓端一致，慢通道与未测速时近似无操作）。
            let want = Self.sliceWant(lanes: lanes, total: total, remaining: remaining,
                                      currentLen: Int(current.length),
                                      measuredSpeed: channel.measuredSpeed)
            let from = current.start
            let to = from + Int64(want) - 1

            if to < current.end {
                // 手里这段比一小片长：把「剩下的」还回池子。
                // 还回去之后必须立刻放弃对它的所有权 —— 也就是把 current
                // 收窄成刚切出来的这一小片，绝不再引用后半段。
                // 否则同一段字节会同时存在于池子和这个 worker 手上，
                // 池子再把它派给别人，两个 worker 就会下到重叠区间、重复写盘。
                pool.putBack(Chunk(start: to + 1, end: current.end))
                board.bumpSplit()
            }
            current = Chunk(start: from, end: to)

            // 每真正派发一片就记一笔，让「完成 / 累计」两个数对得上
            //（放 worker 里而不是 spawn 处：worker 会自己续做几十片，
            //  只记 spawn 数的话「累计」会远小于「完成」）
            board.bumpTotalSlice()

            // 派活前先更新看板：面板能立刻看到这条车道换到了哪一段
            board.update(LaneSnapshot(laneId: laneId,
                                      routeName: channel.name,
                                      url: channel.current.absoluteString,
                                      start: from,
                                      end: to,
                                      downloaded: 0,
                                      speedBytesPerSecond: channel.measuredSpeed,
                                      state: .downloading,
                                      attempt: 1,
                                      lastStatus: 206))
            board.activeUrl = channel.current.absoluteString

            do {
                let (outcome, winner, finalURL) = try await fetchSlice(chunk: Chunk(start: from, end: to),
                                                                        pool: pool,
                                                                        board: board,
                                                                        laneId: laneId,
                                                                        channel: channel,
                                                                        channels: channels,
                                                                        limiter: limiter,
                                                                        tailIsolated: Self.isTailRemaining(remaining: remaining,
                                                                                                           lanes: lanes))
                if !outcome.data.isEmpty {
                    sink.write(outcome.data, at: from)
                    // 登记覆盖区间：只有**真的写进文件**的字节才算数。
                    // 账本会在这里发现重复写入（overlaps > 0），收尾校验据此判死；
                    // 进度也按「新覆盖的字节」推进，重复写入不虚涨。
                    let newlyCovered = ledger.record(start: from,
                                                     endInclusive: from + Int64(outcome.data.count) - 1)
                    pool.recordDone(newlyCovered)
                    watchdog.noteProgress(Int64(outcome.data.count))
                    await accumulator.advance(newlyCovered)
                    winner.observe(elapsed: outcome.elapsed, bytes: Int64(outcome.data.count))
                    board.bumpDoneSlice()
                    board.reward(winner.name)
                    // 顺畅通关：AIMD 加性增，窗口慢慢往上爬
                    limiter.noteSuccess(speed: winner.measuredSpeed)

                    let seconds = max(outcome.elapsed, 0.001)
                    board.update(LaneSnapshot(laneId: laneId,
                                              routeName: winner.name,
                                              url: finalURL.absoluteString,
                                              start: from,
                                              end: to,
                                              downloaded: Int64(outcome.data.count),
                                              speedBytesPerSecond: Double(outcome.data.count) / seconds,
                                              state: .done,
                                              attempt: 1,
                                              lastStatus: 206))
                }
                if outcome.data.count < want {
                    // 没取满（连接中途断了）：把缺的那一段还回池子重取，绝不丢数据。
                    // 带一点短退避，避免同一条坏连接立刻又把缺片捞回去。
                    let missing = Chunk(start: from + Int64(outcome.data.count), end: to)
                    if missing.length > 0 { pool.putBack(missing, backoff: 0.25) }
                }
            } catch {
                if isCancelled || Task.isCancelled { return }
                if (error as? DownloadError) == .cancelled { return }

                // 这一片重试耗尽（已跨通道试过）：在面板上标红，还回池子。
                // WriteSink.failed 只给磁盘写失败用：网络失败就标记的话，
                // 后面所有 worker 写的数据都会被静默丢弃（upstream 的教训）。
                // 失败预算耗尽才标记，调度循环的 90s 无进展保护也会兜底。
                // 判断这片是不是因为服务端限流才失败的（限流要退避更久 + 砍 AIMD 窗口）
                var isThrottled = false
                if let downloadError = error as? DownloadError, case .throttled = downloadError {
                    isThrottled = true
                }

                board.update(LaneSnapshot(laneId: laneId,
                                          routeName: channel.name,
                                          url: channel.current.absoluteString,
                                          start: from,
                                          end: to,
                                          downloaded: 0,
                                          speedBytesPerSecond: 0,
                                          state: .failed,
                                          attempt: Self.maxAttempts,
                                          lastStatus: { if case let .throttled(code, _) = (error as? DownloadError) { return code }; return nil }()))
                // 失败的那一段必须还回池子，否则文件会缺一块。
                //
                // 关键：带退避还回，而不是插到队首让它立刻被重取 ——
                // 老实现就是那样把自己憋成「限流时疯狂撞墙、下载卡死」的。
                // 限流退避更久，并且顺手把 AIMD 窗口砍一刀。
                let backoff: TimeInterval = isThrottled ? 1.2 : 0.4
                pool.putBack(Chunk(start: from, end: to), backoff: backoff)
                if isThrottled {
                    limiter.noteThrottle()
                } else {
                    limiter.noteFailure()
                }
                if pool.failureCount() > Self.maxSliceFailures(lanes: lanes) {
                    sink.markFailed()
                }
                return
            }

            // 这一小片已经干完，回池子重新要活儿。
            //
            // 注意这里传的 live = 1：代表「我自己还占着一条连接」。
            // 老实现传的是 0，而 splitTail 里 `if live <= 0 { return null }`，
            // 于是 worker 自己续做时**永远切不动尾部区间** —— 收尾阶段
            // 池子一空，所有 worker 就只能干等，退化成单连接爬完最后一段。
            guard let next = nextWork(pool: pool, live: 1, lanes: lanes, total: total) else { return }
            current = next
        }
    }

    /// 分配下一段活儿：优先拿现成的；拿不到而连接还闲着，就从末尾切一刀。
    ///
    /// `live` 是「当前还有多少条连接在跑」。注意它**不能传 0**：
    /// `splitTail` 里 `if live <= 0 { return nil }`，传 0 就等于禁止切分，
    /// 收尾阶段池子一空就再也派不出活儿。调用方至少应传 1（代表自己这条在跑）。
    private func nextWork(pool: SlicePool, live: Int, lanes: Int, total: Int64) -> Chunk? {
        if let ready = pool.take() { return ready }
        guard live < lanes else { return nil }
        let remaining = max(total - pool.downloaded(), 0)
        return pool.splitTail(live: max(live, 1),
                              target: sliceTarget(lanes: lanes, total: total, remaining: remaining))
    }

    /// 一个区间一次取多少：剩余数据越多取越大（少发请求），
    /// 越接近尾声取越小（让所有连接都能分到收尾的活儿）。
    private func sliceTarget(lanes: Int, total: Int64, remaining: Int64) -> Int {
        let share = (max(remaining, 0) / Int64(lanes * 4)) * 2
        return Int(min(max(share, Self.minSliceTarget), Self.maxSliceTarget))
    }

    /// 找出「已覆盖区间」的补集 —— 也就是续传时真正要下的那些缺口。
    static func gaps(total: Int64, covered: [ClosedRange<Int64>]) -> [ClosedRange<Int64>] {
        guard total > 0 else { return [] }
        let sorted = covered
            .filter { $0.upperBound >= $0.lowerBound && $0.lowerBound >= 0 && $0.upperBound < total }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !sorted.isEmpty else { return [0...(total - 1)] }
        var result: [ClosedRange<Int64>] = []
        var cursor: Int64 = 0
        for range in sorted {
            if range.lowerBound > cursor {
                result.append(cursor...(range.lowerBound - 1))
            }
            cursor = max(cursor, range.upperBound + 1)
            if cursor >= total { break }
        }
        if cursor < total { result.append(cursor...(total - 1)) }
        return result
    }

    /// 是否进入「尾段」：剩余数据已经不够把所有 lane 按最小片喂饱。
    ///
    /// 这个点之后并行度必然坍缩（剩 1MB、lanes=64 时最多十几条有活干），
    /// 策略必须从「带宽叠加」切换成「别让慢线拖尾」：只派给快通道、
    /// 单片按 BDP 取大、慢片超时让位。阈值自适应 lanes，不用额外常数
    ///（与安卓端 `isTailRemaining` 一致）。
    private static func isTailRemaining(remaining: Int64, lanes: Int) -> Bool {
        remaining < Int64(lanes) * minSliceTarget * 2
    }

    /// 单片按带宽时延积（BDP）保底：在快通道上别用 64KB 小片去交 RTT 税。
    ///
    /// 每片至少覆盖 `tailBdpSeconds` 秒的传输量（按该通道实测速度），
    /// 否则 64KB 在 150ms RTT 下有效吞吐只有体感的 1/10，还顺手把 QPS
    /// 打到 Azure/Cloudflare 的 429/503 线上。慢通道不受影响（floor 小），
    /// 初始未测速时 measuredSpeed≈1 也近似无操作。调用方仍需以 currentLen 为上限
    ///（与安卓端 `bdpFloorBytes` 一致）。
    private static let tailBdpSeconds = 0.25

    private static func bdpFloorBytes(measuredSpeed: Double) -> Int {
        Int(min(max(measuredSpeed * tailBdpSeconds, 0), Double(maxSliceTarget)))
    }

    /// 结合剩余量与通道速度算出本片要多少字节（与安卓端 `sliceWant` 一致）。
    private static func sliceWant(lanes: Int, total: Int64, remaining: Int64,
                                  currentLen: Int, measuredSpeed: Double) -> Int {
        let base = Int(min(max((max(remaining, 0) / Int64(lanes * 4)) * 2,
                               minSliceTarget), maxSliceTarget))
        let want = max(base, min(bdpFloorBytes(measuredSpeed: measuredSpeed), currentLen))
        return min(max(want, 1), max(currentLen, 1))
    }

    /// 单片可接受的最低平均速度：低于它就不是慢、是卡住，直接超时让位
    ///（与安卓端 `MIN_ACCEPTABLE_SLICE_SPEED` 一致）。
    private static let minAcceptableSliceSpeed: Int64 = 50 * 1024

    /// 单片总耗时上限（毫秒）：按最低可接受速度推导，另设 20s 下限兜住小片。
    /// 64KB~1MB 片约 20s，4MB 片约 80s。命中后抛 `incomplete` 走既有重试换线，
    /// 把区间让给快通道，而不是攥着尾段干等（与安卓端 `sliceTimeoutMs` 一致）。
    private static func sliceTimeoutMs(length: Int64) -> Int64 {
        max(20_000, length * 1_000 / minAcceptableSliceSpeed)
    }

    /// 按实时吞吐加权挑通道：快的多干活，慢的也有活（带宽叠加）。
    ///
    /// 老实现是贪心取最快，导致所有 lane 挤在同一条通道/同一 session，
    /// 既打爆单镜像（429/503）又浪费其它通道带宽，还让多 session 形同虚设。
    /// 上游重写时退回了贪心，这里恢复加权（与安卓端一致）。
    ///
    /// - Parameter excludeThrottled: 尾段隔离：直接排除被限流通道（而不是只降权），
    ///   剩的不够全员分时不再给慢线派尾片。全部被排除时退回普通加权保底不断流。
    private func pickChannel(_ channels: [RouteChannel], roundRobin: Int,
                             excludeThrottled: Bool = false) -> Int {
        guard channels.count > 1 else { return 0 }
        var total: Double = 0
        var weights: [Double] = []
        weights.reserveCapacity(channels.count)
        for ch in channels {
            if excludeThrottled, ch.throttled {
                weights.append(0)
                continue
            }
            var w = max(ch.measuredSpeed, 1)
            // 被限流的通道降权 90%，而不是直接剔除（保底不断流）
            if ch.throttled { w *= 0.1 }
            weights.append(w)
            total += w
        }
        // 尾段隔离把全部通道都排除时：退回普通加权，保底不断流
        if total <= 0 {
            if excludeThrottled { return pickChannel(channels, roundRobin: roundRobin) }
            return roundRobin % channels.count
        }
        var r = Double.random(in: 0..<total)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return i }
        }
        return weights.indices.max(by: { weights[$0] < weights[$1] }) ?? 0
    }

    // MARK: - 取一小片

    /// 真正发起 Range 请求，把这一小片读进内存。
    ///
    /// 失败时按指数退避重试；命中 429/503 时读 `Retry-After` 退避 ——
    /// Azure 单 Blob 有「约 60 MiB/s 或 500 请求/秒」的目标，超了就是 503 ServerBusy，
    /// 官方建议用指数退避而不是硬顶，否则会被越限越死。
    ///
    /// 多线路重试语义（本次修复的核心）：
    ///  - attempt 0 用初始通道主地址；
    ///  - attempt 1 起重新加权选通道（避开刚失败的那条），试另一条线的 primary；
    ///  - 最后一次强制走直连兜底。
    /// 全程只用局部变量选地址，不再变异共享 `RouteChannel`，并发重试互不踩。
    /// 返回成功时的实际通道，调用方按它做 `observe/reward`，限流标记不张冠李戴。
    private func fetchSlice(chunk: Chunk,
                            pool: SlicePool,
                            board: LaneBoard,
                            laneId: Int,
                            channel: RouteChannel,
                            channels: [RouteChannel],
                            limiter: AdaptiveConcurrency? = nil,
                            tailIsolated: Bool = false) async throws -> (SliceOutcome, RouteChannel, URL) {
        var lastError: Error = DownloadError.badResponse
        let direct = channels.first(where: { $0.name == DownloadRoute.direct.name })
        // 限流撞了两回就直接放弃这一片：继续退避 = 攥着区间干等，
        // 整条下载都陪着这条被限流的通道停摆。让位给调度器重新派。
        var throttledCount = 0
        // 这一片已经试过的通道名：重试时优先换没试过的，避免在同一根坏线上反复撞
        var tried: Set<String> = [channel.name]

        for attempt in 0..<Self.maxAttempts {
            // 每轮重试前先看有没有被取消
            try Task.checkCancellation()
            if isCancelled || inflight.isCancelling { throw DownloadError.cancelled }

            // 选本轮实际通道：首轮用初始，后续换线，最后兜底直连
            let active: RouteChannel
            let targetURL: URL
            if attempt == 0 || channels.count <= 1 {
                active = channel
                targetURL = active.primary
            } else if attempt >= Self.maxAttempts - 1 {
                if let direct {
                    active = direct
                    targetURL = direct.primary
                } else {
                    // plan 里没有直连（如直连测速太慢被剔除）：用该通道自带的兜底（即直连 URL）。
                    // 此时成功不代表镜像恢复，见下面 `isFallback` 分支。
                    active = channels[Self.pickRetryIndex(channels: channels, excluding: Array(tried),
                                                          excludeThrottled: tailIsolated)]
                    targetURL = active.fallback
                }
            } else {
                active = channels[Self.pickRetryIndex(channels: channels, excluding: Array(tried),
                                                      excludeThrottled: tailIsolated)]
                targetURL = active.primary
            }
            tried.insert(active.name)
            // 兜底地址即直连：成功不清除镜像的限流标记，归因清晰。
            let isFallbackURL = targetURL != active.primary

            // 每次真正发出 HTTP 请求都占一个速率闸名额（重试也算），
            // 否则遇到 429 疯狂重试时速率闸形同虚设。
            limiter?.noteDispatch()

            var request = URLRequest(url: targetURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            // 定稿后冻结：group 子任务闭包按值捕获，避免 `var` 捕获告警
            let finishedRequest = request

            let startedAt = Date()
            do {
                // 慢片超时：单片总耗时封顶，超时即放弃本片走换线重试，
                // 把区间让给快通道 —— 尾段不再被一条卡住的连接 gate 住。
                // 安卓端是在读循环里查 deadline；URLSession 整包返回，这里做成竞速超时，
                // 超时胜出时抛出的 incomplete 会走既有重试换线，group 退出时顺带掐掉慢请求。
                let timeoutMs = Self.sliceTimeoutMs(length: chunk.length)
                let (data, response): (Data, URLResponse) = try await withThrowingTaskGroup(of: (Data, URLResponse).self) { grp in
                    grp.addTask { [self] in try await self.send(finishedRequest, on: active.session) }
                    grp.addTask {
                        try await Task.sleep(for: .milliseconds(Int(timeoutMs)))
                        throw DownloadError.incomplete
                    }
                    guard let first = try await grp.next() else { throw DownloadError.incomplete }
                    grp.cancelAll()
                    return first
                }
                guard let http = response as? HTTPURLResponse else { throw DownloadError.badResponse }

                switch http.statusCode {
                case 206:
                    // **关键校验**：确认服务器真的按我们请求的区间返回。
                    //
                    // 有些镜像/CDN 对 Range 支持不完整（忽略部分区间、或从自己
                    // 理解的偏移开始返回），返回码仍是 206。不校验 Content-Range
                    // 的话，取到的数据会被写到错误偏移上 —— 下载"成功"、文件大小
                    // 也对，但内容错了，表现就是「能下完但解压不了」。
                    guard Self.contentRangeMatches(http,
                                                   expectedStart: chunk.start,
                                                   expectedEnd: chunk.end) else {
                        throw DownloadError.noRangeSupport
                    }
                    // 兜底（直连）成功不代表镜像恢复，不清除镜像限流标记
                    if !isFallbackURL { active.setThrottled(false) }
                    guard !data.isEmpty else { throw DownloadError.incomplete }
                    return (SliceOutcome(data: data, elapsed: Date().timeIntervalSince(startedAt)), active, targetURL)
                case 200:
                    // 服务器忽略了 Range（回 200 全量）。这多半意味着这条地址
                    // 不支持分段：交给重试逻辑换条线（下轮自动选别的通道）。
                    // 唯一能救的是 start==0 的片 —— 数据本来就是从 0 开始的，
                    // 截取前 want 字节照样是对的（URLSession 已把整个响应读进来，
                    // prefix 只是截取引用段，不会二次拷贝整个文件）。
                    guard chunk.start == 0 else { throw DownloadError.noRangeSupport }
                    if !isFallbackURL { active.setThrottled(false) }
                    let head = data.prefix(Int(chunk.length))
                    guard head.count > 0 else { throw DownloadError.incomplete }
                    return (SliceOutcome(data: Data(head), elapsed: Date().timeIntervalSince(startedAt)), active, targetURL)
                case 429, 503:
                    pool.recordThrottle()
                    board.bumpThrottle()
                    // 通道级降额：不是简单降权重，而是直接把它判为「被限流」，
                    // 调度器下一轮就会削它的并发，避免越限越死。
                    active.setThrottled(true)
                    board.penalize(active.name)
                    throw DownloadError.throttled(code: http.statusCode,
                                                  retryAfter: Self.retryAfter(http))
                default:
                    throw DownloadError.badResponse
                }
            } catch {
                // 取消优先级最高：无论是标志位还是 Task 取消，都直接向外抛
                if isCancelled || inflight.isCancelling { throw DownloadError.cancelled }
                if error is CancellationError { throw error }
                if (error as? DownloadError) == .cancelled { throw DownloadError.cancelled }
                if (error as NSError).code == NSURLErrorCancelled { throw DownloadError.cancelled }

                lastError = error
                board.bumpRetry()
                if attempt >= Self.maxAttempts - 1 { break }

                // 不支持 Range 的地址：下轮循环自动换线重试，不退避 —— 这是地址选错了，
                // 不是服务器忙（attempt 照常消耗，单地址轮到自己时也能正常退出）。
                // endpoints 不可变，不再原地轮换，换线由选路负责。
                if (error as? DownloadError) == .noRangeSupport {
                    continue
                }

                if case .throttled(_, _) = (error as? DownloadError) {
                    // 被限流：把这条通道的权重降下来，让活儿分给别人
                    active.demote()
                    throttledCount += 1
                    if throttledCount >= 2 {
                        // 连着两次限流：这条通道眼下进不去，别攥着区间长睡，
                        // 直接放弃这一片 —— 调度器马上会把活儿派给健康通道。
                        pool.recordFailure()
                        throw error
                    }
                }

                // 重试状态同步到面板：用户能看到「车道 #3 正在第 2 次重试 / 上一次 503」
                board.update(LaneSnapshot(laneId: laneId,
                                          routeName: active.name,
                                          url: targetURL.absoluteString,
                                          start: chunk.start,
                                          end: chunk.end,
                                          downloaded: 0,
                                          speedBytesPerSecond: 0,
                                          state: .retrying,
                                          attempt: attempt + 2,
                                          lastStatus: { if case let .throttled(code, _) = (error as? DownloadError) { return code }; return nil }()))

                // 退避期间也要能被取消打断
                try await Task.sleep(for: .milliseconds(Self.backoffMillis(attempt: attempt, error: error)))
            }
        }

        pool.recordFailure()
        throw lastError
    }

    /// 校验 `Content-Range` 是否真的对应我们请求的字节区间。
    ///
    /// 形如 `bytes 4194304-8388607/10485760`。
    ///
    /// 两道检查：
    ///  1. 起止偏移必须与请求完全一致 —— 防止镜像「自作主张」返回别的区间
    ///     （返回码仍是 206），那种数据写到当前偏移就是静默损坏；
    ///  2. 总长度（`/` 后面那段）应当大于我们请求的终点 —— 防止下载过程中
    ///     源端文件被替换（GitHub 上很少见，但镜像缓存错乱时会遇到）。
    ///
    /// 拿不到头时返回 false：宁可换一条通道重试，也不冒险写错位置。
    private static func contentRangeMatches(_ http: HTTPURLResponse,
                                            expectedStart: Int64,
                                            expectedEnd: Int64) -> Bool {
        guard let raw = http.value(forHTTPHeaderField: "Content-Range")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return false }

        // 期望格式：bytes <start>-<end>/<total>（total 也可能是 *）
        var spec = raw
        if spec.lowercased().hasPrefix("bytes") {
            spec = String(spec.dropFirst("bytes".count))
        }
        spec = spec.trimmingCharacters(in: .whitespaces)
        if spec.hasPrefix("=") { spec = String(spec.dropFirst()).trimmingCharacters(in: .whitespaces) }
        guard !spec.isEmpty else { return false }

        let parts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let rangePart = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let dashParts = rangePart.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard dashParts.count == 2,
              let start = Int64(dashParts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(dashParts[1].trimmingCharacters(in: .whitespaces)) else { return false }

        guard start == expectedStart, end == expectedEnd else { return false }

        if parts.count == 2 {
            let totalPart = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if totalPart != "*" {
                guard let total = Int64(totalPart), total > expectedEnd else { return false }
            }
        }
        return true
    }

    /// 重试选路：加权随机，但排除刚失败的那条线（单通道时无处可避，直接返回 0）。
    ///
    /// 排除是为了“首失败即换线”：一直加权随机仍可能连抽同一条坏线，
    /// 白白浪费 `maxAttempts` 里宝贵的第二次机会。
    ///
    /// - Parameter excluding: 本片已经试过的通道名，优先避开（全试过则退回普通加权）。
    /// - Parameter excludeThrottled: 尾段隔离时一并排除被限流通道（与安卓端一致）。
    private static func pickRetryIndex(channels: [RouteChannel], excluding names: [String],
                                       excludeThrottled: Bool = false) -> Int {
        guard channels.count > 1 else { return 0 }
        let excluded = Set(names)
        var total: Double = 0
        var weights: [Double] = []
        weights.reserveCapacity(channels.count)
        for ch in channels {
            if excluded.contains(ch.name) {
                weights.append(0)
                continue
            }
            if excludeThrottled, ch.throttled {
                weights.append(0)
                continue
            }
            var w = max(ch.measuredSpeed, 1)
            if ch.throttled { w *= 0.1 }
            weights.append(w)
            total += w
        }
        // 被排除后无可用（全试过了）：退回普通加权，至少还能兜底
        if total <= 0 {
            return DownloadEngine.pickWeightedIndex(channels: channels.map { ($0.measuredSpeed, $0.throttled) })
        }
        var r = Double.random(in: 0..<total)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return i }
        }
        return weights.indices.max(by: { weights[$0] < weights[$1] }) ?? 0
    }

    /// 重试选路（排除单条通道，旧签名，内部转调新实现）
    private static func pickRetryIndex(channels: [RouteChannel], excluding name: String,
                                       excludeThrottled: Bool = false) -> Int {
        pickRetryIndex(channels: channels, excluding: [name], excludeThrottled: excludeThrottled)
    }

    /// 纯权重抽样（无排除），供重试回退路径复用，避免实例方法在 static 上下文里不可用。
    private static func pickWeightedIndex(channels: [(speed: Double, throttled: Bool)]) -> Int {
        var total: Double = 0
        var weights: [Double] = []
        for ch in channels {
            var w = max(ch.speed, 1)
            if ch.throttled { w *= 0.1 }
            weights.append(w)
            total += w
        }
        guard total > 0 else { return 0 }
        var r = Double.random(in: 0..<total)
        for (i, w) in weights.enumerated() {
            r -= w
            if r <= 0 { return i }
        }
        return 0
    }

    // MARK: - 单连接下载（不支持分段 / 体积太小）

    /// 单连接下载：带**真实进度**（totalBytesWritten 驱动），
    /// 并在收尾用服务端声明的 Content-Length 校验完整性。
    ///
    /// 老实现用 `session.download(for:)`：拿不到任何中间进度（界面只能转圈），
    /// 而且断流时可能安静返回一个截断文件。现在换成 delegate 驱动。
    private func downloadSingle(url: URL,
                                into outURL: URL,
                                expectedTotal: Int64,
                                progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (url: URL, bytes: Int64) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        let downloader = SingleDownloader(destination: outURL,
                                          expectedTotal: expectedTotal,
                                          onProgress: progress)
        let session = URLSession(configuration: config, delegate: downloader, delegateQueue: nil)
        lock.lock(); sessions.append(session); lock.unlock()
        defer {
            lock.lock(); sessions.removeAll { $0 === session }; lock.unlock()
            session.invalidateAndCancel()
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        inflight.register(task)

        let result: (URL, Int64)
        do {
            result = try await downloader.run { task.resume() }
        } catch {
            inflight.release(task)
            throw error
        }
        inflight.release(task)
        if isCancelled { throw DownloadError.cancelled }
        return (result.0, result.1)
    }

    // MARK: - 起步请求（解析 + 体积 + 首块，一次拿全）

    /// 发一个 `Range: bytes=0-<bootstrapBytes-1>` 的请求：
    ///  - URLSession 自动跟随 302，`response.url` 就是**签名后的真实地址**；
    ///  - `Content-Range` 给出文件总长；
    ///  - 首块数据直接留给分段引擎，省掉一次重复下载。
    ///
    /// 这是整条链路的提速关键：老实现「解析 → 探通道 → 探体积 → 下载」四段串行，
    /// 每段都新建 URLSession（= 重新握手）；现在只剩这一个往返。
    private func fetchBootstrap(url: URL,
                                authToken: String?,
                                headers: [String: String]) async throws -> EngineBootstrap? {
        if isCancelled { throw DownloadError.cancelled }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        let collector = BootstrapCollector(cap: Int(Self.bootstrapBytes))
        let session = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=0-\(Self.bootstrapBytes - 1)", forHTTPHeaderField: "Range")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // Token 只发给 GitHub 自己的域名，绝不外泄给镜像
        if let authToken, Self.isGitHubHost(url.host) {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = session.dataTask(with: request)
        inflight.register(task)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<EngineBootstrap?, Never>) in
                collector.begin(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        inflight.release(task)
        if isCancelled { throw DownloadError.cancelled }
        if Task.isCancelled { throw CancellationError() }
        return result
    }

    /// 只有 GitHub 自己的域名才允许附带 Token
    private static func isGitHubHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host == "githubusercontent.com"
            || host.hasSuffix(".githubusercontent.com")
    }

    // MARK: - 常量

    /// 一次分片请求的目标字节数下限。
    ///
    /// 调到 64KB 是为了收尾阶段：剩余量少时，如果每片还按 128KB 取，
    /// 最后那几 MB 只能被一两条连接瓜分，速度会「断崖式」掉下去。
    /// 64KB 让尾段能摊给更多连接，末段也能贴着带宽跑完。
    private static let minSliceTarget: Int64 = 64 * 1024
    /// 分片大小上限：从 4MB 降到 1MB —— 这是**大文件能否正常下载**的关键。
    ///
    /// 每个 worker 在处理分片时会把整个分片读进内存，
    /// 所以分片上限直接决定「每条连接吃多少内存」：
    ///   4MB × 128 并发 = 512MB  → iOS 上直接被杀进程
    ///   1MB × 128 并发 = 128MB  → 安全
    ///
    /// 1MB 片在 100MB+ 的文件上依然只占 1% 的分片数量，
    /// 不会因为请求变多而明显拖慢速度（RTT 摊薄在 1MB 上已经足够）。
    private static let maxSliceTarget: Int64 = 1 * 1024 * 1024
    /// 小于这个体积不做分段：切来切去不如一条连接拉完
    private static let minChunkedTotal: Int64 = 4 * 1024 * 1024
    /// 起步请求一次拿多少字节：够判断分段能力、够让进度条立刻动起来，
    /// 又不至于在小文件上白拉太多。256KB 在 4MB 门槛下最多占 6%。
    private static let bootstrapBytes: Int64 = 256 * 1024
    private static let maxAttempts = 3
    private static let userAgent = "ArtifactBoost"

    /// 单片耗尽重试（已跨通道）后不立刻毒化整文件，攒够这么多才判死。
    /// 取 `max(20, lanes*2)`：flaky 网络下零星失败能被别的 lane 捡回重下，
    /// 签名过期/全线 400 时又能较快收敛去走 Manager 层的直连回退，而不是空转。
    /// （常驻 worker 失败时让位退出，无进展保护 90s 也会兜底，双保险。）
    fileprivate static func maxSliceFailures(lanes: Int) -> Int {
        max(20, lanes * 2)
    }

    /// 引擎并发上限（与 AccelerationSettings.maxConnections 一致）。
    /// 注意这只是**上限**：真正的在飞并发由 AdaptiveConcurrency 的 AIMD 窗口决定，
    /// 服务器撑不住时引擎会自己降下来，不会再出现「128 条连接一起撞限流」。
    private static let maxLanes = 128

    /// 卡住看门狗窗口（秒）：有连接在飞、但超过这个时间一个字节都没落盘，
    /// 就判定卡住并强制重建所有在飞连接。CDN 的心跳字节会让 URLSession
    /// 的 idle 超时永不触发，所以必须用「有没有真的写进文件」来判。
    ///
    /// 从 12s 收紧到 8s：每个分片请求现在都有总时长上限兜底，
    /// 8 秒没有任何字节落盘已经能确定是卡住，再等下去只是白白占着连接。
    private static let stallWindow: TimeInterval = 8

    /// 缺口修复的最大轮数。
    ///
    /// 主循环跑完后若账本显示还有没覆盖的字节，就把缺口重新派下去再跑一轮。
    /// 3 轮足够吃掉「个别区间因连接抖动没落盘」这类问题；
    /// 若 3 轮还补不上，多半是源端真有问题，继续重试只是浪费用户时间。
    private static let maxRepairRounds = 3

    /// 单轮修复最多处理多少个缺口区间（防止极端碎片化时爆炸）
    private static let maxRepairRanges = 512

    /// 按可用内存约束并发数。
    ///
    /// 分段下载里每个 worker 都会把一个分片整个放进内存，分片上限是
    /// `maxSliceTarget`（1MB）。用户把并发设到 128 时：
    ///
    ///     128 × 1MB = 128MB 缓冲
    ///
    /// 加上 URLSession 自身的缓冲与已分配的堆，低内存设备上依然可能紧张。
    /// 这里按「当前可用内存 / 每条连接预算」算出安全并发，再与用户设的上限取小。
    /// 宁可少开几条连接（速度略降），也不能让整个下载被杀。
    private static func safeLanes(requested: Int, bytesPerLane: Int) -> Int {
        // 再省也得留 2 条连接，否则等于退化成单线程
        let minLanes = 2
        guard requested > minLanes else { return max(requested, 1) }

        let available = usableMemoryBytes()
        guard available > 0 else { return requested }

        let perLane = max(Int64(bytesPerLane), 1)
        let byMemory = Int(available / perLane)
        return min(max(byMemory, minLanes), requested)
    }

    /// 估算可用内存字节数（只敢用一半，另一半留给系统与框架）。
    ///
    /// 这里刻意**不**用 `os_proc_available_memory()`：
    /// 它在 iOS 模拟器上不可用，而 CI 会同时构建真机与模拟器两个目标，
    /// 用了会让模拟器构建直接编译失败。
    /// 改用「物理内存的 1/8」作为保守估计 —— 对主流 iPhone 足够安全
    ///（3GB 设备的 1/8 = 384MB，配 1MB 分片能撑满 128 并发上限）。
    private static func usableMemoryBytes() -> Int64 {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        guard physical > 0 else { return 0 }
        return physical / 8
    }

    /// 把 fd soft limit 提到 hard 上限：每条连接占一个 fd，
    /// 并发放开到 128+ 之后，默认 soft limit（常见 256）会在建连一半时报
    /// 「too many open files」。提升自己的 soft 到 hard 不需要任何特权。
    /// Linux（typecheck 环境）没有 Darwin 的 rlimit 初始化器，按平台编译。
    private static func raiseFileLimit() {
        #if canImport(Darwin)
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        // 注意：Swift 不导入 Darwin 的 RLIM_INFINITY 宏（它带 C 类型转换，
        // 展开值是 ((uint64_t)1 << 63) - 1），只能自己写这个数。
        let rlimInfinity: rlim_t = 0x7FFF_FFFF_FFFF_FFFF
        let target: rlim_t = limit.rlim_max == rlimInfinity
            ? rlimInfinity
            : min(limit.rlim_max, 8192)
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        setrlimit(RLIMIT_NOFILE, &limit)
        #endif
    }

    /// 渐进建连的策略已由 `AdaptiveConcurrency`（AIMD 窗口）接管：
    /// 起始窗口 16，顺畅时加性增、限流时乘性减，不再需要时间片式的固定爬坡。
    /// 这里保留常量说明，方便对照旧行为。

    private static func retryAfter(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              let seconds = Double(raw), seconds >= 0, seconds <= 600 else { return nil }
        return seconds
    }

    /// 指数退避 + 抖动；限流时优先听服务端的 Retry-After。
    ///
    /// 限流退避上限压到 1.5s：worker 命中限流后要么很快回来、要么直接让位，
    /// 绝不攥着区间长睡 —— 一次 Retry-After: 600 的限流不该让整条下载停十分钟。
    /// 真正的「降温」交给 AdaptiveConcurrency 砍窗口，不靠单条 worker 睡觉。
    private static func backoffMillis(attempt: Int, error: Error) -> Int {
        if case .throttled(_, let retryAfter) = (error as? DownloadError) {
            // 防雪崩：多个 worker 同时被限流时把退避时间错开
            let base = retryAfter ?? Double(1 << min(attempt, 4))
            return Int(min(max(base * (1 + Double.random(in: 0...0.25)), 0.25), 1.5) * 1000)
        }
        let base = Double(1 << min(attempt, 5)) * 250
        return Int(min(base * (1 + Double.random(in: 0...0.3)), 15_000))
    }
}

/// 落盘汇点：多个 worker 并发写同一个文件的不同偏移，用一把锁保护
private final class WriteSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private(set) var failed = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data, at offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !failed else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch {
            failed = true
        }
    }

    func markFailed() {
        lock.lock(); failed = true; lock.unlock()
    }
}

/// 取消标志：URLSession 回调可能来自任意线程
private final class CancelledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }

    func reset() {
        lock.lock(); flag = false; lock.unlock()
    }
}

/// 单调递增计数器（车道编号专用）。用锁而不是 `&+` 自增，
/// 免得并发调度时两条车道拿到同一个号。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}

/// 并发计数器：worker 结束时自己递减，调度循环只读。
/// 这样调度器**永远不需要阻塞等待某个 worker 退出** ——
/// 阻塞收割（group.next()）正是「整条下载退化成单连接」的元凶：
/// 调度器 spawn 了 1 条 worker 后区间就在它手里，池子是空的，
/// 阻塞收割会让调度器一直等到这条 worker 干完整个下载才醒。
private final class ConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.lock(); value += 1; lock.unlock() }
    func decrement() { lock.lock(); value -= 1; lock.unlock() }
    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// 在飞请求登记簿。
///
/// `URLSession.data(for:)` 挂起时协程取消并不会让它自动返回 ——
/// 必须拿到对应的 `URLSessionDataTask` 调 `cancel()`。
/// 取消时把登记簿里所有 task 一起 cancel，所有 worker 才会「同时」退出，
/// 而不是各自等读到超时（60s）才反应。
private final class TaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]
    private var cancelling = false

    var isCancelling: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelling
    }

    func register(_ task: URLSessionTask) {
        lock.lock()
        if cancelling {
            lock.unlock()
            task.cancel()
            return
        }
        tasks[ObjectIdentifier(task)] = task
        lock.unlock()
    }

    func release(_ task: URLSessionTask) {
        lock.lock()
        tasks.removeValue(forKey: ObjectIdentifier(task))
        lock.unlock()
    }

    /// 逐个 cancel 所有在飞 task，并让之后注册的 task 一进来就被取消
    func cancelAll() {
        lock.lock()
        cancelling = true
        let live = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        live.forEach { $0.cancel() }
    }

    /// 「掐掉这一批、但别把整个下载判死」：卡住恢复用。
    ///
    /// 与 `cancelAll` 的区别是不会把 `cancelling` 打开 —— 被掐掉的 worker
    /// 会以取消错误退出，调度循环看到 `isCancelled` 仍为 false，
    /// 于是下一轮就用新连接重新派活，下载继续。
    func abortAll() {
        lock.lock()
        let live = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        live.forEach { $0.cancel() }
    }

    func reset() {
        lock.lock()
        cancelling = false
        tasks.removeAll()
        lock.unlock()
    }
}

/// 把 `session.dataTask` 创建的 task 从 continuation 闭包传到取消处理器手里。
/// 取消处理器可能在任何线程、任何时刻被调用，所以要有锁。
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLSessionDataTask?

    var task: URLSessionDataTask? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// MARK: - 起步请求

/// 只读「响应头 + 首块正文」的收集器。
///
/// 两条铁律：
///  1. 只有 **206** 才允许正文继续流下来。200（服务器忽略 Range）如果放行，
///     几百 MB 的正文会被整包读进内存 —— 那正是老实现「解析巨慢 / 爆内存」的根源；
///  2. 拿够 `cap` 字节就主动 `cancel`，绝不多读一个字节。
private final class BootstrapCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let cap: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<EngineBootstrap?, Never>?
    private var finished = false

    init(cap: Int) {
        self.cap = max(cap, 1)
        super.init()
    }

    func begin(_ continuation: CheckedContinuation<EngineBootstrap?, Never>) {
        lock.lock(); self.continuation = continuation; lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        lock.lock(); self.response = http; lock.unlock()
        completionHandler(http.statusCode == 206 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        let reached = buffer.count >= cap
        lock.unlock()
        if reached { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let http = response
        let data = buffer
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        guard let continuation else { return }
        guard let http else {
            // 连响应头都没拿到：网络层错误，交给上层处理
            continuation.resume(returning: nil)
            return
        }
        var total: Int64 = 0
        var chunked = false
        if http.statusCode == 206,
           let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
           let last = contentRange.split(separator: "/").last,
           let parsed = Int64(last.trimmingCharacters(in: .whitespaces)), parsed > 0 {
            total = parsed
            chunked = true
        } else if let raw = http.value(forHTTPHeaderField: "Content-Length"),
                  let parsed = Int64(raw), parsed > 0 {
            total = parsed
        }
        continuation.resume(returning: EngineBootstrap(
            data: chunked ? data : Data(),
            total: total,
            chunked: chunked,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            finalURL: http.url ?? task.originalRequest?.url ?? task.currentRequest?.url ?? URL(string: "https://github.com")!,
            status: http.statusCode
        ))
    }
}

// MARK: - 单连接下载

/// 单连接下载的桥：把 `URLSessionDownloadDelegate` 的回调翻成 async/await，
/// 顺带用 `totalBytesWritten` 驱动**真实进度**（老实现只能转圈）。
private final class SingleDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expectedTotal: Int64
    private let onProgress: @Sendable (DownloadProgress) -> Void

    private var continuation: CheckedContinuation<(URL, Int64), Error>?
    private var moved = false
    private var failure: Error?

    private var lastEmit = Date.distantPast
    private var lastAt = Date()
    private var lastBytes: Int64 = 0
    private var smoothed: Double = 0

    init(destination: URL,
         expectedTotal: Int64,
         onProgress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.destination = destination
        self.expectedTotal = expectedTotal
        self.onProgress = onProgress
        super.init()
    }

    func run(start: @escaping () -> Void) async throws -> (URL, Int64) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock(); self.continuation = continuation; lock.unlock()
            start()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedTotal
        lock.lock()
        let dt = now.timeIntervalSince(lastAt)
        if dt > 0.2 {
            let delta = totalBytesWritten - lastBytes
            if delta > 0 {
                let instant = Double(delta) / dt
                smoothed = smoothed <= 0 ? instant : smoothed * 0.6 + instant * 0.4
            } else {
                smoothed *= 0.5
            }
            lastBytes = totalBytesWritten
            lastAt = now
        }
        guard now.timeIntervalSince(lastEmit) >= 0.25 else { lock.unlock(); return }
        lastEmit = now
        let speed = max(smoothed, 0)
        lock.unlock()

        let fraction = total > 0 ? min(Double(totalBytesWritten) / Double(total), 1) : 0
        let eta = (speed > 64 && total > totalBytesWritten) ? Double(total - totalBytesWritten) / speed : 0
        onProgress(DownloadProgress(downloadedBytes: totalBytesWritten,
                                    totalBytes: total,
                                    fraction: fraction,
                                    speedBytesPerSecond: speed,
                                    etaSeconds: eta))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: location, to: destination)
            lock.lock(); moved = true; lock.unlock()
        } catch {
            lock.lock(); failure = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let moved = self.moved
        let failure = self.failure
        lock.unlock()

        guard let continuation else { return }
        if let error { continuation.resume(throwing: error); return }
        if let failure { continuation.resume(throwing: failure); return }
        guard moved else {
            continuation.resume(throwing: DownloadError.badResponse)
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64) ?? 0
        guard size > 0 else {
            continuation.resume(throwing: DownloadError.incomplete)
            return
        }
        // 服务端声明了体积就必须对齐：断流时 URLSession 可能安静返回截断文件，
        // 用户解压才发现坏了 —— 这是「下完但用不了」的经典来源。
        if expectedTotal > 0, size != expectedTotal {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(throwing: DownloadError.incompleteDetailed(
                "单连接下载被截断：只收到 \(size) / \(expectedTotal) 字节"))
            return
        }
        continuation.resume(returning: (destination, size))
    }
}
