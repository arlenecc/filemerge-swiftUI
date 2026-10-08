import Foundation

/// 线程安全的进度累加器：内部累积计数，按时间节流对外回调，
/// 避免海量文件场景下回调风暴拖垮 UI。
public final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Int = 0
    private var bytes: UInt64 = 0
    private var seq: UInt64 = 0
    private var lastEmitAt: Date = .distantPast
    private var hasEmitted = false

    private var totalFiles: Int?
    private var totalBytes: UInt64?
    private let throttleInterval: TimeInterval
    private let handler: (@Sendable (ProgressSnapshot) -> Void)?

    public init(
        handler: (@Sendable (ProgressSnapshot) -> Void)? = nil,
        throttleInterval: TimeInterval = FileMergeConfig.progressThrottleInterval,
        totalFiles: Int? = nil,
        totalBytes: UInt64? = nil
    ) {
        self.handler = handler
        self.throttleInterval = throttleInterval
        self.totalFiles = totalFiles
        self.totalBytes = totalBytes
    }

    /// 累加进度；达到节流间隔时向 handler 发出一次快照
    public func add(files: Int, bytes: UInt64) {
        let shouldEmit: Bool
        let snapshot: ProgressSnapshot?
        lock.lock()
        self.files += files
        self.bytes &+= bytes
        let now = Date()
        if throttleInterval <= 0 || now.timeIntervalSince(lastEmitAt) >= throttleInterval {
            lastEmitAt = now
            shouldEmit = true
            seq &+= 1
            snapshot = makeSnapshotLocked()
        } else {
            shouldEmit = false
            snapshot = nil
        }
        lock.unlock()
        if shouldEmit, let snapshot, let handler {
            handler(snapshot)
        }
    }

    /// 扩大阶段总量（哈希预筛结束后追加幸存者数量，保持同一进度流的连续性，
    /// 避免拆成两个 reporter 导致 seq 重置与进度条回跳）
    public func expandTotals(files: Int, bytes: UInt64) {
        lock.lock()
        totalFiles = totalFiles.map { $0 + files }
        totalBytes = totalBytes.map { $0 &+ bytes }
        lock.unlock()
    }

    /// 强制发出当前累计快照（阶段结束时调用，保证最终进度可达 100%）
    public func emit(force: Bool = true) {
        guard force else { return }
        let snapshot: ProgressSnapshot
        lock.lock()
        seq &+= 1
        snapshot = makeSnapshotLocked()
        lock.unlock()
        handler?(snapshot)
    }

    private func makeSnapshotLocked() -> ProgressSnapshot {
        ProgressSnapshot(
            seq: seq,
            files: files,
            bytes: bytes,
            totalFiles: totalFiles,
            totalBytes: totalBytes
        )
    }
}
