import Foundation

enum ArchiveFormat: String, Hashable, Sendable, Codable {
    case zip
    case tarball

    var path: String { self == .zip ? "zipball" : "tarball" }
    var fileExtension: String { self == .zip ? "zip" : "tar.gz" }
    var title: String { self == .zip ? "ZIP" : "TAR.GZ" }
}

/// 能加速下载的东西：构建产物 / 构建日志 / 发行版附件 / 源码包
enum DownloadSource: Hashable, Sendable, Codable {
    case artifact(repo: String, id: Int64)
    case runLogs(repo: String, runID: Int64)
    /// - Parameter browserURL: 该附件在 github.com 上的**稳定公开地址**
    ///   （`https://github.com/{owner}/{repo}/releases/download/{tag}/{name}`）。
    ///   镜像 ghfast.top 只认 `github.com` 域名，而解析出来的是 302 之后的 Azure
    ///   签名地址，套不进 ghfast；有了这个稳定地址，发行版就能走 ghfast 加速。
    ///   拿不到 tag 时为 nil，此时退回原行为（只用签名地址 + 常规镜像）。
    case releaseAsset(repo: String, assetID: Int64, browserURL: String? = nil)
    case sourceArchive(repo: String, ref: String, format: ArchiveFormat)

    // MARK: - Codable（后台续下时任务落盘用，带关联值的手写编解码）

    private enum Kind: String, Codable {
        case artifact
        case runLogs
        case releaseAsset
        case sourceArchive
    }

    private enum Keys: String, CodingKey {
        case kind
        case repo
        case id
        case runID
        case assetID
        case browserURL
        case ref
        case format
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .artifact:
            self = .artifact(repo: try container.decode(String.self, forKey: .repo),
                             id: try container.decode(Int64.self, forKey: .id))
        case .runLogs:
            self = .runLogs(repo: try container.decode(String.self, forKey: .repo),
                            runID: try container.decode(Int64.self, forKey: .runID))
        case .releaseAsset:
            self = .releaseAsset(repo: try container.decode(String.self, forKey: .repo),
                                 assetID: try container.decode(Int64.self, forKey: .assetID),
                                 browserURL: try container.decodeIfPresent(String.self, forKey: .browserURL))
        case .sourceArchive:
            self = .sourceArchive(repo: try container.decode(String.self, forKey: .repo),
                                  ref: try container.decode(String.self, forKey: .ref),
                                  format: try container.decode(ArchiveFormat.self, forKey: .format))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .artifact(let repo, let id):
            try container.encode(Kind.artifact, forKey: .kind)
            try container.encode(repo, forKey: .repo)
            try container.encode(id, forKey: .id)
        case .runLogs(let repo, let runID):
            try container.encode(Kind.runLogs, forKey: .kind)
            try container.encode(repo, forKey: .repo)
            try container.encode(runID, forKey: .runID)
        case .releaseAsset(let repo, let assetID, let browserURL):
            try container.encode(Kind.releaseAsset, forKey: .kind)
            try container.encode(repo, forKey: .repo)
            try container.encode(assetID, forKey: .assetID)
            try container.encodeIfPresent(browserURL, forKey: .browserURL)
        case .sourceArchive(let repo, let ref, let format):
            try container.encode(Kind.sourceArchive, forKey: .kind)
            try container.encode(repo, forKey: .repo)
            try container.encode(ref, forKey: .ref)
            try container.encode(format, forKey: .format)
        }
    }

    /// 源码包由 GitHub 现场打包，不支持 Range 分段，只能单连接下载
    var supportsChunkedDownload: Bool {
        if case .sourceArchive = self { return false }
        return true
    }

    var iconName: String {
        switch self {
        case .artifact: return "archivebox.fill"
        case .runLogs: return "doc.text.fill"
        case .releaseAsset: return "shippingbox.fill"
        case .sourceArchive: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var kindName: String {
        switch self {
        case .artifact: return "构建产物"
        case .runLogs: return "构建日志"
        case .releaseAsset: return "发行版附件"
        case .sourceArchive: return "源码包"
        }
    }

    /// 能否走 ghfast 这类**只认 github.com 原始地址**的镜像。
    /// 目前只有发行版附件有这个稳定地址（构建产物/日志的地址是临时的）。
    var ghfastEligibleURL: String? {
        guard case .releaseAsset(_, _, let browserURL) = self,
              let url = browserURL, !url.isEmpty else { return nil }
        return url
    }
}

/// 界面上一行「可下载项」
struct DownloadItem: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let size: Int64?
    let isPrivate: Bool
    let source: DownloadSource

    var iconName: String { source.iconName }
    var kindName: String { source.kindName }

    /// 落盘文件名
    var fileName: String {
        switch source {
        case .artifact:
            return sanitize(title) + ".zip"
        case .runLogs:
            return sanitize(title) + "-logs.zip"
        case .releaseAsset:
            return sanitize(title)
        case .sourceArchive(_, let ref, let format):
            let base = ref.isEmpty ? "source" : sanitize(ref)
            return "\(sanitize(title))-\(base).\(format.fileExtension)"
        }
    }

    private func sanitize(_ raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 由接口数据构造下载项

extension DownloadItem {
    static func artifact(_ artifact: GHArtifact, repo: GHRepo) -> DownloadItem {
        DownloadItem(
            id: "artifact-\(artifact.id)",
            title: artifact.name,
            subtitle: "构建产物 · \(artifact.createdAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "时间未知")",
            size: artifact.sizeInBytes,
            isPrivate: repo.isPrivate,
            source: .artifact(repo: repo.fullName, id: artifact.id)
        )
    }

    static func runLogs(_ run: GHWorkflowRun, repo: GHRepo) -> DownloadItem {
        DownloadItem(
            id: "logs-\(run.id)",
            title: "\(run.name ?? "Workflow") #\(run.runNumber) 日志",
            subtitle: "构建日志 · \(run.headBranch ?? "-")",
            size: nil,
            isPrivate: repo.isPrivate,
            source: .runLogs(repo: repo.fullName, runID: run.id)
        )
    }

    static func releaseAsset(_ asset: GHReleaseAsset, release: GHRelease, repo: GHRepo) -> DownloadItem {
        // 拼出 github.com 上的稳定下载地址，供 ghfast 这类镜像使用。
        // 附件名可能含空格/中文，这里按路径段做一次编码。
        let encodedTag = release.tagName.addingPercentEncoding(
            withAllowedCharacters: Self.pathSegmentAllowed
        ) ?? release.tagName
        let encodedName = asset.name.addingPercentEncoding(
            withAllowedCharacters: Self.pathSegmentAllowed
        ) ?? asset.name
        let browserURL = "https://github.com/\(repo.fullName)/releases/download/\(encodedTag)/\(encodedName)"

        return DownloadItem(
            id: "asset-\(asset.id)",
            title: asset.name,
            subtitle: "\(release.displayName) · 下载 \(asset.downloadCount) 次",
            size: asset.size,
            isPrivate: repo.isPrivate,
            source: .releaseAsset(repo: repo.fullName, assetID: asset.id, browserURL: browserURL)
        )
    }

    /// URL 路径段允许的字符（保留非保留字符，其余交给百分号编码）
    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return set
    }()

    static func sourceArchive(repo: GHRepo, ref: String, format: ArchiveFormat) -> DownloadItem {
        let label = ref.isEmpty ? (repo.defaultBranch ?? "默认分支") : ref
        return DownloadItem(
            id: "source-\(repo.fullName)-\(label)-\(format.rawValue)",
            title: "\(repo.name)-\(label)",
            subtitle: "源码包 · \(format.title)",
            size: nil,
            isPrivate: repo.isPrivate,
            source: .sourceArchive(repo: repo.fullName, ref: ref, format: format)
        )
    }
}