import SwiftUI

struct RepoListView: View {
    @EnvironmentObject private var session: SessionManager
    @State private var repos: [GHRepo] = []
    @State private var isLoading = false
    @State private var isSearchingRemote = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private var shownRepos: [GHRepo] {
        guard !searchText.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }

                Section {
                    ForEach(shownRepos) { repo in
                        NavigationLink(value: repo) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if repo.isPrivate {
                                        Image(systemName: "lock.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(repo.fullName).font(.headline)
                                }
                                if let date = repo.updatedAt {
                                    Text("更新于 \(date.formatted(date: .numeric, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if isLoading || isSearchingRemote {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("我的仓库")
            .searchable(text: $searchText, prompt: "输入关键词，回车远程搜索")
            .onSubmit(of: .search) {
                Task { await remoteSearch() }
            }
            .navigationDestination(for: GHRepo.self) { repo in
                RunListView(repo: repo)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        if let login = session.user?.login {
                            Text("已登录：\(login)")
                        }
                        Button("退出登录", role: .destructive) {
                            session.logout()
                        }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .task { await loadRepos() }
            .refreshable { await loadRepos() }
        }
    }

    private func loadRepos() async {
        guard let client = session.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var all: [GHRepo] = []
            for page in 1...3 {
                let batch = try await client.repos(page: page)
                all.append(contentsOf: batch)
                if batch.count < 100 { break }
            }
            repos = all
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remoteSearch() async {
        guard let client = session.client, !searchText.isEmpty else { return }
        isSearchingRemote = true
        errorMessage = nil
        defer { isSearchingRemote = false }
        do {
            repos = try await client.searchRepos(keyword: searchText)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
