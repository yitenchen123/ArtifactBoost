import Foundation

/// 断点续传的元数据：记录「这个文件已经下过哪些字节区间」。
///
/// 老实现只在**进程内**续做（分片队列活着的时候），App 一被杀掉、
/// 或者用户点了取消，已下好的几百 MB 就全废了 —— 下次只能从 0 开始。
/// 这份元数据配合半成品文件，让下载可以跨进程续上。
struct ResumeMeta: Codable, Sendable {
    /// 文件总字节数：体积一变（比如 release 附件被重新上传）就不能续了
    var total: Int64
    /// 服务端 ETag / Last-Modified：用来确认「还是同一个文件」
    var etag: String?
    var lastModified: String?
    /// 已覆盖的字节区间，每项是 [start, end] 闭区间
    var ranges: [[Int64]]
    var updatedAt: Date

    var coveredBytes: Int64 {
        ranges.reduce(Int64(0)) { partial, pair in
            guard pair.count == 2, pair[1] >= pair[0] else { return partial }
            return partial + (pair[1] - pair[0] + 1)
        }
    }
}

/// 引擎内部使用的续传上下文。
struct ResumeContext: Sendable {
    let key: String
    let partURL: URL
    let etag: String?
    let lastModified: String?
    /// 上次已经下好的区间（闭区间）
    let covered: [ClosedRange<Int64>]

    var coveredBytes: Int64 {
        covered.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound + 1) }
    }
}

/// 断点续传的落盘仓库。
///
/// 目录选 `Application Support` 而不是 `Caches`：系统会在磁盘紧张时
/// 清空 Caches，那正好会把用户辛苦下了一半的几百 MB 一起清掉。
/// 半成品与元数据成对出现（`<key>.part` + `<key>.json`），
/// 任何一方缺失或校验不过就整对丢弃，绝不拿错文件拼接。
final class ResumeStore: @unchecked Sendable {
    static let shared = ResumeStore()

    private let fm = FileManager.default
    /// 落盘放在串行后台队列：checkpoint 每 1.5s 一次，
    /// 绝不能让 JSON 编码与磁盘写入卡到下载线程上。
    private let io = DispatchQueue(label: "art.artifactboost.resume.io", qos: .utility)
    private let root: URL

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("ArtifactBoost/partial", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func partURL(key: String) -> URL {
        root.appendingPathComponent(Self.fileStem(key) + ".part")
    }

    func metaURL(key: String) -> URL {
        root.appendingPathComponent(Self.fileStem(key) + ".json")
    }

    func load(key: String) -> ResumeMeta? {
        guard let data = try? Data(contentsOf: metaURL(key: key)) else { return nil }
        return try? JSONDecoder().decode(ResumeMeta.self, from: data)
    }

    /// 判断能不能续上；能续就返回上下文，不能续会把残留的半成品清掉。
    ///
    /// 三道校验缺一不可：
    ///  1. 体积一致 —— 文件被替换时体积几乎一定会变；
    ///  2. 半成品文件在，且大小等于总长（引擎建文件时就 truncate 到总长）；
    ///  3. ETag / Last-Modified 一致（两边都有时才比，避免服务端不回这个头就误判）。
    func prepare(key: String,
                 total: Int64,
                 etag: String?,
                 lastModified: String?,
                 fileName: String?) -> ResumeContext? {
        guard let meta = load(key: key) else {
            // 没有元数据：把可能的孤儿半成品清掉，从头下
            try? fm.removeItem(at: partURL(key: key))
            return nil
        }
        let part = partURL(key: key)
        guard meta.total == total,
              fm.fileExists(atPath: part.path),
              let size = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? Int64,
              size == total else {
            discard(key: key)
            return nil
        }
        if let old = meta.etag, let new = etag, !old.isEmpty, !new.isEmpty, old != new {
            discard(key: key)
            return nil
        }
        let covered = meta.ranges.compactMap { pair -> ClosedRange<Int64>? in
            guard pair.count == 2, pair[0] >= 0, pair[1] >= pair[0], pair[1] < total else { return nil }
            return pair[0]...pair[1]
        }
        // 元数据里一个有效区间都没有（损坏）时当作没有续传记录
        guard !covered.isEmpty else {
            discard(key: key)
            return nil
        }
        return ResumeContext(key: key,
                             partURL: part,
                             etag: etag ?? meta.etag,
                             lastModified: lastModified ?? meta.lastModified,
                             covered: covered)
    }

    /// 同步落盘（取消 / 失败收尾用：必须保证进程退出前写进去）
    func saveNow(_ meta: ResumeMeta, key: String) {
        persist(meta, key: key)
    }

    /// 异步落盘（周期 checkpoint 用，不阻塞下载线程）
    func save(_ meta: ResumeMeta, key: String) {
        io.async { [weak self] in
            self?.persist(meta, key: key)
        }
    }

    /// 丢弃该任务的全部续传数据（用户主动取消 / 下载完成）
    func discard(key: String) {
        io.async { [weak self] in
            guard let self else { return }
            try? self.fm.removeItem(at: self.partURL(key: key))
            try? self.fm.removeItem(at: self.metaURL(key: key))
        }
    }

    /// 清理过期残留（默认 7 天）：防止用户中途放弃的任务永久占着磁盘
    func prune(olderThan age: TimeInterval = 7 * 24 * 3600) {
        io.async { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-age)
            let files = (try? self.fm.contentsOfDirectory(at: self.root,
                                                          includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff {
                    try? self.fm.removeItem(at: file)
                }
            }
        }
    }

    // MARK: - 内部

    private func persist(_ meta: ResumeMeta, key: String) {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        // `.atomic`：写到临时文件再原子替换，进程在写入途中被杀也不会留下半截 JSON
        try? data.write(to: metaURL(key: key), options: .atomic)
    }

    /// 把下载项 id 变成安全的文件名：加一个稳定哈希后缀，
    /// 避免 `owner/repo` 这类含斜杠的 key 在转义后互相撞名。
    static func fileStem(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let digest = String(hash, radix: 16)
        let readable = String(key.map { ch -> Character in
            ch.isLetter || ch.isNumber || ch == "-" || ch == "." ? ch : "_"
        }.prefix(48))
        return "\(readable)-\(digest)"
    }
}
