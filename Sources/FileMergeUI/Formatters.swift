import Foundation
import FileMergeCore

/// 数值与字节的展示格式化
public enum Formatters {
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    public static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    public static func count(_ value: Int) -> String {
        value.formatted()
    }
}
