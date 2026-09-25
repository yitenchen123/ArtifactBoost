import Foundation

func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSpeed(_ bytesPerSecond: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)), countStyle: .file) + "/s"
}
