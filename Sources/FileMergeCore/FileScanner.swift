import Foundation

/// 并行目录扫描器：多个 worker 从共享目录队列取目录枚举，
/// 有界并发（不会随目录深度无限扩张），适合海量文件场景。
public final class FileScanner: Sendable {
    public let root: URL
    public let concurrency: Int

    public init(root: URL, concurrency: Int = FileMergeConfig.defaultConcurrency) {
        self.root = root
        self.concurrency = max(1, concurrency)
    }

    /// 扫描整个目录树，返回按相对路径排序的文件列表。
    /// - 跳过符号链接（避免环与重复计算）
    /// - 无法读取的目录记录到 warnings，不中断整体扫描
    public func scan(onProgress: (@Sendable (ProgressSnapshot) -> Void)? = nil) async throws -> DirectoryScan {
        try Task.checkCancellation()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError.rootNotADirectory
        }

        let reporter = ProgressReporter(handler: onProgress)
        let state = ScanState()
        state.push(root)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<concurrency {
                group.addTask { try await self.work(state: state, reporter: reporter) }
            }
            try await group.waitForAll()
        }
        try Task.checkCancellation()
        reporter.emit(force: true)

        let result = state.snapshot()
        let sorted = result.files.sorted { $0.relativePath < $1.relativePath }
        return DirectoryScan(root: root, files: sorted, warnings: result.warnings)
    }

    // MARK: - Worker

    private func work(state: ScanState, reporter: ProgressReporter) async throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let rootPath = root.standardizedFileURL.path

        while true {
            try Task.checkCancellation()

            switch state.next() {
            case .done:
                return // 队列空且无 worker 在枚举：扫描结束
            case .retry:
                // 队列暂时为空但仍有 worker 在工作，其可能产出新目录，稍后重试
                try await Task.sleep(for: .milliseconds(2))
                continue
            case .work(let dir):
                defer { state.finishDir() }
                try enumerate(dir: dir, fm: fm, keys: keys, rootPath: rootPath, state: state, reporter: reporter)
            }
        }
    }

    /// 枚举单个目录（同步，无 await，保证锁使用安全）。
    /// 文件按批处理（512 个/批）：批量入列与批量上报，大幅降低海量文件时的锁竞争与分配开销。
    /// 根目录本身不可读取时抛出错误（避免静默返回空结果）；子目录不可读仅记录警告。
    private func enumerate(
        dir: URL,
        fm: FileManager,
        keys: Set<URLResourceKey>,
        rootPath: String,
        state: ScanState,
        reporter: ProgressReporter
    ) throws {
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys), options: []) else {
            if dir.standardizedFileURL.path == rootPath {
                throw ScanError.rootUnreadable
            }
            state.addWarning("无法读取目录：\(dir.path)")
            return
        }

        var pendingFiles: [FileInfo] = []
        var pendingBytes: UInt64 = 0

        for item in items {
            guard let values = try? item.resourceValues(forKeys: keys) else {
                state.addWarning("无法读取文件属性，已跳过：\(item.path)")
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                state.push(item)
            } else if values.isRegularFile == true {
                let size = UInt64(max(0, values.fileSize ?? 0))
                let relative = Self.relativePath(of: item, rootPath: rootPath)
                pendingFiles.append(FileInfo(url: item, relativePath: relative, size: size))
                pendingBytes &+= size
                if pendingFiles.count >= Self.batchSize {
                    state.appendFiles(pendingFiles)
                    reporter.add(files: pendingFiles.count, bytes: pendingBytes)
                    pendingFiles = []
                    pendingBytes = 0
                }
            }
        }

        if !pendingFiles.isEmpty {
            state.appendFiles(pendingFiles)
            reporter.add(files: pendingFiles.count, bytes: pendingBytes)
        }
    }

    private static let batchSize = 512

    static func relativePath(of url: URL, rootPath: String) -> String {
        let itemPath = url.standardizedFileURL.path
        if itemPath.hasPrefix(rootPath + "/") {
            return String(itemPath.dropFirst(rootPath.count + 1))
        }
        return url.lastPathComponent
    }
}

/// worker 取目录的结果
private enum PopResult {
    case work(URL)
    case retry
    case done
}

/// 扫描过程中的共享可变状态（锁保护；所有方法均为同步，避免在 async 上下文直接操作锁）
private final class ScanState: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [URL] = []
    private var busy = 0
    private var files: [FileInfo] = []
    private var warnings: [String] = []

    func next() -> PopResult {
        lock.lock()
        defer { lock.unlock() }
        if let dir = queue.popLast() {
            busy += 1
            return .work(dir)
        }
        return busy == 0 ? .done : .retry
    }

    func push(_ dir: URL) {
        lock.lock()
        queue.append(dir)
        lock.unlock()
    }

    func finishDir() {
        lock.lock()
        busy -= 1
        lock.unlock()
    }

    func appendFiles(_ batch: [FileInfo]) {
        lock.lock()
        files.append(contentsOf: batch)
        lock.unlock()
    }

    func addWarning(_ message: String) {
        lock.lock()
        warnings.append(message)
        lock.unlock()
    }

    func snapshot() -> (files: [FileInfo], warnings: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (files, warnings)
    }
}
