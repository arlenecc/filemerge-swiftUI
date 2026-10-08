import Foundation
import Testing
@testable import FileMergeCore

@Suite("DedupEngine 全局排重")
struct DedupEngineTests {
    @Test("跨目录重复文件保留主目录版本")
    func duplicatesAcrossDirsKeepMainVersion() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "AAA")
        TestFS.write(secondary, "a.txt", "AAA")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].origin == .main)
        #expect(plan.entries[0].relativePath == "a.txt")
        #expect(plan.duplicatesCount == 1)
        #expect(plan.savedBytes == 3)
        #expect(plan.estimatedFileCount == 1)
        #expect(plan.estimatedTotalSize == 3)
    }

    @Test("两目录各自的唯一文件都进入计划")
    func uniqueFilesFromBothRootsPlanned() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "A")
        TestFS.write(secondary, "b.txt", "B")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))

        #expect(plan.entries.count == 2)
        #expect(plan.entries[0].origin == .main)
        #expect(plan.entries[0].relativePath == "a.txt")
        #expect(plan.entries[1].origin == .secondary)
        #expect(plan.entries[1].relativePath == "b.txt")
        #expect(plan.duplicatesCount == 0)
    }

    @Test("同相对路径不同内容：两个文件都保留")
    func sameRelativePathDifferentContentBothKept() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "X")
        TestFS.write(secondary, "a.txt", "Y")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))

        #expect(plan.entries.count == 2)
        #expect(plan.duplicatesCount == 0)
        let origins = Set(plan.entries.map(\.origin))
        #expect(origins == [.main, .secondary])
    }

    @Test("主目录内部重复保留相对路径排序靠前的文件")
    func duplicateWithinMainKeepsFirstByPath() async throws {
        let main = TestFS.makeTempDir()
        TestFS.write(main, "z.bin", "D")
        TestFS.write(main, "a.bin", "D")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(TestFS.makeTempDir()))

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].relativePath == "a.bin")
        #expect(plan.duplicatesCount == 1)
    }

    @Test("同哈希时主目录版本优先于副目录版本")
    func mainBeatsSecondaryForSameHash() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "m.txt", "S")
        TestFS.write(secondary, "s.txt", "S")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))

        #expect(plan.entries.count == 1)
        #expect(plan.entries[0].origin == .main)
        #expect(plan.entries[0].relativePath == "m.txt")
    }

    @Test("尺寸唯一的文件无需计算哈希")
    func uniqueSizeFilesSkipHashing() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "1")
        TestFS.write(main, "bb.txt", "22")
        TestFS.write(secondary, "ccc.txt", "333")

        let collector = SnapshotCollector()
        _ = try await DedupEngine.buildPlan(
            main: TestFS.scan(main), secondary: TestFS.scan(secondary),
            onProgress: collector.handler
        )

        #expect(collector.last?.files == 0, "全部尺寸唯一时不应有文件参与哈希")
        #expect(collector.last?.bytes == 0)
    }

    @Test("同尺寸不同内容全部保留")
    func sameSizeDifferentContentAllKept() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "111")
        TestFS.write(secondary, "b.txt", "222")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))

        #expect(plan.entries.count == 2)
        #expect(plan.duplicatesCount == 0)
    }

    @Test("计划条目包含正确的大小与来源排序（主目录在前）")
    func planOrderingMainFirst() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "m2.txt", "2")
        TestFS.write(main, "m1.txt", "1")
        TestFS.write(secondary, "s1.txt", "3")

        let plan = try await DedupEngine.buildPlan(main: TestFS.scan(main), secondary: TestFS.scan(secondary))

        let rels = plan.entries.map(\.relativePath)
        #expect(rels == ["m1.txt", "m2.txt", "s1.txt"])
        #expect(plan.entries.map(\.origin) == [.main, .main, .secondary])
    }

    @Test("头部哈希相同但全量不同：幸存者经全量哈希后全部保留")
    func sameHeadDifferentFullBothKept() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        // 两个文件头部（64KB+1 字节）完全一致，尾部不同 → 进入全量哈希阶段
        let head = TestFS.randomData(FileMergeConfig.headHashBytes + 1)
        let tailA = TestFS.randomData(64 * 1024, seed: 1)
        let tailB = TestFS.randomData(64 * 1024, seed: 2)
        TestFS.write(main, "a.bin", head + tailA)
        TestFS.write(secondary, "b.bin", head + tailB)

        let collector = SnapshotCollector()
        let plan = try await DedupEngine.buildPlan(
            main: TestFS.scan(main), secondary: TestFS.scan(secondary),
            onProgress: collector.handler
        )

        #expect(plan.entries.count == 2)
        #expect(plan.duplicatesCount == 0)
        // 两阶段共用同一进度流：预筛 2 个 + 全量 2 个 = 4，总量自动扩展
        #expect(collector.last?.files == 4)
        #expect(collector.last?.totalFiles == 4)
    }

    @Test("排重进度最终快照覆盖全部参与哈希的文件")
    func progressCoversHashedFiles() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "AAA")
        TestFS.write(secondary, "b.txt", "AAA")     // 与 a.txt 重复
        TestFS.write(secondary, "c.txt", "AAA")     // 同内容第三份

        let collector = SnapshotCollector()
        let plan = try await DedupEngine.buildPlan(
            main: TestFS.scan(main), secondary: TestFS.scan(secondary),
            onProgress: collector.handler
        )

        #expect(plan.entries.count == 1)
        #expect(collector.last?.files == 6, "3 个文件经预筛+全量两阶段，工作量计 6 次")
        #expect(collector.last?.totalFiles == 6)
        #expect(collector.last?.bytes == 18)
        #expect(collector.last?.totalBytes == 18)
    }
}
