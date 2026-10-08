import Foundation
@testable import FileMergeCore

/// FileMergeUITests 目标内使用的最小文件夹具助手
enum UITestFS {
    static func makeTempDir() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FileMergeUITests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func write(_ root: URL, _ relativePath: String, _ content: String) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: url)
        return url
    }

    static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
