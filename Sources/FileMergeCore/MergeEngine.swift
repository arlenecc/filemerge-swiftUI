import Foundation

/// 合并执行引擎：
/// 1. 先串行计算每个条目的目标路径（主目录文件按相对路径直写；副目录文件冲突时重命名），
/// 2. 再按有界并发并行复制，写过程中按节流上报进度。
/// 目标已存在且内容一致的条目会被跳过（支持幂等重跑）；单文件失败记录错误、不中断整体。
public struct MergeEngine: Sendable {
    public let plan: MergePlan
    public let destination: URL

    public init(plan: MergePlan, destination: URL) {
        self.plan = plan
        self.destination = destination
    }

    enum FileAction: Equatable, Sendable {
        case copy
        case overwrite
        case skip
        case rename(String)
    }

    struct CopyOp: Sendable {
        let entry: PlanEntry
        let destinationURL: URL
        let action: FileAction
    }

    /// 目标路径的预检状态（并行计算，供串行决策使用）
    struct DestState: Sendable {
        let exists: Bool
        let sameContent: Bool
    }

    public func merge(
        concurrency: Int = FileMergeConfig.defaultConcurrency,
        onProgress: (@Sendable (ProgressSnapshot) -> Void)? = nil
    ) async throws -> MergeResult {
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let reporter = ProgressReporter(
            handler: onProgress,
            totalFiles: plan.entries.count,
            totalBytes: plan.estimatedTotalSize
        )

        // ---- 第 1 步：并行预检目标状态（存在性 + 内容一致性）----
        // 幂等重跑时需要对目标文件做全量哈希，并行预检避免决策阶段串行读盘拖慢整体；
        // 比对可取消，大文件场景下取消合并能立即生效
        let dest = self.destination
        let destStates = try await ParallelMap.run(plan.entries, concurrency: concurrency) { entry -> DestState in
            let target = dest.appendingPathComponent(entry.relativePath)
            guard FileManager.default.fileExists(atPath: target.path) else {
                return DestState(exists: false, sameContent: false)
            }
            let same = try await FileHasher.filesHaveSameContent(entry.sourceURL, target)
            return DestState(exists: true, sameContent: same)
        }

        // ---- 第 2 步：串行决策（冲突与重命名需要全局顺序）----
        var claimed = Set<String>()
        var ops: [CopyOp] = []
        ops.reserveCapacity(plan.entries.count)

        for (entry, state) in zip(plan.entries, destStates) {
            try Task.checkCancellation()
            let relative = entry.relativePath
            var finalRelative = relative
            var action: FileAction = .copy

            if claimed.contains(relative) {
                // 仅副目录条目可能与更早的条目同路径（主目录条目相对路径天然唯一）
                (action, finalRelative) = try await placeSecondary(entry: entry, relative: relative, claimed: &claimed)
            } else if state.exists {
                if state.sameContent {
                    action = .skip
                } else if entry.origin == .main {
                    action = .overwrite  // 主目录优先，覆盖陈旧内容
                } else {
                    (action, finalRelative) = try await placeSecondary(entry: entry, relative: relative, claimed: &claimed)
                }
            }

            claimed.insert(relative)
            ops.append(CopyOp(
                entry: entry,
                destinationURL: dest.appendingPathComponent(finalRelative),
                action: action
            ))
        }

        // ---- 第 3 步：集中创建父目录（避免每文件一次 mkdir 系统调用）----
        var parents = Set<String>()
        for op in ops where op.action != .skip {
            parents.insert(op.destinationURL.deletingLastPathComponent().path)
        }
        for parent in parents.sorted() {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        }

        // ---- 第 4 步：并行复制（任务内实时上报进度）----
        var result = MergeResult()

        let outcomes = try await ParallelMap.run(ops, concurrency: concurrency) { op -> Outcome in
            let outcome = Self.perform(op: op)
            reporter.add(files: 1, bytes: op.entry.size)
            return outcome
        }

        for (op, outcome) in zip(ops, outcomes) {
            switch outcome {
            case .copied(let renamed):
                result.copiedFiles += 1
                result.copiedBytes += op.entry.size
                if renamed { result.renamedFiles += 1 }
            case .skipped:
                result.skippedFiles += 1
            case .failed(let message):
                result.errors.append(message)
            }
        }

        reporter.emit(force: true)
        return result
    }

    enum Outcome: Sendable {
        case copied(renamed: Bool)
        case skipped
        case failed(String)
    }

    static func perform(op: CopyOp) -> Outcome {
        let fm = FileManager.default
        switch op.action {
        case .skip:
            return .skipped
        case .copy, .overwrite, .rename:
            do {
                let target = op.destinationURL
                if op.action == .overwrite {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
                        // 目标位置是目录时拒绝覆盖，避免递归删除整个子树
                        return .failed("目标位置已被目录占用，拒绝覆盖：\(op.entry.relativePath)")
                    }
                    try fm.removeItem(at: target)
                }
                try fm.copyItem(at: op.entry.sourceURL, to: target)
                return .copied(renamed: {
                    if case .rename = op.action { return true }
                    return false
                }())
            } catch {
                return .failed("复制失败：\(op.entry.relativePath) → \(error.localizedDescription)")
            }
        }
    }

    /// 为副目录条目在目标目录中寻找落位：
    /// - 候选 "名称 (n).扩展名" 不存在 → 在该处改名写入；
    /// - 候选已存在且内容与源一致 → 幂等跳过（重复重跑不产生新副本）；
    /// - 候选已存在但内容不同 → 顺延编号继续找。
    /// 返回 (动作, 最终相对路径)。
    private func placeSecondary(
        entry: PlanEntry,
        relative: String,
        claimed: inout Set<String>
    ) async throws -> (FileAction, String) {
        let fm = FileManager.default
        let directory = (relative as NSString).deletingLastPathComponent
        let fileName = (relative as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension

        for n in 1...9_999 {
            try Task.checkCancellation()
            let candidateName = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let candidateRelative = directory.isEmpty ? candidateName : "\(directory)/\(candidateName)"
            let candidateURL = destination.appendingPathComponent(candidateRelative)
            guard fm.fileExists(atPath: candidateURL.path) else {
                claimed.insert(candidateRelative)
                return (.rename(candidateRelative), candidateRelative)
            }
            if try await FileHasher.filesHaveSameContent(entry.sourceURL, candidateURL) {
                // 幂等重跑：候选位已是该文件的先前副本，无需再写
                claimed.insert(candidateRelative)
                return (.skip, candidateRelative)
            }
        }
        // 理论上不可达：以 UUID 兜底保证不覆盖任何文件
        let fallback = directory.isEmpty
            ? "\(stem)-\(UUID().uuidString)"
            : "\(directory)/\(stem)-\(UUID().uuidString)"
        claimed.insert(fallback)
        return (.rename(fallback), fallback)
    }
}
