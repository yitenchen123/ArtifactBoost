import Foundation

/// 通道的作用域：决定它能套在哪种 URL 上。
///
/// 这是新增 ghfast 后必须区分的一件事 ——
/// 常规镜像（gh-proxy 等）是「把已签名的真实地址塞进前缀」，任何地址都能中转；
/// 而 ghfast.top 只认 `github.com` 原始地址，套到 Azure 签名地址上会直接 400。
enum RouteScope: Sendable {
    /// 可用于任何地址（含 Azure 签名地址）
    case any
    /// 只能用于 github.com 的原始地址（发行版附件的稳定下载链接）
    case githubOnly
}

/// 下载通道：直连 Azure 签名地址，或经由镜像 / 自建反代中转（前缀 + 原始地址）
struct DownloadRoute: Hashable, Sendable {
    let name: String
    let prefix: String
    let scope: RouteScope

    init(name: String, prefix: String, scope: RouteScope = .any) {
        self.name = name
        self.prefix = prefix
        self.scope = scope
    }

    static let direct = DownloadRoute(name: "直连", prefix: "")

    var isDirect: Bool { prefix.isEmpty }

    /// 内置公共镜像。它们只是中转「已签名的产物地址」，不接触 Token；
    /// 但私有仓库的产物不应经过第三方，所以只在公开仓库且用户开启智能加速时使用。
    /// 不同节点往往落在不同的机房/线路上，多通道并行时带宽可以叠加。
    static let builtInMirrors: [DownloadRoute] = [
        DownloadRoute(name: "gh-proxy.com", prefix: "https://gh-proxy.com/"),
        DownloadRoute(name: "slink.ltd", prefix: "https://slink.ltd/"),
        DownloadRoute(name: "hk.gh-proxy.com", prefix: "https://hk.gh-proxy.com/"),
        DownloadRoute(name: "moeyy.xyz", prefix: "https://github.moeyy.xyz/"),
    ]

    /// ghfast.top —— **只能用于发行版**。
    ///
    /// 它的用法是 `https://ghfast.top/https://github.com/...`，
    /// 也就是必须给它一个 github.com 的原始地址；
    /// 构建产物 / 构建日志解析出来的是临时签名地址，套上去会被拒。
    /// 因此单独归类，只在下载发行版附件时参与候选。
    static let ghfast = DownloadRoute(
        name: "ghfast.top",
        prefix: "https://ghfast.top/",
        scope: .githubOnly
    )

    /// 给一次具体下载挑可用的镜像。
    ///
    /// - Parameter githubURL: 该下载在 github.com 上的稳定地址；只有发行版有，其余为 nil。
    ///   为 nil 时 `.githubOnly` 的通道会被剔除。
    static func mirrors(for githubURL: URL?) -> [DownloadRoute] {
        githubURL == nil ? builtInMirrors : builtInMirrors + [ghfast]
    }

    func apply(to url: URL) -> URL {
        guard !prefix.isEmpty, let mirrored = URL(string: prefix + url.absoluteString) else { return url }
        return mirrored
    }

    /// 补全并校验用户填的前缀，非法时返回空串
    static func normalizedPrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let url = URL(string: trimmed), url.scheme != nil else { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }
}

/// 带权重的通道，用于按权重分配分块；初始权重均等，下载中按实时吞吐动态调整
struct ScoredRoute: Equatable, Sendable {
    let route: DownloadRoute
    let speed: Double
}

enum RouteMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case direct
    case smart
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "直连"
        case .smart: return "智能加速"
        case .custom: return "自定义"
        }
    }

    var detail: String {
        switch self {
        case .direct: return "直接连 GitHub 存储，最安全，但国内通常很慢"
        case .smart: return "直连与公共镜像多通道并行，带宽叠加"
        case .custom: return "使用你自己搭建的中转（Cloudflare Worker / 反向代理）"
        }
    }
}

/// 持久化的加速设置：在「设置」页调好并保存，下载时直接套用
struct AccelerationSettings {
    var connections: Int = 16
    var mode: RouteMode = .smart
    var customPrefix: String = ""

    static let `default` = AccelerationSettings()
    /// 设置页档位
    /// 128 属于极限档：吃千兆内网/高速 Wi-Fi 用，普通宽带吃不满，
    /// 且更容易被 CDN 限流（引擎会自动退让，不会失败）。
    static let connectionOptions = [8, 16, 32, 64, 128]
    /// 引擎接受的并发上限
    static let maxConnections = 128

    private enum Keys {
        static let connections = "ab.connections"
        static let mode = "ab.routeMode"
        static let customPrefix = "ab.customPrefix"
    }

    static func load() -> AccelerationSettings {
        let store = UserDefaults.standard
        var settings = AccelerationSettings()
        let stored = store.integer(forKey: Keys.connections)
        settings.connections = stored > 0 ? stored : 16
        settings.mode = RouteMode(rawValue: store.string(forKey: Keys.mode) ?? "") ?? .smart
        settings.customPrefix = store.string(forKey: Keys.customPrefix) ?? ""
        return settings
    }

    func save() {
        let store = UserDefaults.standard
        store.set(clampedConnections, forKey: Keys.connections)
        store.set(mode.rawValue, forKey: Keys.mode)
        store.set(customPrefix, forKey: Keys.customPrefix)
    }

    var clampedConnections: Int { max(1, min(connections, Self.maxConnections)) }

    /// 当前设置下的候选通道（直连永远保留兜底）
    ///
    /// - Parameter githubURL: 该下载在 github.com 上的稳定地址；只有发行版有。
    ///   非空时 ghfast 才会进入候选（它只认 github.com 原始地址）。
    func candidateRoutes(isPrivateRepo: Bool = false, githubURL: URL? = nil) -> [DownloadRoute] {
        switch mode {
        case .direct:
            return [.direct]
        case .custom:
            let prefix = DownloadRoute.normalizedPrefix(customPrefix)
            guard !prefix.isEmpty else { return [.direct] }
            return [DownloadRoute(name: "自定义加速", prefix: prefix), .direct]
        case .smart:
            guard !isPrivateRepo else { return [.direct] }
            return [.direct] + DownloadRoute.mirrors(for: githubURL)
        }
    }
}
