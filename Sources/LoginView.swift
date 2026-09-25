import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var tokenInput = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Actions 产物加速下载", systemImage: "bolt.circle.fill")
                            .font(.title2)
                            .bold()
                        Text("登录 GitHub 后，浏览仓库的 Actions 产物，并通过多线程分段并发下载加速拉取。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("使用 Personal Access Token 登录") {
                    SecureField("粘贴 Token（ghp_… 或 github_pat_…）", text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Link("① 创建 classic Token（勾选 repo 权限）",
                         destination: URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=ArtifactBoost")!)
                    Link("② 创建 fine-grained Token（需 Actions 读权限）",
                         destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                } footer: {
                    Text("Token 仅保存在本机钥匙串，不会上传到任何第三方服务器。fine-grained Token 请为目标仓库开启 Actions: Read 和 Contents: Read 权限。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        login()
                    } label: {
                        HStack {
                            Spacer()
                            if isWorking {
                                ProgressView()
                            } else {
                                Text("验证并登录").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }
            .navigationTitle("登录 GitHub")
        }
    }

    private func login() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await session.login(token: token)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}
