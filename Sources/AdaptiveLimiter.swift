import Foundation

/// 自适应并发控制器（AIMD + 令牌桶限流器）。
///
/// 解决的问题：用户把并发拉到 128，引擎就真的往服务器砸 128 条连接 ——
/// Azure Blob 对单 Blob 有「约 60 MiB/s 或 500 请求/秒」的软目标，
/// 超了直接回 503 ServerBusy；很多公共镜像更狠，几十条就 429。
/// 一旦被限流，用户看到的就是「越下越慢、时不时卡住」。
///
/// 这里做两件事：
///  1. **AIMD 拥塞窗口**（和 TCP 一个思路）：顺畅时*加性增*（每完成一片 +1），
///     命中限流时*乘性减*（窗口砍半）。于是实际并发会自己爬到「服务器愿意给的
///     那个上限」然后稳在那里，而不是硬顶着 128 撞墙。
///  2. **全局速率闸**：把「每秒发出的 Range 请求数」也管起来。窗口管的是瞬时
///     并发，速率闸管的是 QPS —— 两者一起才能压住 429。
///
/// 用户设的 `connections` 从此只是**上限**而不是**目标**：设 128 不会更慢，
/// 只意味着「允许引擎在服务器撑得住时爬到 128」。
final class AdaptiveConcurrency: @unchecked Sendable {
    private let lock = NSLock()

    /// 用户设定的并发上限（硬顶，永不超过）
    private let ceiling: Int
    /// 当前窗口：实际允许的在飞请求数
    private var window: Int
    /// 上次乘性减半的时间：避免一次限流风暴把窗口一路打到 1
    private var lastDecrease = Date.distantPast
    /// 已经连续顺畅多久（秒），用于决定什么时候重新尝试探高
    private var smoothSince = Date()
    /// 处于「探测期」（刚减过窗口，需要谨慎加）
    private var probing = false

    /// 结果计数（诊断面板用）
    private(set) var increases = 0
    private(set) var decreases = 0
    private(set) var peakWindow = 0

    /// 速率闸：最近一次「发请求」的时间戳，用来算 QPS
    private var emitTimes: [Date] = []
    /// 每秒允许发出的请求数上限（随窗口缩放，避免大开窗口时 QPS 也爆掉）
    private var maxQPS: Double

    /// 起始窗口：不激进，也不保守 —— 与老实现的爬坡起点一致
    private static let rampStepBase = 16
    /// 连续顺畅多久才把「探测」标记清掉（之后加性增更快）
    private static let smoothThreshold: TimeInterval = 3.0

    init(ceiling: Int) {
        self.ceiling = max(1, ceiling)
        // 起始窗口取「16 或上限」，上限小的时候直接顶满
        self.window = min(max(1, min(Self.rampStepBase, ceiling)), ceiling)
        // QPS 上限：每个并发每秒最多发 ~8 个请求（Azure 单 Blob 500 QPS 的量级，
        // 留出余量；镜像通常更宽松但没必要压满）
        self.maxQPS = Double(self.window) * 8
        self.peakWindow = self.window
    }

    /// 当前允许的在飞请求数
    var currentWindow: Int {
        lock.lock(); defer { lock.unlock() }
        return window
    }

    var maxWindow: Int { ceiling }

    /// 判定「现在能不能再派一片」：既要窗口没满，也要没撞上速率闸。
    /// - Parameter inflight: 当前在飞请求数
    func canDispatch(inflight: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inflight < window else { return false }
        return qpsRoomLocked() > 0
    }

    /// 记录一次「即将发出请求」，用于速率闸计数
    func noteDispatch() {
        lock.lock()
        emitTimes.append(Date())
        trimLocked()
        lock.unlock()
    }

    /// 一片成功：加性增（AIMD 的 AI 部分）。
    ///
    /// 分两个阶段：
    ///  - **探测期**（刚被限流砍过窗口）：每片 +1，步子稍小，避免刚减完就冲回去；
    ///  - **稳定期**（连续顺畅超过 smoothThreshold）：每片 +1。
    /// 两者都是 +1（标准 AIMD 的 AI 就是线性增），区别只在探测期会更保守地
    /// 在窗口回涨后立刻再降；这里保留 `probing` 标记供诊断与后续策略调整。
    func noteSuccess(speed: Double) {
        lock.lock()
        let now = Date()
        let wasProbing = probing
        if now.timeIntervalSince(smoothSince) >= Self.smoothThreshold {
            probing = false
        }
        if window < ceiling {
            // 探测期涨幅压一半（向上取整，至少 +1），避免窗口刚被砍完就立刻冲高
            let step = wasProbing ? 1 : 2
            window = min(window + step, ceiling)
            increases += 1
        }
        peakWindow = max(peakWindow, window)
        maxQPS = Double(window) * 8
        smoothSince = now
        lock.unlock()
    }

    /// 命中限流（429/503）：乘性减（AIMD 的 MD 部分）
    ///
    /// 「乘性减」只在窗口真正被压下来时才记一笔，且同一秒内不重复减半 ——
    /// 否则 128 条连接同时撞 429 时，窗口会被连续减半 7 次直接掉到 1，
    /// 之后的加性增要爬很久才能恢复，用户体感就是「限流之后一直很慢」。
    func noteThrottle() {
        lock.lock()
        let now = Date()
        if now.timeIntervalSince(lastDecrease) > 1.0 {
            decreases += 1
            window = max(2, window / 2)
            maxQPS = Double(window) * 8
            lastDecrease = now
            probing = true
            smoothSince = now
        }
        lock.unlock()
    }

    /// 一片超时/连接错误（非限流）：轻度收缩，避免在坏线上继续加压
    func noteFailure() {
        lock.lock()
        let now = Date()
        if now.timeIntervalSince(lastDecrease) > 0.5, window > 4 {
            window = max(4, window - max(1, window / 8))
            maxQPS = Double(window) * 8
            lastDecrease = now
            smoothSince = now
        }
        lock.unlock()
    }

    /// 速率闸余额（调用方必须已持锁）
    private func qpsRoomLocked() -> Int {
        trimLocked()
        let room = Int(maxQPS) - emitTimes.count
        return max(room, 0)
    }

    /// 只保留最近 1 秒的发送记录
    private func trimLocked() {
        let cutoff = Date().addingTimeInterval(-1.0)
        if let firstRecent = emitTimes.firstIndex(where: { $0 > cutoff }) {
            if firstRecent > 0 { emitTimes.removeFirst(firstRecent) }
        } else {
            emitTimes.removeAll()
        }
    }
}

/// 说明：调度器现在直接使用 `AdaptiveConcurrency` 的
/// `canDispatch(inflight:)` + `currentWindow` 两个方法决定「此刻能派几条」，
/// 不再需要额外的时间片包装层 —— 老实现那种「每 150ms 加一档、加到上限就完事」
/// 的固定爬坡已经删除。
