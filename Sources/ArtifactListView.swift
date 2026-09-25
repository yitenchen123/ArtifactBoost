import SwiftUI

struct ArtifactListView: View {
    let repo: GHRepo
    let run: GHWorkflowRun

    @StateObject private var dm: DownloadManager
    @State private var artifacts: [GHArtifact] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(repo: GHRepo, run: GHWorkflowRun, client: GitHubClient) {
        self.repo = repo
        self.run = run
        _dm = StateObject(wrappedValue: DownloadManager(client: client))
    }

    var body: some View {
        List {
            Section {
                Stepper("并发连接数：\(dm.connections)", value: $dm.connections, in: 1...16)
            } footer: {
                Text("连接数越多提速越明显（建议 8）。产物为 zip 压缩包，下载完成后可一键导出到「文件」App 或分享。")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if artifacts.isEmpty && !isLoading {
                Section {
                    Text("该运行没有可下载的产物（可能已过期）")
                        .foregroundStyle(.secondary)
                }
            }

            Section("产物") {
                ForEach(artifacts) { artifact in
                    artifactRow(artifact)
                }
            }

            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("运行 #\(run.runNumber)")
        .task { await load() }
        .refreshable { await load() }
    }

    @ViewBuilder
    private func artifactRow(_ artifact: GHArtifact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "archivebox.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.name).font(.headline)
                    Text("\(formatBytes(artifact.sizeInBytes)) · \(artifact.createdAt?.formatted(date: .numeric, time: .omitted) ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if artifact.expired {
                    Text("已过期")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            switch dm.state(for: artifact) {
            case .idle:
                Button {
                    dm.start(artifact: artifact, repo: repo)
                } label: {
                    Label("加速下载", systemImage: "bolt.horizontal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(artifact.expired)

            case .resolving:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在获取下载地址…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    HStack {
                        Text("\(formatBytes(progress.downloadedBytes)) / \(formatBytes(progress.totalBytes))（\(Int(progress.fraction * 100))%）")
                        Spacer()
                        Text(formatSpeed(progress.speedBytesPerSecond))
                            .foregroundStyle(.green)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("取消", role: .destructive) {
                        dm.cancel(artifact: artifact)
                    }
                    .font(.caption)
                }

            case .finished(let url):
                VStack(alignment: .leading, spacing: 6) {
                    Label("下载完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                    HStack {
                        ShareLink(item: url) {
                            Label("导出 / 保存到文件", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                        Button("重新下载") {
                            dm.start(artifact: artifact, repo: repo)
                        }
                        .font(.caption)
                    }
                }

            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重试") {
                        dm.start(artifact: artifact, repo: repo)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            artifacts = try await dm.client.artifacts(repo: repo, run: run)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
