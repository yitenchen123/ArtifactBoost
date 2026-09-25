import SwiftUI

struct RunListView: View {
    let repo: GHRepo

    @EnvironmentObject private var session: SessionManager
    @State private var runs: [GHWorkflowRun] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if runs.isEmpty && !isLoading {
                Section {
                    Text("暂无 Workflow 运行记录")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(runs) { run in
                    NavigationLink(value: run) {
                        HStack(spacing: 10) {
                            Image(systemName: statusIconName(for: run))
                                .foregroundStyle(statusColor(for: run))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.name ?? "Workflow")
                                    .font(.headline)
                                Text("#\(run.runNumber) · \(run.headBranch ?? "-")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let date = run.createdAt {
                                    Text(date.formatted(date: .numeric, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
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
        .navigationTitle(repo.name)
        .navigationDestination(for: GHWorkflowRun.self) { run in
            if let client = session.client {
                ArtifactListView(repo: repo, run: run, client: client)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func statusIconName(for run: GHWorkflowRun) -> String {
        guard run.status == "completed" else { return "arrow.triangle.2.circlepath" }
        switch run.conclusion {
        case "success": return "checkmark.circle.fill"
        case "failure": return "xmark.circle.fill"
        case "cancelled": return "nosign"
        default: return "exclamationmark.circle.fill"
        }
    }

    private func statusColor(for run: GHWorkflowRun) -> Color {
        guard run.status == "completed" else { return .blue }
        switch run.conclusion {
        case "success": return .green
        case "failure": return .red
        case "cancelled": return .gray
        default: return .orange
        }
    }

    private func load() async {
        guard let client = session.client else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            runs = try await client.workflowRuns(repo: repo)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
