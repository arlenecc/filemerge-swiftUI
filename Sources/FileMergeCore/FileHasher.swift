import CryptoKit
import Foundation

/// 流式文件哈希：固定内存占用（分块读取），支持取消。
public enum FileHasher {
    /// 计算 Data 的 SHA256 十六进制字符串
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 流式计算整个文件的 SHA256（分块读取，内存占用恒定为 chunkSize）
    public static func hashFile(at url: URL, chunkSize: Int = FileMergeConfig.hashChunkSize) async throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize) {
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            if Task.isCancelled { throw CancellationError() }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 只读文件头部若干字节计算哈希，用于同尺寸文件的快速预筛
    public static func headHash(at url: URL, headBytes: Int = FileMergeConfig.headHashBytes) async throws -> String {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: headBytes) ?? Data()
        return sha256Hex(of: head)
    }

    /// 判断两个文件内容是否一致：先比大小，再比全量哈希。
    /// 分块读取且每块后检查取消（大文件比对时取消能立即生效）；
    /// 普通 IO 失败视为不一致（返回 false），取消错误继续向上传播。
    public static func filesHaveSameContent(_ a: URL, _ b: URL) async throws -> Bool {
        guard a != b else { return true }
        let fm = FileManager.default
        guard
            let sa = try? fm.attributesOfItem(atPath: a.path)[.size] as? UInt64,
            let sb = try? fm.attributesOfItem(atPath: b.path)[.size] as? UInt64
        else { return false }
        guard sa == sb else { return false }
        let ha: String
        let hb: String
        do {
            ha = try await hashFile(at: a)
            hb = try await hashFile(at: b)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
        return ha == hb
    }
}
