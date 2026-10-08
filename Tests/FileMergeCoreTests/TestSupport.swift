import Foundation
@testable import FileMergeCore

enum TestFS {
    static func makeTempDir(named name: String = UUID().uuidString) -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FileMergeTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func write(_ root: URL, _ relativePath: String, _ content: String) -> URL {
        write(root, relativePath, Data(content.utf8))
    }

    @discardableResult
    static func write(_ root: URL, _ relativePath: String, _ content: Data) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: url)
        return url
    }

    static func makeSymlink(at url: URL, to target: URL) {
        try! FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    }

    /// 读取文本文件；文件不存在时返回 nil（避免并行测试中 try! 崩溃进程）
    static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func scan(_ root: URL, concurrency: Int = 4) async throws -> DirectoryScan {
        try await FileScanner(root: root, concurrency: concurrency).scan()
    }

    static func randomData(_ byteCount: Int, seed: UInt64 = 0x2026_1007) -> Data {
        var rng = SeededGenerator(seed: seed)
        return Data((0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }
}

/// 简单可复现的伪随机数生成器（SplitMix64）
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 快照收集器：线程安全地收集 ProgressSnapshot，用于断言
final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [ProgressSnapshot] = []

    var handler: @Sendable (ProgressSnapshot) -> Void {
        { [weak self] snap in
            guard let self else { return }
            self.lock.lock()
            self.snapshots.append(snap)
            self.lock.unlock()
        }
    }

    var all: [ProgressSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return snapshots
    }

    var last: ProgressSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.last
    }
}
