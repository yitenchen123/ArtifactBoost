import Foundation

struct GHUser: Codable {
    let login: String
    let avatarURL: URL?
    enum CodingKeys: String, CodingKey {
        case login
        case avatarURL = "avatar_url"
    }
}

struct GHRepo: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let fullName: String
    let isPrivate: Bool
    let updatedAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name
        case fullName = "full_name"
        case isPrivate = "private"
        case updatedAt = "updated_at"
    }
    var owner: String { fullName.split(separator: "/").first.map(String.init) ?? "" }
}

struct RepoSearchResponse: Codable {
    let items: [GHRepo]
}

struct GHWorkflowRun: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String?
    let runNumber: Int
    let status: String?
    let conclusion: String?
    let headBranch: String?
    let createdAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case runNumber = "run_number"
        case headBranch = "head_branch"
        case createdAt = "created_at"
    }
}

struct RunsResponse: Codable {
    let totalCount: Int
    let workflowRuns: [GHWorkflowRun]
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case workflowRuns = "workflow_runs"
    }
}

struct GHArtifact: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let sizeInBytes: Int64
    let expired: Bool
    let createdAt: Date?
    let expiresAt: Date?
    enum CodingKeys: String, CodingKey {
        case id, name, expired
        case sizeInBytes = "size_in_bytes"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct ArtifactsResponse: Codable {
    let totalCount: Int
    let artifacts: [GHArtifact]
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case artifacts
    }
}
