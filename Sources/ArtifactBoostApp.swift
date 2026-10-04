import SwiftUI

@main
struct ArtifactBoostApp: App {
    @StateObject private var session: SessionManager
    @StateObject private var downloads: DownloadManager

    init() {
        let session = SessionManager()
        _session = StateObject(wrappedValue: session)
        _downloads = StateObject(wrappedValue: DownloadManager(session: session))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if session.isLoggedIn {
                    RootTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .environmentObject(downloads)
            .task {
                // 后台续下：上次进程被杀时没下完的任务自动恢复
                //（登录态在 SessionManager.init 里已同步恢复，无需等待）
                downloads.restorePending()
            }
        }
    }
}