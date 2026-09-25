import SwiftUI

@main
struct ArtifactBoostApp: App {
    @StateObject private var session = SessionManager()

    var body: some Scene {
        WindowGroup {
            if session.isLoggedIn {
                RepoListView()
                    .environmentObject(session)
            } else {
                LoginView()
                    .environmentObject(session)
            }
        }
    }
}
