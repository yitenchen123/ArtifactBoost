import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case idle
        case resolving
        case downloading(DownloadProgress)
        case finished(URL)
        case failed(String)
    }

    @Published var states: [Int64: State] = [:]
    @Published var connections: Int = 8

    private var engines: [Int64: DownloadEngine] = [:]
    let client: GitHubClient

    init(client: GitHubClient) {
        self.client = client
    }

    func state(for artifact: GHArtifact) -> State {
        states[artifact.id] ?? .idle
    }

    func start(artifact: GHArtifact, repo: GHRepo) {
        switch state(for: artifact) {
        case .resolving, .downloading:
            return
        default:
            break
        }

        states[artifact.id] = .resolving
        let engine = DownloadEngine()
        engines[artifact.id] = engine
        let safeName = artifact.name.replacingOccurrences(of: "/", with: "_")
        let connectionCount = connections

        Task {
            do {
                let signed = try await client.resolveDownloadURL(repo: repo, artifact: artifact)
                let url = try await engine.download(
                    signedURL: signed,
                    fileName: "\(safeName)-\(artifact.id).zip",
                    connections: connectionCount
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch self.states[artifact.id] {
                        case .resolving?, .downloading?, .none:
                            self.states[artifact.id] = .downloading(progress)
                        default:
                            break
                        }
                    }
                }
                states[artifact.id] = .finished(url)
            } catch {
                if (error as? DownloadError) == .cancelled {
                    states[artifact.id] = .idle
                } else {
                    states[artifact.id] = .failed(error.localizedDescription)
                }
            }
            engines[artifact.id] = nil
        }
    }

    func cancel(artifact: GHArtifact) {
        engines[artifact.id]?.cancel()
    }
}
