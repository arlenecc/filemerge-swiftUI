import Foundation
import FileMergeCore

/// 单条日志
public struct LogEntry: Identifiable, Equatable {
    public let id: Int
    public let text: String
}

/// 界面状态机：串联 扫描 → 排重 → 合并 三个阶段，
/// 引擎在后台并发执行，进度通过节流回调跳回主线程更新，
/// 海量文件时 UI 不会被进度事件淹没。
@MainActor
public final class AppViewModel: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case analyzing
        case analyzed
        case merging
        case merged
        case failed(String)
    }

    // MARK: - 发布状态

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var mainDir: URL?
    @Published public private(set) var secondaryDir: URL?
    @Published public private(set) var destinationDir: URL?
    @Published public private(set) var mainStats: ScanStats?
    @Published public private(set) var secondaryStats: ScanStats?
    @Published public private(set) var estimate: MergeEstimate?
    /// nil 表示不定进度（如扫描阶段总量未知）
    @Published public private(set) var progressValue: Double?
    @Published public private(set) var progressText: String = "就绪"
    @Published public private(set) var logEntries: [LogEntry] = []

    // MARK: - 私有状态

    private var plan: MergePlan?
    private var analysisMainURL: URL?
    private var analysisSecondaryURL: URL?
    private var currentTask: Task<Void, Never>?
    private var nextLogID = 0
    private var lastSeqByStage: [String: UInt64] = [:]

    public init() {}

    // MARK: - 派生状态

    public var busy: Bool { phase == .analyzing || phase == .merging }

    public var canStartAnalysis: Bool {
        mainDir != nil && secondaryDir != nil && destinationDir != nil && !busy
    }

    public var canStartMerge: Bool {
        plan != nil && destinationDir != nil && !busy
    }

    public var phaseLabel: String {
        switch phase {
        case .idle: "就绪"
        case .analyzing: "分析中"
        case .analyzed: "分析完成"
        case .merging: "合并中"
        case .merged: "合并完成"
        case .failed: "失败"
        }
    }

    // MARK: - 目录设置

    public func setMainDir(_ url: URL?) {
        guard url != mainDir else { return }
        mainDir = url
        invalidateAnalysis()
    }

    public func setSecondaryDir(_ url: URL?) {
        guard url != secondaryDir else { return }
        secondaryDir = url
        invalidateAnalysis()
    }

    /// 更换最终目录不影响已有分析结果（合并时使用新目录）
    public func setDestinationDir(_ url: URL?) {
        destinationDir = url
    }

    private func invalidateAnalysis() {
        plan = nil
        estimate = nil
        mainStats = nil
        secondaryStats = nil
        guard !busy else { return }
        phase = .idle
        progressValue = nil
        progressText = "就绪"
    }

    // MARK: - 操作入口（UI 用）

    public func beginAnalysis() {
        guard !busy else { return }
        currentTask = Task { await startAnalysis() }
    }

    public func beginMerge() {
        guard !busy else { return }
        currentTask = Task { await startMerge() }
    }

    public func cancel() {
        currentTask?.cancel()
    }

    // MARK: - 分析

    public func startAnalysis() async {
        guard !busy else { return }
        guard let m = mainDir, let s = secondaryDir, let d = destinationDir else {
            phase = .failed("请先选择主目录、副目录和最终目录")
            return
        }
        do {
            try MergeValidator.validate(main: m, secondary: s, destination: d)
        } catch {
            phase = .failed(error.localizedDescription)
            log("校验失败：\(error.localizedDescription)")
            return
        }

        plan = nil
        estimate = nil
        mainStats = nil
        secondaryStats = nil
        lastSeqByStage.removeAll()
        analysisMainURL = m
        analysisSecondaryURL = s
        phase = .analyzing
        progressValue = nil
        progressText = "正在扫描…"
        log("开始分析…")

        do {
            log("正在扫描主目录：\(m.path)")
            let mainScan = try await FileScanner(root: m).scan(onProgress: progressHandler("scanMain"))
            mainStats = mainScan.stats
            log("主目录扫描完成：\(Formatters.count(mainScan.stats.fileCount)) 个文件，共 \(Formatters.bytes(mainScan.stats.totalSize))")
            if !mainScan.warnings.isEmpty {
                log("主目录有 \(mainScan.warnings.count) 个子目录无法读取（已跳过）")
            }

            log("正在扫描副目录：\(s.path)")
            let secondaryScan = try await FileScanner(root: s).scan(onProgress: progressHandler("scanSecondary"))
            secondaryStats = secondaryScan.stats
            log("副目录扫描完成：\(Formatters.count(secondaryScan.stats.fileCount)) 个文件，共 \(Formatters.bytes(secondaryScan.stats.totalSize))")
            if !secondaryScan.warnings.isEmpty {
                log("副目录有 \(secondaryScan.warnings.count) 个子目录无法读取（已跳过）")
            }

            log("正在计算文件哈希并全局排重…")
            let builtPlan = try await DedupEngine.buildPlan(
                main: mainScan,
                secondary: secondaryScan,
                onProgress: progressHandler("hash")
            )
            plan = builtPlan
            estimate = MergeEstimate(
                fileCount: builtPlan.estimatedFileCount,
                totalSize: builtPlan.estimatedTotalSize,
                duplicates: builtPlan.duplicatesCount,
                savedBytes: builtPlan.savedBytes
            )
            log("排重完成：唯一文件 \(Formatters.count(builtPlan.estimatedFileCount)) 个，重复 \(Formatters.count(builtPlan.duplicatesCount)) 个，可节省 \(Formatters.bytes(builtPlan.savedBytes))")
            log("分析完成。预计合并后：\(Formatters.count(builtPlan.estimatedFileCount)) 个文件，共 \(Formatters.bytes(builtPlan.estimatedTotalSize))。可点击「开始合并」。")
            progressValue = 1.0
            progressText = "分析完成"
            phase = .analyzed
        } catch is CancellationError {
            phase = .idle
            progressValue = nil
            progressText = "已取消"
            log("分析已取消")
        } catch {
            phase = .failed("分析失败：\(error.localizedDescription)")
            log(phaseText(of: phase))
        }
    }

    // MARK: - 合并

    public func startMerge() async {
        guard !busy else { return }
        guard let p = plan, let d = destinationDir, let m = analysisMainURL, let s = analysisSecondaryURL else {
            phase = .failed("请先完成分析，再开始合并")
            return
        }
        do {
            try MergeValidator.validate(main: m, secondary: s, destination: d)
        } catch {
            phase = .failed(error.localizedDescription)
            log("校验失败：\(error.localizedDescription)")
            return
        }

        phase = .merging
        progressValue = 0
        progressText = "正在合并…"
        log("开始合并：共 \(Formatters.count(p.estimatedFileCount)) 个文件，目标：\(d.path)")

        do {
            let engine = MergeEngine(plan: p, destination: d)
            let result = try await engine.merge(onProgress: progressHandler("merge"))

            for message in result.errors.prefix(10) {
                log("错误：\(message)")
            }
            if result.errors.count > 10 {
                log("…另有 \(Formatters.count(result.errors.count - 10)) 个错误未展示")
            }
            log("合并完成：复制 \(Formatters.count(result.copiedFiles)) 个（\(Formatters.bytes(result.copiedBytes))），跳过 \(Formatters.count(result.skippedFiles)) 个，重命名 \(Formatters.count(result.renamedFiles)) 个，失败 \(Formatters.count(result.errors.count)) 个")
            progressValue = 1.0
            progressText = "合并完成"
            phase = .merged
        } catch is CancellationError {
            // 计划仍有效，回到“已分析”状态允许再次合并
            phase = .analyzed
            progressText = "已取消"
            progressValue = nil
            log("合并已取消")
        } catch {
            phase = .failed("合并失败：\(error.localizedDescription)")
            log(phaseText(of: phase))
        }
    }

    // MARK: - 进度与日志

    /// 构造某个阶段的节流进度回调；回调从后台线程跳回主线程更新发布属性
    private func progressHandler(_ stage: String) -> @Sendable (ProgressSnapshot) -> Void {
        { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.applyProgress(snapshot, stage: stage)
            }
        }
    }

    private func applyProgress(_ snapshot: ProgressSnapshot, stage: String) {
        // 阶段已切换后的迟到事件直接丢弃
        switch phase {
        case .analyzing:
            guard ["scanMain", "scanSecondary", "hash"].contains(stage) else { return }
        case .merging:
            guard stage == "merge" else { return }
        default:
            return
        }
        // 丢弃乱序到达的过期快照
        if let last = lastSeqByStage[stage], snapshot.seq < last { return }
        lastSeqByStage[stage] = snapshot.seq

        let fileText = "已处理 \(Formatters.count(snapshot.files)) 个文件"
        switch stage {
        case "scanMain":
            progressValue = nil
            progressText = "正在扫描主目录…\(fileText)（\(Formatters.bytes(snapshot.bytes))）"
        case "scanSecondary":
            progressValue = nil
            progressText = "正在扫描副目录…\(fileText)（\(Formatters.bytes(snapshot.bytes))）"
        case "hash":
            // 预筛与全量哈希共用同一进度流（总量自动扩展），进度条连续不回跳
            if let total = snapshot.totalBytes, total > 0 {
                let ratio = Double(snapshot.bytes) / Double(total)
                progressValue = min(1, ratio)
                progressText = "正在计算哈希排重…\(Int((ratio * 100).rounded()))%（\(fileText)）"
            } else {
                progressValue = nil
                progressText = "正在计算哈希排重…\(fileText)"
            }
        case "merge":
            if let total = snapshot.totalBytes, total > 0 {
                let ratio = Double(snapshot.bytes) / Double(total)
                progressValue = min(1, ratio)
                progressText = "正在合并…\(Int((ratio * 100).rounded()))%（\(fileText)）"
            } else {
                progressValue = nil
                progressText = "正在合并…\(fileText)"
            }
        default:
            break
        }
    }

    private func log(_ text: String) {
        nextLogID += 1
        logEntries.append(LogEntry(id: nextLogID, text: text))
        if logEntries.count > FileMergeConfig.logLineLimit {
            logEntries.removeFirst(logEntries.count - FileMergeConfig.logLineLimit)
        }
    }

    private func phaseText(of phase: Phase) -> String {
        switch phase {
        case .failed(let message): message
        default: ""
        }
    }
}
