import Foundation

enum GitHubError: LocalizedError {
    case badURL
    case badResponse
    case http(Int, String)
    case artifactExpired
    case downloadURLNotFound
    /// 解析签名地址整体超时（与安卓端同步）：文本直接面向用户，下载页失败态用得到
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的请求地址"
        case .badResponse: return "服务器响应异常"
        case .http(let code, let message):
            switch code {
            case 401: return "Token 无效或已过期（401），请重新登录"
            case 403:
                return "权限不足或触发限流（403）\(message)\n如果是别人的公开仓库：fine-grained Token 需要勾选 Public Repositories 只读；classic Token 勾了 repo 即可。"
            case 404:
                return "未找到（404）：仓库不存在、是私有仓库，或你的 Token 没有被授权访问它。"
            default: return "请求失败（\(code)）\(message)"
            }
        case .artifactExpired: return "该产物已过期，GitHub 已将其删除"
        case .downloadURLNotFound: return "未能获取产物下载地址"
        case .requestTimeout: return "解析下载地址超时（30s）：直连 api.github.com 太慢，请检查网络后重试"
        }
    }
}

private struct GHErrorMessage: Codable {
    let message: String?
}

/// 搜索排序方式
enum RepoSort: String, CaseIterable, Identifiable {
    case bestMatch
    case stars
    case updated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bestMatch: return "最佳匹配"
        case .stars: return "星标最多"
        case .updated: return "最近更新"
        }
    }
}

/// 无可变状态（仅 token），声明 Sendable 以便测速限时等后台任务安全捕获
final class GitHubClient: Sendable {
    let token: String

    init(token: String) {
        self.token = token
    }

    func makeURL(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var comps = URLComponents(string: "https://api.github.com")
        comps?.path = "/" + path
        if !query.isEmpty { comps?.queryItems = query }
        guard let url = comps?.url else { throw GitHubError.badURL }
        return url
    }

    func authorizedRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        // 普通 API 单次 45s 封顶（与安卓端 apiClient callTimeout 对应）：
        // URLSession.shared 改不了配置，只能逐请求设 idle 超时。
        req.timeoutInterval = 45
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let request = authorizedRequest(try makeURL(path, query: query))
        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(GHErrorMessage.self, from: data))?.message ?? ""
            if http.statusCode == 410 { throw GitHubError.artifactExpired }
            throw GitHubError.http(http.statusCode, msg)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    /// 验证 Token 并返回当前用户
    func validateToken() async throws -> GHUser {
        try await get("user")
    }

    /// 当前用户可见的仓库（自己 + 协作 + 组织）
    func repos(page: Int) async throws -> [GHRepo] {
        try await get("user/repos", query: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "affiliation", value: "owner,collaborator,organization_member"),
        ])
    }

    /// 搜索全站仓库：不限于自己的仓库，别人的公开仓库也能搜到并下载
    func searchRepos(keyword: String, sort: RepoSort = .bestMatch) async throws -> [GHRepo] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "per_page", value: "40"),
        ]
        switch sort {
        case .bestMatch:
            break
        case .stars:
            query.append(URLQueryItem(name: "sort", value: "stars"))
            query.append(URLQueryItem(name: "order", value: "desc"))
        case .updated:
            query.append(URLQueryItem(name: "sort", value: "updated"))
            query.append(URLQueryItem(name: "order", value: "desc"))
        }
        let resp: RepoSearchResponse = try await get("search/repositories", query: query)
        return resp.items
    }

    /// 按 owner/repo 取单个仓库（「直接打开仓库」用）
    func repo(fullName: String) async throws -> GHRepo {
        try await get("repos/\(fullName)")
    }

    /// 仓库最近的 workflow 运行记录
    func workflowRuns(repo: GHRepo) async throws -> [GHWorkflowRun] {
        let resp: RunsResponse = try await get(
            "repos/\(repo.fullName)/actions/runs",
            query: [URLQueryItem(name: "per_page", value: "30")]
        )
        return resp.workflowRuns
    }

    /// 取单次 workflow 运行（「直接打开 Actions 链接」用）
    func workflowRun(fullName: String, runID: Int64) async throws -> GHWorkflowRun {
        try await get("repos/\(fullName)/actions/runs/\(runID)")
    }

    /// 某次运行产生的产物列表
    func artifacts(repo: GHRepo, run: GHWorkflowRun) async throws -> [GHArtifact] {
        let resp: ArtifactsResponse = try await get(
            "repos/\(repo.fullName)/actions/runs/\(run.id)/artifacts",
            query: [URLQueryItem(name: "per_page", value: "100")]
        )
        return resp.artifacts
    }

    /// 某个仓库的发行版（Release）
    func releases(repo: GHRepo) async throws -> [GHRelease] {
        try await get("repos/\(repo.fullName)/releases", query: [
            URLQueryItem(name: "per_page", value: "50"),
        ])
    }

    /// 仓库分支（用于下载任意分支的源码包）
    func branches(repo: GHRepo) async throws -> [GHBranch] {
        try await get("repos/\(repo.fullName)/branches", query: [
            URLQueryItem(name: "per_page", value: "100"),
        ])
    }

    /// 解析任意下载项的签名地址。
    /// GitHub 对这些接口都会 302 跳转到带签名的真实地址（产物/日志在 Azure Blob，
    /// 源码包在 codeload），这里拦下跳转拿到真实地址，后续分段下载直接打这个地址
    /// （不再需要 Token，也不再经过 api.github.com）。
    func resolveDownloadURL(for source: DownloadSource) async throws -> URL {
        var extraHeaders: [String: String] = [:]
        let path: String
        switch source {
        case .artifact(let repo, let id):
            path = "repos/\(repo)/actions/artifacts/\(id)/zip"
        case .runLogs(let repo, let runID):
            path = "repos/\(repo)/actions/runs/\(runID)/logs"
        case .releaseAsset(let repo, let assetID, _):
            path = "repos/\(repo)/releases/assets/\(assetID)"
            // 附件接口默认返回 JSON 元数据，必须显式要二进制才会 302
            extraHeaders["Accept"] = "application/octet-stream"
        case .sourceArchive(let repo, let ref, let format):
            let encoded = ref.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ref
            path = encoded.isEmpty ? "repos/\(repo)/\(format.path)" : "repos/\(repo)/\(format.path)/\(encoded)"
        }

        let url = try makeURL(path)
        var request = authorizedRequest(url)
        // 解析阶段永远直连 api.github.com：idle 30s 封顶（与安卓端 redirectClient 对应），
        // 总时长另由 performDownload 的 30s 限时兜底。
        request.timeoutInterval = 30
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession(configuration: .ephemeral, delegate: RedirectCatcher(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.badResponse }
        if http.statusCode == 410 { throw GitHubError.artifactExpired }
        if http.statusCode == 302 || http.statusCode == 303,
           let location = http.value(forHTTPHeaderField: "Location"),
           let signed = URL(string: location) {
            return signed
        }
        if !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(GHErrorMessage.self, from: data))?.message ?? ""
            throw GitHubError.http(http.statusCode, message)
        }
        throw GitHubError.downloadURLNotFound
    }
}

/// 阻止 URLSession 自动跟随 302，把跳转响应原样返回
private final class RedirectCatcher: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - README 与提交数（仓库详情页用）

extension GitHubClient {
    /// 取仓库 README 的 Markdown 原文。
    /// `?ref=` 跟随当前选中的分支；`Accept: application/vnd.github.raw` 直接返回纯文本，
    /// 省掉一次 base64 解码。404 表示没有 README，返回 nil 而不是抛错。
    func readme(repo: GHRepo, ref: String? = nil) async throws -> GHReadme? {
        var query: [URLQueryItem] = []
        let target = ref?.isEmpty == false ? ref! : (repo.defaultBranch ?? "")
        if !target.isEmpty {
            query.append(URLQueryItem(name: "ref", value: target))
        }

        var request = authorizedRequest(try makeURL("repos/\(repo.fullName)/readme", query: query))
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw GitHubError.badResponse }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            let msg = (try? JSONDecoder().decode(GHErrorMessage.self, from: data))?.message ?? ""
            throw GitHubError.http(http.statusCode, msg)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return GHReadme(path: readmePath(from: http) ?? "README.md", text: text)
    }

    /// README 接口在响应里带了文件路径的 base64，解出来用于标题展示（失败就退回默认名）
    private func readmePath(from response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Content-Location") else { return nil }
        return raw.split(separator: "/").last.map { String($0) }
    }

    /// 默认分支上的提交数（GitHub 用 Link 头的 last 页号给出，per_page=1 只需一次请求）。
    /// 拿不到就返回 nil，界面自动隐藏这一项。
    func commitCount(repo: GHRepo) async throws -> Int? {
        let query = [
            URLQueryItem(name: "sha", value: repo.defaultBranch ?? "HEAD"),
            URLQueryItem(name: "per_page", value: "1"),
        ]
        let (_, resp) = try await URLSession.shared.data(
            for: authorizedRequest(try makeURL("repos/\(repo.fullName)/commits", query: query))
        )
        guard let http = resp as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        guard let link = http.value(forHTTPHeaderField: "Link") else { return nil }
        return lastPageNumber(in: link)
    }

    /// 从 `Link: <...?page=42>; rel="last"` 里抠出 42
    private func lastPageNumber(in linkHeader: String) -> Int? {
        for segment in linkHeader.split(separator: ",") {
            guard segment.contains("rel=\"last\"") else { continue }
            guard let range = segment.range(of: "page=") else { continue }
            let digits = segment[range.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }
}
