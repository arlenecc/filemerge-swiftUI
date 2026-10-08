import Foundation
import Testing
@testable import FileMergeCore

@Suite("MergeEngine 合并写入")
struct MergeEngineTests {
    @Test("按主目录结构写入，副目录唯一文件落到其相对路径")
    func mergeWritesMainStructureAndSecondaryUniques() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "A-main")
        TestFS.write(main, "sub/b.txt", "B-main")
        TestFS.write(secondary, "c.txt", "C-sec")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        let result = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(result.errors.isEmpty)
        #expect(result.copiedFiles == 3)
        #expect(TestFS.read(destination.appendingPathComponent("a.txt")) == "A-main")
        #expect(TestFS.read(destination.appendingPathComponent("sub/b.txt")) == "B-main")
        #expect(TestFS.read(destination.appendingPathComponent("c.txt")) == "C-sec")
    }

    @Test("重复内容只写入一份")
    func mergeSkipsDuplicates() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "same.txt", "SAME")
        TestFS.write(secondary, "also-same.txt", "SAME")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        _ = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(TestFS.exists(destination.appendingPathComponent("same.txt")))
        #expect(!TestFS.exists(destination.appendingPathComponent("also-same.txt")))
    }

    @Test("主副目录同相对路径冲突时副目录文件重命名")
    func mergeRenamesCollision() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "X")
        TestFS.write(secondary, "a.txt", "Y")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        let result = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(result.renamedFiles == 1)
        #expect(result.errors.isEmpty)
        #expect(TestFS.read(destination.appendingPathComponent("a.txt")) == "X")
        #expect(TestFS.read(destination.appendingPathComponent("a (1).txt")) == "Y")
    }

    @Test("重命名不覆盖已存在的文件（连续递增）")
    func renameSkipsOccupiedVariants() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "X")
        TestFS.write(secondary, "a.txt", "Y")
        // 目标目录已存在 "a (1).txt"（内容不同）
        TestFS.write(destination, "a (1).txt", "pre-existing")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        let result = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(result.renamedFiles == 1)
        #expect(TestFS.read(destination.appendingPathComponent("a.txt")) == "X")
        #expect(TestFS.read(destination.appendingPathComponent("a (1).txt")) == "pre-existing")
        #expect(TestFS.read(destination.appendingPathComponent("a (2).txt")) == "Y")
    }

    @Test("重复合并幂等：已存在且内容一致的文件被跳过")
    func mergeIsIdempotent() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "A")
        TestFS.write(main, "sub/b.txt", "B")
        TestFS.write(secondary, "c.txt", "C")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        let first = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(first.copiedFiles == 3)

        let second = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(second.copiedFiles == 0)
        #expect(second.skippedFiles == 3)
        #expect(second.errors.isEmpty)
        #expect(TestFS.read(destination.appendingPathComponent("a.txt")) == "A")
        #expect(TestFS.read(destination.appendingPathComponent("sub/b.txt")) == "B")
        #expect(TestFS.read(destination.appendingPathComponent("c.txt")) == "C")
    }

    @Test("重复合并幂等：已改名的副目录条目不再产生新副本")
    func renamedEntryIsIdempotentOnRerun() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "X")
        TestFS.write(secondary, "a.txt", "Y")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        let first = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(first.renamedFiles == 1)

        let second = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(second.copiedFiles == 0)
        #expect(second.renamedFiles == 0)
        #expect(second.skippedFiles == 2)
        #expect(second.errors.isEmpty)
        #expect(!TestFS.exists(destination.appendingPathComponent("a (2).txt")))
        #expect(TestFS.read(destination.appendingPathComponent("a (1).txt")) == "Y")
    }

    @Test("覆盖目标为目录时拒绝并记录错误，不删除目录内容")
    func overwriteRefusesDirectoryTarget() async throws {
        let main = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "new")
        // 目标目录中 a.txt 位置是一个目录
        TestFS.write(destination, "a.txt/inner.txt", "keep")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(TestFS.makeTempDir()))
        let result = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(result.errors.count == 1)
        #expect(result.copiedFiles == 0)
        #expect(TestFS.exists(destination.appendingPathComponent("a.txt/inner.txt")))
    }

    @Test("主目录条目遇目标已存在但内容不同时覆盖")
    func mergeOverwritesChangedMainDestination() async throws {
        let main = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "new-content")
        TestFS.write(destination, "a.txt", "stale-content")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(TestFS.makeTempDir()))
        let result = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(result.errors.isEmpty)
        #expect(TestFS.read(destination.appendingPathComponent("a.txt")) == "new-content")
    }

    @Test("合并进度最终快照等于计划总量")
    func mergeProgressFinalTotals() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "12345")
        TestFS.write(secondary, "b.txt", "1234567890")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))
        let collector = SnapshotCollector()
        _ = try await MergeEngine(plan: plan, destination: destination).merge(onProgress: collector.handler)

        #expect(collector.last?.files == 2)
        #expect(collector.last?.bytes == 15)
        #expect(collector.last?.totalFiles == 2)
        #expect(collector.last?.totalBytes == 15)
    }

    @Test("源文件缺失时记录错误而不中断其他文件的复制")
    func mergeCollectsErrorForMissingSource() async throws {
        let main = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        let ghost = TestFS.write(main, "ghost.txt", "G")
        TestFS.write(main, "ok.txt", "OK")
        try FileManager.default.removeItem(at: ghost)

        let scan = try await TestFS.scan(main)
        // 手工构造计划：正常条目 + 一个指向已删除文件的条目
        var entries = scan.files.map {
            PlanEntry(origin: .main, sourceURL: $0.url, relativePath: $0.relativePath, size: $0.size, hash: nil)
        }
        entries.append(PlanEntry(
            origin: .main,
            sourceURL: main.appendingPathComponent("ghost.txt"),
            relativePath: "ghost.txt",
            size: 1,
            hash: nil
        ))
        let plan = MergePlan(entries: entries, duplicatesCount: 0, savedBytes: 0)

        let result = try await MergeEngine(plan: plan, destination: destination).merge()

        #expect(result.errors.count == 1)
        #expect(result.copiedFiles == 1)
        #expect(TestFS.read(destination.appendingPathComponent("ok.txt")) == "OK")
    }
}
