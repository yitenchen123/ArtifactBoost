import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var user: GHUser?
    @Published private(set) var client: GitHubClient?

    var isLoggedIn: Bool { client != nil }

    init() {
        if let token = KeychainHelper.read() {
            client = GitHubClient(token: token)
        }
    }

    func login(token: String) async throws {
        let newClient = GitHubClient(token: token)
        let user = try await newClient.validateToken()
        KeychainHelper.save(token: token)
        self.client = newClient
        self.user = user
    }

    func logout() {
        KeychainHelper.delete()
        client = nil
        user = nil
    }
}
