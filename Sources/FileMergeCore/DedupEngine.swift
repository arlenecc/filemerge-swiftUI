import Foundation

/// 全局统一排重引擎：
/// 1. 合并主、副目录全部文件，按文件尺寸分组——尺寸唯一的文件无需哈希即唯一；
/// 2. 同尺寸组先做头部哈希预筛，仍冲突的再做全量哈希，最大限度减少 IO；
/// 3. 内容完全相同的文件为一个簇，保留顺序最靠前者（主目录优先，其后按相对路径升序），其余视为重复。
public enum DedupEngine {
    struct Candidate: Sendable {
        let file: FileInfo
        let origin: FileOrigin
    }

    public static func buildPlan(
        main: DirectoryScan,
        secondary: DirectoryScan,
        concurrency: Int = FileMergeConfig.defaultConcurrency,
        onProgress: (@Sendable (ProgressSnapshot) -> Void)? = nil
    ) async throws -> MergePlan {
        try Task.checkCancellation()
        var candidates: [Candidate] = []
        candidates.reserveCapacity(main.files.count + secondary.files.count)
        for file in main.files { candidates.append(Candidate(file: file, origin: .main)) }
        for file in secondary.files { candidates.append(Candidate(file: file, origin: .secondary)) }

        // ---- 第 1 步：按尺寸分组 ----
        var bySize: [UInt64: [Candidate]] = [:]
        for candidate in candidates {
            bySize[candidate.file.size, default: []].append(candidate)
        }

        var uniqueCandidates: [Candidate] = []
        var sizeGroups: [[Candidate]] = []
        for (_, group) in bySize {
            if group.count == 1 {
                uniqueCandidates.append(group[0])
            } else {
                sizeGroups.append(group)
            }
        }

        // 同一文件可能因主/副目录嵌套重叠被扫描两次：按绝对路径缓存哈希避免重复 IO
        let cache = HashCache()

        // ---- 第 2 步：头部哈希预筛 ----
        // 两阶段共用同一个 reporter：seq 保持单调，总量在进入全量哈希阶段时扩展，
        // 进度条不会回跳，UI 也能用单一 stage 识别整个哈希阶段
        let filesNeedingHash = sizeGroups.reduce(0) { $0 + $1.count }
        let bytesNeedingHash = sizeGroups.reduce(UInt64(0)) { $0 + $1.reduce(0) { $0 + $1.file.size } }
        let reporter = ProgressReporter(
            handler: onProgress,
            totalFiles: filesNeedingHash,
            totalBytes: bytesNeedingHash
        )

        var survivors: [Candidate] = []  // 头部哈希后仍无法判定唯一的候选
        var settled: [Candidate] = uniqueCandidates

        for group in sizeGroups {
            try Task.checkCancellation()
            // 小于等于头部字节数的文件，头部哈希即全量哈希，直接按哈希聚类
            let headHashes = try await ParallelMap.run(group, concurrency: concurrency) { candidate -> (Candidate, String) in
                let hash: String
                if candidate.file.size <= UInt64(FileMergeConfig.headHashBytes) {
                    hash = try await Self.fullHash(of: candidate.file.url, cache: cache)
                } else if let hit = cache.headHash(at: candidate.file.url) {
                    hash = hit
                } else {
                    let value = try await FileHasher.headHash(at: candidate.file.url)
                    cache.setHeadHash(at: candidate.file.url, value: value)
                    hash = value
                }
                reporter.add(files: 1, bytes: candidate.file.size)
                return (candidate, hash)
            }

            // 按 (尺寸, 头部哈希) 再分组
            var byHead: [String: [Candidate]] = [:]
            for (candidate, head) in headHashes {
                byHead["\(candidate.file.size)-\(head)", default: []].append(candidate)
            }
            for (_, sub) in byHead {
                if sub.count == 1 {
                    settled.append(sub[0])
                } else {
                    survivors.append(contentsOf: sub)
                }
            }
        }

        // ---- 第 3 步：全量哈希定案（幸存者追加进同一进度流的总量）----
        reporter.expandTotals(
            files: survivors.count,
            bytes: survivors.reduce(UInt64(0)) { $0 + $1.file.size }
        )
        var clusters: [[Candidate]] = []
        if !survivors.isEmpty {
            let fullHashes = try await ParallelMap.run(survivors, concurrency: concurrency) { candidate -> (Candidate, String) in
                let hash = try await Self.fullHash(of: candidate.file.url, cache: cache)
                reporter.add(files: 1, bytes: candidate.file.size)
                return (candidate, hash)
            }
            var byFull: [String: [Candidate]] = [:]
            for (candidate, hash) in fullHashes {
                byFull[hash, default: []].append(candidate)
            }
            for (_, cluster) in byFull {
                clusters.append(cluster)
            }
        }

        // ---- 第 4 步：逐簇保留最优先者，生成计划 ----
        var entries: [PlanEntry] = []
        var duplicatesCount = 0
        var savedBytes: UInt64 = 0

        for cluster in clusters {
            let sorted = cluster.sorted { a, b in
                if a.origin != b.origin { return a.origin < b.origin }
                return a.file.relativePath < b.file.relativePath
            }
            let winner = sorted[0]
            let hash = cache.fullHash(at: winner.file.url)
            entries.append(PlanEntry(
                origin: winner.origin,
                sourceURL: winner.file.url,
                relativePath: winner.file.relativePath,
                size: winner.file.size,
                hash: hash
            ))
            duplicatesCount += sorted.count - 1
            savedBytes += winner.file.size * UInt64(sorted.count - 1)
        }

        for candidate in settled {
            entries.append(PlanEntry(
                origin: candidate.origin,
                sourceURL: candidate.file.url,
                relativePath: candidate.file.relativePath,
                size: candidate.file.size,
                hash: nil  // 尺寸/头部唯一，未计算全量哈希
            ))
        }

        // 主目录文件在前、副目录在后，各自按相对路径升序，保证确定性
        entries.sort { a, b in
            if a.origin != b.origin { return a.origin < b.origin }
            return a.relativePath < b.relativePath
        }

        reporter.emit(force: true)
        return MergePlan(entries: entries, duplicatesCount: duplicatesCount, savedBytes: savedBytes)
    }

    /// 取全量哈希（优先命中缓存，否则现算并写缓存）
    private static func fullHash(of url: URL, cache: HashCache) async throws -> String {
        if let hit = cache.fullHash(at: url) { return hit }
        let value = try await FileHasher.hashFile(at: url)
        cache.setFullHash(at: url, value: value)
        return value
    }
}

/// 哈希缓存：锁保护的同步方法，供并发任务安全读写
private final class HashCache: @unchecked Sendable {
    private let lock = NSLock()
    private var full: [String: String] = [:]
    private var head: [String: String] = [:]

    func fullHash(at url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return full[url.path]
    }

    func setFullHash(at url: URL, value: String) {
        lock.lock()
        full[url.path] = value
        lock.unlock()
    }

    func headHash(at url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return head[url.path]
    }

    func setHeadHash(at url: URL, value: String) {
        lock.lock()
        head[url.path] = value
        lock.unlock()
    }
}
