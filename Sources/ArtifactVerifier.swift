import Foundation

/// 下载完成后的结构校验。
///
/// 为什么需要：引擎保证的是「字节覆盖 + 长度一致」，这能挡住断流/漏段，
/// 但挡不住服务端给出一个长度正确、内容损坏的文件（镜像缓存坏了、
/// 代理截断后补齐、CDN 回源出错）。这类文件解压时才报错，
/// 用户体验就是「下完了却用不了」。
///
/// 校验保持轻量：只读头 4 字节 + 尾部 64KB。
/// ZIP 的中央目录在文件末尾，能读到合法的 EOCD 就说明结构完整；
/// 配合前面的长度校验，足以挡住绝大多数坏包，又不会让 500MB 的文件多等几秒。
enum ArtifactVerifier {
    /// - Returns: nil 表示通过；否则是给用户看的原因
    static func verify(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "文件无法读取"
        }
        defer { try? handle.close() }

        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
        guard size >= 22 else { return "ZIP 文件过小，可能下载不完整" }

        guard let head = try? handle.read(upToCount: 4), head.count == 4 else {
            return "ZIP 头部缺失"
        }
        let headBytes = [UInt8](head)
        let localHeader: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        let emptyArchive: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard headBytes == localHeader || headBytes == emptyArchive else {
            return "不是有效的 ZIP 文件"
        }

        // 中央目录结束记录（EOCD）最多在末尾 65557 字节内
        let tailLength = Int(min(size, 65_557))
        guard (try? handle.seek(toOffset: UInt64(size - Int64(tailLength)))) != nil,
              let tail = try? handle.read(upToCount: tailLength),
              tail.count >= 22 else {
            return "ZIP 尾部读取失败"
        }
        let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let bytes = [UInt8](tail)
        var found = false
        var index = bytes.count - 22
        while index >= 0 {
            if bytes[index] == eocd[0], bytes[index + 1] == eocd[1],
               bytes[index + 2] == eocd[2], bytes[index + 3] == eocd[3] {
                found = true
                break
            }
            index -= 1
        }
        guard found else { return "ZIP 结构不完整（缺少中央目录）" }
        return nil
    }
}
