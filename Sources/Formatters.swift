import Foundation

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)), countStyle: .file) + "/s"
}

/// 剩余时间：42 秒 / 3 分 12 秒 / 1 小时 04 分
/// 速度未知或已经下完（<1s）时返回 nil，界面据此隐藏这一项，而不是显示「0 秒」。
func formatDuration(_ seconds: Double) -> String? {
    guard seconds.isFinite, seconds >= 1 else { return nil }
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) 秒" }
    if total < 3600 {
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) 分" : "\(minutes) 分 \(rest) 秒"
    }
    return String(format: "%d 小时 %02d 分", total / 3600, (total % 3600) / 60)
}

/// 1200 → 1.2k，34000 → 34k（GitHub 的数字缩写风格）
func formatCount(_ count: Int) -> String {
    switch count {
    case ..<1000:
        return "\(count)"
    case ..<10_000:
        return String(format: "%.1fk", Double(count) / 1000)
    case ..<1_000_000:
        return "\(count / 1000)k"
    default:
        return String(format: "%.1fm", Double(count) / 1_000_000)
    }
}

/// 相对时间：刚刚 / 5 分钟前 / 3 小时前 / 2 天前 / 4 个月前 / 1 年前
/// （对齐 GitHub 的时间展示风格，比绝对日期更符合移动端的阅读习惯）
func formatRelative(_ date: Date, now: Date = Date()) -> String {
    let interval = now.timeIntervalSince(date)

    // 未来时间（时钟偏差）统一显示为「刚刚」，避免出现「-3 分钟前」
    guard interval >= 0 else { return "刚刚" }

    if interval < 60 {
        return "刚刚"
    }
    let minutes = Int(interval / 60)
    if minutes < 60 {
        return "\(minutes) 分钟前"
    }
    let hours = minutes / 60
    if hours < 24 {
        return "\(hours) 小时前"
    }
    let days = hours / 24
    if days < 30 {
        return "\(days) 天前"
    }
    let months = days / 30
    if months < 12 {
        return "\(months) 个月前"
    }
    return "\(months / 12) 年前"
}
