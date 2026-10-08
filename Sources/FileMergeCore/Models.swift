import Foundation

/// 全局配置：并发度、分块大小、节流间隔等
public enum FileMergeConfig {
    /// 默认并发度：取 CPU 核心数，限制在 4~16 之间，避免海量文件时过度占用资源
    public static let defaultConcurrency: Int = min(max(4, ProcessInfo.processInfo.activeProcessorCount), 16)
    /// 哈希计算的分块读取大小（1 MB）
    public static let hashChunkSize: Int = 1 << 20
    /// 头部哈希采样字节数（64 KB），用于同尺寸文件的快速预筛
    public static let headHashBytes: Int = 1 << 16
    /// 进度回调节流间隔（秒），避免海量文件时 UI 更新风暴
    public static let progressThrottleInterval: TimeInterval = 0.1
    /// 单个日志缓冲上限
    public static let logLineLimit: Int = 2000
}

/// 单个文件的元信息
public struct FileInfo: Sendable, Hashable {
    /// 文件绝对路径
    public let url: URL
    /// 相对于扫描根目录的路径（以 / 分隔）
    public let relativePath: String
    /// 文件大小（字节，逻辑大小）
    public let size: UInt64

    public init(url: URL, relativePath: String, size: UInt64) {
        self.url = url
        self.relativePath = relativePath
        self.size = size
    }
}

/// 扫描统计
public struct ScanStats: Sendable, Equatable {
    public var fileCount: Int = 0
    public var totalSize: UInt64 = 0

    public init(fileCount: Int = 0, totalSize: UInt64 = 0) {
        self.fileCount = fileCount
        self.totalSize = totalSize
    }
}

/// 一个目录的完整扫描结果
public struct DirectoryScan: Sendable {
    public let root: URL
    /// 文件列表，按 relativePath 升序排列
    public let files: [FileInfo]
    /// 扫描过程中无法读取的目录/条目警告
    public let warnings: [String]

    public init(root: URL, files: [FileInfo], warnings: [String] = []) {
        self.root = root
        self.files = files
        self.warnings = warnings
    }

    public var stats: ScanStats {
        ScanStats(fileCount: files.count, totalSize: files.reduce(0) { $0 + $1.size })
    }
}

/// 统一的进度快照（扫描 / 哈希 / 合并共用）
/// - totalFiles / totalBytes 为 nil 表示总量未知（如扫描阶段），UI 显示为不定进度
public struct ProgressSnapshot: Sendable, Equatable {
    /// 单调递增序列号，用于丢弃乱序到达的过期快照
    public var seq: UInt64
    public var files: Int
    public var bytes: UInt64
    public var totalFiles: Int?
    public var totalBytes: UInt64?
}

/// 文件来源
public enum FileOrigin: String, Sendable, CaseIterable, Comparable {
    case main
    case secondary

    private var rank: Int {
        switch self {
        case .main: 0
        case .secondary: 1
        }
    }

    public static func < (lhs: FileOrigin, rhs: FileOrigin) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// 合并计划中的一个条目：把 sourceURL 写入最终目录的 relativePath
public struct PlanEntry: Sendable, Hashable {
    public let origin: FileOrigin
    public let sourceURL: URL
    public let relativePath: String
    public let size: UInt64
    /// 去重过程中计算出的全量哈希；尺寸唯一的文件未计算哈希时为 nil
    public let hash: String?

    public init(origin: FileOrigin, sourceURL: URL, relativePath: String, size: UInt64, hash: String?) {
        self.origin = origin
        self.sourceURL = sourceURL
        self.relativePath = relativePath
        self.size = size
        self.hash = hash
    }
}

/// 合并计划：排重后待写入最终目录的全部文件
public struct MergePlan: Sendable {
    /// 待复制文件（主目录文件在前，副目录文件在后，各自按相对路径排序）
    public let entries: [PlanEntry]
    /// 被去除的重复文件数量
    public let duplicatesCount: Int
    /// 去重节省的空间（字节）
    public let savedBytes: UInt64

    public init(entries: [PlanEntry], duplicatesCount: Int, savedBytes: UInt64) {
        self.entries = entries
        self.duplicatesCount = duplicatesCount
        self.savedBytes = savedBytes
    }

    public var estimatedFileCount: Int { entries.count }
    public var estimatedTotalSize: UInt64 { entries.reduce(0) { $0 + $1.size } }
}

/// 合并预估信息（展示用）
public struct MergeEstimate: Sendable, Equatable {
    public let fileCount: Int
    public let totalSize: UInt64
    public let duplicates: Int
    public let savedBytes: UInt64

    public init(fileCount: Int, totalSize: UInt64, duplicates: Int, savedBytes: UInt64) {
        self.fileCount = fileCount
        self.totalSize = totalSize
        self.duplicates = duplicates
        self.savedBytes = savedBytes
    }
}

/// 合并执行结果
public struct MergeResult: Sendable {
    public var copiedFiles: Int = 0
    public var copiedBytes: UInt64 = 0
    /// 目标已存在且内容一致的文件（幂等重跑时跳过）
    public var skippedFiles: Int = 0
    /// 因相对路径冲突而重命名的文件数
    public var renamedFiles: Int = 0
    public var errors: [String] = []

    public init() {}
}

/// 扫描错误
public enum ScanError: Error, Equatable, LocalizedError {
    case rootNotADirectory
    /// 根目录存在但无法枚举内容（权限不足或已被移除）
    case rootUnreadable

    public var errorDescription: String? {
        switch self {
        case .rootNotADirectory: "所选路径不是目录，无法扫描"
        case .rootUnreadable: "无法读取所选目录的内容，请检查权限后重试"
        }
    }
}
