import Foundation

struct DownloadProgress: Equatable {
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var fraction: Double = 0
    var speedBytesPerSecond: Double = 0
}

enum DownloadError: LocalizedError {
    case badResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badResponse: return "下载失败：服务器响应异常"
        case .cancelled: return "下载已取消"
        }
    }
}

private struct Chunk {
    let index: Int
    let start: Int64
    let end: Int64
}

/// 汇总各分块进度，节流后回调给 UI
private actor ProgressAccumulator {
    private var chunkBytes: [Int: Int64] = [:]
    private let total: Int64
    private let startTime = Date()
    private var lastEmit = Date.distantPast
    private let handler: @Sendable (DownloadProgress) -> Void

    init(total: Int64, handler: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.handler = handler
    }

    private func emit(force: Bool = false) {
        let now = Date()
        if !force, now.timeIntervalSince(lastEmit) < 0.25 { return }
        lastEmit = now
        let downloaded = chunkBytes.values.reduce(0, +)
        let elapsed = max(now.timeIntervalSince(startTime), 0.05)
        handler(DownloadProgress(
            downloadedBytes: downloaded,
            totalBytes: total,
            fraction: total > 0 ? min(Double(downloaded) / Double(total), 1) : 0,
            speedBytesPerSecond: Double(downloaded) / elapsed
        ))
    }

    func update(chunk: Int, bytes: Int64) {
        chunkBytes[chunk] = bytes
        emit()
    }

    func finish(downloaded: Int64) {
        let elapsed = max(Date().timeIntervalSince(startTime), 0.05)
        handler(DownloadProgress(
            downloadedBytes: downloaded,
            totalBytes: total > 0 ? total : downloaded,
            fraction: 1,
            speedBytesPerSecond: Double(downloaded) / elapsed
        ))
    }
}

/// 接收每个分块任务的进度回调与完成事件
private final class ChunkDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var chunkForTask: [Int: Int] = [:]
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]
    private var partURLs: [Int: URL] = [:]
    private var taskErrors: [Int: Error] = [:]
    private let accumulator: ProgressAccumulator
    private let tempDir: URL

    init(accumulator: ProgressAccumulator, tempDir: URL) {
        self.accumulator = accumulator
        self.tempDir = tempDir
    }

    func register(task: URLSessionDownloadTask, chunk: Int, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        chunkForTask[task.taskIdentifier] = chunk
        continuations[task.taskIdentifier] = continuation
        lock.unlock()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lock.lock()
        let chunk = chunkForTask[downloadTask.taskIdentifier]
        lock.unlock()
        guard let chunk else { return }
        Task { await accumulator.update(chunk: chunk, bytes: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard let chunk = chunkForTask[downloadTask.taskIdentifier] else { return }
        let dest = tempDir.appendingPathComponent("part-\(chunk)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            partURLs[downloadTask.taskIdentifier] = dest
        } catch {
            taskErrors[downloadTask.taskIdentifier] = error
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        let id = task.taskIdentifier
        guard let continuation = continuations.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        let part = partURLs.removeValue(forKey: id)
        let storedError = taskErrors.removeValue(forKey: id)
        let response = task.response as? HTTPURLResponse
        lock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else if let storedError {
            continuation.resume(throwing: storedError)
        } else if let response, !(200..<300).contains(response.statusCode) {
            continuation.resume(throwing: DownloadError.badResponse)
        } else if let part {
            continuation.resume(returning: part)
        } else {
            continuation.resume(throwing: DownloadError.badResponse)
        }
    }
}

/// 多线程分段下载引擎：
/// 先用 HEAD/Range 探测文件大小，然后切成 N 段并发下载，最后按序合并。
/// 产物实际托管在 Azure Blob Storage，支持 Range 请求；
/// 单连接被限速时，多并发能显著提升总速度。
final class DownloadEngine {
    private let lock = NSLock()
    private var session: URLSession?

    func cancel() {
        lock.lock()
        let s = session
        lock.unlock()
        s?.invalidateAndCancel()
    }

    private func setSession(_ s: URLSession?) {
        lock.lock()
        session = s
        lock.unlock()
    }

    func download(signedURL: URL,
                  fileName: String,
                  connections: Int,
                  progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ab-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let total = try await probeSize(url: signedURL)
        let accumulator = ProgressAccumulator(total: total ?? 0, handler: progress)

        let outDir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Artifacts", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var outURL = outDir.appendingPathComponent(fileName)
        if fm.fileExists(atPath: outURL.path) {
            outURL = outDir.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(fileName)")
        }

        // 服务器不支持分块时，退化为单线程下载
        guard let total, total > 0 else {
            let (tmp, resp) = try await URLSession.shared.download(from: signedURL)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DownloadError.badResponse
            }
            try fm.moveItem(at: tmp, to: outURL)
            let size = ((try? fm.attributesOfItem(atPath: outURL.path))?[.size] as? Int64) ?? 0
            await accumulator.finish(downloaded: size)
            try? fm.removeItem(at: tempDir)
            return outURL
        }

        let delegate = ChunkDelegate(accumulator: accumulator, tempDir: tempDir)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        config.httpMaximumConnectionsPerHost = max(1, connections)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        setSession(session)
        defer {
            session.invalidateAndCancel()
            setSession(nil)
            try? fm.removeItem(at: tempDir)
        }

        let chunks = makeChunks(total: total, connections: connections)
        var parts: [(Int, URL)] = []
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for chunk in chunks {
                group.addTask {
                    try await self.downloadChunk(signedURL: signedURL, chunk: chunk, session: session, delegate: delegate)
                }
            }
            for try await part in group {
                parts.append(part)
            }
        }

        // 按顺序合并所有分块
        fm.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        for (_, partURL) in parts.sorted(by: { $0.0 < $1.0 }) {
            let input = try FileHandle(forReadingFrom: partURL)
            while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
                try out.write(contentsOf: data)
            }
            try? input.close()
        }
        try? out.close()

        await accumulator.finish(downloaded: total)
        return outURL
    }

    private func downloadChunk(signedURL: URL,
                               chunk: Chunk,
                               session: URLSession,
                               delegate: ChunkDelegate) async throws -> (Int, URL) {
        var lastError: Error = DownloadError.badResponse
        for attempt in 0..<3 {
            do {
                var req = URLRequest(url: signedURL)
                req.cachePolicy = .reloadIgnoringLocalCacheData
                req.setValue("bytes=\(chunk.start)-\(chunk.end)", forHTTPHeaderField: "Range")
                let partURL: URL = try await withCheckedThrowingContinuation { continuation in
                    let task = session.downloadTask(with: req)
                    delegate.register(task: task, chunk: chunk.index, continuation: continuation)
                    task.resume()
                }
                return (chunk.index, partURL)
            } catch {
                if (error as NSError).code == NSURLErrorCancelled { throw DownloadError.cancelled }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 800_000_000)
                }
            }
        }
        throw lastError
    }

    private func makeChunks(total: Int64, connections: Int) -> [Chunk] {
        let minChunk: Int64 = 2 * 1024 * 1024 // 每段至少 2MB，太碎反而慢
        var count = Int64(max(1, min(connections, 32)))
        if total / count < minChunk {
            count = max(1, total / minChunk)
        }
        let size = (total + count - 1) / count
        var chunks: [Chunk] = []
        var start: Int64 = 0
        while start < total {
            let end = min(start + size - 1, total - 1)
            chunks.append(Chunk(index: chunks.count, start: start, end: end))
            start = end + 1
        }
        return chunks
    }

    /// 探测文件大小：先 HEAD，失败再用 Range: bytes=0-0 读 Content-Range
    private func probeSize(url: URL) async throws -> Int64? {
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.cachePolicy = .reloadIgnoringLocalCacheData
        if let (_, resp) = try? await URLSession.shared.data(for: head),
           let http = resp as? HTTPURLResponse,
           (200..<300).contains(http.statusCode),
           let len = http.value(forHTTPHeaderField: "Content-Length"),
           let total = Int64(len), total > 0 {
            return total
        }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.badResponse }
        if http.statusCode == 206,
           let range = http.value(forHTTPHeaderField: "Content-Range"),
           let last = range.split(separator: "/").last,
           let total = Int64(last.trimmingCharacters(in: .whitespaces)), total > 0 {
            return total
        }
        return nil
    }
}
