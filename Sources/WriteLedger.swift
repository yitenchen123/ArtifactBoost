import Foundation

/// 写入覆盖账本：记录「哪些字节区间已经被真正写进文件」。
///
/// ## 为什么需要它
///
/// 引擎原来的完整性校验只有一句 `size == total` —— 那只是**总量**校验。
/// 「重复写了两段 + 漏写了一段」的总量完全可能相等，最后文件大小对得上、
/// 内容却是错的 —— 症状正是「能下完但解压不了」。
///
/// 这个账本把校验升级成**覆盖**校验：
///  - 每次成功写盘都登记区间；
///  - 任何一次「重叠写入」立刻发现（说明同一段被两个 worker 写了）；
///  - 收尾时核对「覆盖量 == 文件总大小」且「区间无重叠」，
///    两者同时成立才说明每个字节都被恰好写过一次。
///
/// 开销：每写一片登记一次（几十字节的节点 + 一把锁），
/// 相对于一片的网络与磁盘开销完全可以忽略。
final class WriteLedger: @unchecked Sendable {

    private let lock = NSLock()
    private let total: Int64

    /// 已写入的区间，按起点有序，且保证两两不相交、不相邻
    private var ranges: [ClosedRange<Int64>] = []

    private var covered: Int64 = 0

    /// 检测到的重叠写入次数（> 0 说明调度出问题了）
    private(set) var overlaps = 0

    /// 区间个数（诊断用）
    var segmentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ranges.count
    }

    /// 已覆盖的字节数
    var coveredBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return covered
    }

    init(total: Int64) {
        self.total = total
    }

    /// 登记一次写盘。
    ///
    /// - Returns: 真正新覆盖的字节数。若该区间已被完全写过，返回 0；
    ///            若与已有区间部分重叠，只把新增部分计入覆盖量。
    @discardableResult
    func record(start: Int64, endInclusive: Int64) -> Int64 {
        guard endInclusive >= start else { return 0 }
        lock.lock(); defer { lock.unlock() }

        // 找到第一个起点 >= start 的位置
        var index = lowerBound(start)

        // 前一个区间若与新区间重叠或相邻，从它开始合并
        if index > 0 {
            let prev = ranges[index - 1]
            if prev.upperBound >= start - 1 {
                index -= 1
            }
        }

        var mergedStart = start
        var mergedEnd = endInclusive
        var overlapsFound = 0

        var i = index
        while i < ranges.count {
            let r = ranges[i]
            if r.lowerBound > mergedEnd + 1 { break }
            // 正式判定重叠：两个区间真正有交集（不是仅相邻）
            if r.lowerBound <= mergedEnd && r.upperBound >= mergedStart { overlapsFound += 1 }
            if r.lowerBound < mergedStart { mergedStart = r.lowerBound }
            if r.upperBound > mergedEnd { mergedEnd = r.upperBound }
            i += 1
        }

        if overlapsFound > 0 { overlaps += overlapsFound }

        // 新覆盖的字节 = 合并后的长度 − 被吞掉的旧区间总长
        var absorbed: Int64 = 0
        for j in index..<i {
            absorbed += ranges[j].upperBound - ranges[j].lowerBound + 1
        }
        var newBytes = (mergedEnd - mergedStart + 1) - absorbed
        if newBytes < 0 { newBytes = 0 }

        // 用合并结果替换被吞掉的那些区间
        ranges.replaceSubrange(index..<i, with: [mergedStart...mergedEnd])
        covered += newBytes
        return newBytes
    }

    /// 是否每个字节都恰好覆盖了一次（区间不重叠 + 覆盖量等于总大小）
    func isComplete() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard overlaps == 0 else { return false }
        guard ranges.count == 1, let only = ranges.first else { return false }
        return only.lowerBound == 0 && only.upperBound == total - 1
    }

    /// 尚未覆盖的区间列表（诊断 / 补漏用），最多返回 `limit` 段
    func gaps(limit: Int = 50) -> [ClosedRange<Int64>] {
        lock.lock(); defer { lock.unlock() }
        var result: [ClosedRange<Int64>] = []
        var cursor: Int64 = 0
        for r in ranges {
            if r.lowerBound > cursor {
                result.append(cursor...(r.lowerBound - 1))
                if result.count >= limit { return result }
            }
            cursor = max(cursor, r.upperBound + 1)
        }
        if cursor < total { result.append(cursor...(total - 1)) }
        return result
    }

    /// 生成一段人类可读的差异描述（校验失败时写进错误信息）
    func describe() -> String {
        lock.lock(); defer { lock.unlock() }
        var text = "已覆盖 \(covered)/\(total) 字节，缺 \(total - covered) 字节"
        if overlaps > 0 { text += "，检测到 \(overlaps) 次重复写入" }
        let g = gapsLocked(limit: 3)
        if !g.isEmpty {
            text += "，缺口示例："
            text += g.map { "[\($0.lowerBound)-\($0.upperBound)]" }.joined(separator: "、")
        }
        return text
    }

    /// 在有序区间表里找第一个起点 >= value 的下标
    private func lowerBound(_ value: Int64) -> Int {
        var lo = 0
        var hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].lowerBound < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// 调用方必须已持锁
    private func gapsLocked(limit: Int) -> [ClosedRange<Int64>] {
        var result: [ClosedRange<Int64>] = []
        var cursor: Int64 = 0
        for r in ranges {
            if r.lowerBound > cursor {
                result.append(cursor...(r.lowerBound - 1))
                if result.count >= limit { return result }
            }
            cursor = max(cursor, r.upperBound + 1)
        }
        if cursor < total { result.append(cursor...(total - 1)) }
        return result
    }
}
