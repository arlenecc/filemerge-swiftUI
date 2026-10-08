import Foundation
import Testing
@testable import FileMergeCore

@Suite("端到端：扫描 → 排重 → 合并")
struct EndToEndTests {
    @Test("全流程结果与预估一致，最终目录内容正确")
    func fullPipelineMatchesEstimate() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()

        // 主目录：a.txt 与 dup/x.txt 内容重复；sub/c.txt 与副目录 sub/c.txt 重复
        TestFS.write(main, "a.txt", "alpha")
        TestFS.write(main, "sub/b.txt", "bravo")
        TestFS.write(main, "sub/c.txt", "charlie")
        TestFS.write(main, "dup/x.txt", "alpha")
        // 副目录：a.txt（跨目录重复）、sub/c.txt（跨目录重复）、d.txt、e.txt
        TestFS.write(secondary, "a.txt", "alpha")
        TestFS.write(secondary, "sub/c.txt", "charlie")
        TestFS.write(secondary, "sub2/d.txt", "delta")
        TestFS.write(secondary, "e.txt", "echo")

        let mainScan = try await TestFS.scan(main)
        let secondaryScan = try await TestFS.scan(secondary)
        #expect(mainScan.stats.fileCount == 4)
        #expect(secondaryScan.stats.fileCount == 4)

        let plan = try await DedupEngine.buildPlan(main: mainScan, secondary: secondaryScan)

        // 全局唯一内容：alpha, bravo, charlie, delta, echo → 5 个
        #expect(plan.estimatedFileCount == 5)
        #expect(plan.duplicatesCount == 3)
        // 重复节省：dup/x.txt(5) + secondary/a.txt(5) + secondary/sub/c.txt(7) = 17
        #expect(plan.savedBytes == 17)
        // 唯一内容总字节：5+5+7+5+4 = 26
        #expect(plan.estimatedTotalSize == 26)

        let result = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(result.errors.isEmpty)
        #expect(result.copiedFiles == 5)
        #expect(result.renamedFiles == 0)

        // 实际写入与预估一致
        let finalScan = try await TestFS.scan(destination)
        #expect(finalScan.stats.fileCount == plan.estimatedFileCount)
        #expect(finalScan.stats.totalSize == plan.estimatedTotalSize)

        // 内容正确：主目录版本优先
        #expect(TestFS.read(destination.appendingPathComponent("a.txt")) == "alpha")
        #expect(TestFS.read(destination.appendingPathComponent("sub/b.txt")) == "bravo")
        #expect(TestFS.read(destination.appendingPathComponent("sub/c.txt")) == "charlie")
        #expect(TestFS.read(destination.appendingPathComponent("sub2/d.txt")) == "delta")
        #expect(TestFS.read(destination.appendingPathComponent("e.txt")) == "echo")
        // 重复文件不应出现
        #expect(!TestFS.exists(destination.appendingPathComponent("dup/x.txt")))
    }

    @Test("副目录与主目录同路径不同内容：合并后重命名共存")
    func e2eCollisionRename() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()

        TestFS.write(main, "docs/readme.txt", "main-readme")
        TestFS.write(secondary, "docs/readme.txt", "secondary-readme")
        TestFS.write(secondary, "docs/extra.txt", "extra")

        let mainScan = try await TestFS.scan(main)
        let secondaryScan = try await TestFS.scan(secondary)
        let plan = try await DedupEngine.buildPlan(main: mainScan, secondary: secondaryScan)
        #expect(plan.estimatedFileCount == 3)

        let result = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(result.errors.isEmpty)
        #expect(result.renamedFiles == 1)

        #expect(TestFS.read(destination.appendingPathComponent("docs/readme.txt")) == "main-readme")
        #expect(TestFS.read(destination.appendingPathComponent("docs/readme (1).txt")) == "secondary-readme")
        #expect(TestFS.read(destination.appendingPathComponent("docs/extra.txt")) == "extra")
    }

    @Test("副目录嵌套于主目录内（路径重叠）时排重正确")
    func e2eOverlappingRoots() async throws {
        let root = TestFS.makeTempDir()
        let main = root
        let secondary = root.appendingPathComponent("nested", isDirectory: true)
        let destination = TestFS.makeTempDir()

        TestFS.write(main, "top.txt", "TOP")
        TestFS.write(secondary, "inner.txt", "INNER")

        let mainScan = try await TestFS.scan(main)           // 扫到 top.txt + nested/inner.txt
        let secondaryScan = try await TestFS.scan(secondary) // 只扫到 inner.txt

        let plan = try await DedupEngine.buildPlan(main: mainScan, secondary: secondaryScan)
        // 唯一内容：TOP、INNER（inner 在两次扫描中哈希相同 → 副目录版本被去重）
        #expect(plan.estimatedFileCount == 2)

        let result = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(result.errors.isEmpty)
        #expect(result.copiedFiles == 2)
        #expect(TestFS.read(destination.appendingPathComponent("top.txt")) == "TOP")
        #expect(TestFS.read(destination.appendingPathComponent("nested/inner.txt")) == "INNER")
    }

    @Test("较大文件（2MB）重复内容跨目录去重")
    func e2eLargeFileDedup() async throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()

        let data = TestFS.randomData(2 * 1024 * 1024)
        TestFS.write(main, "big1.bin", data)
        TestFS.write(secondary, "big2.bin", data)
        TestFS.write(secondary, "small.txt", "tiny")

        let mainScan = try await TestFS.scan(main)
        let secondaryScan = try await TestFS.scan(secondary)
        let plan = try await DedupEngine.buildPlan(main: mainScan, secondary: secondaryScan)

        #expect(plan.estimatedFileCount == 2)
        #expect(plan.duplicatesCount == 1)
        #expect(plan.savedBytes == 2 * 1024 * 1024)

        let result = try await MergeEngine(plan: plan, destination: destination).merge()
        #expect(result.errors.isEmpty)
        #expect(TestFS.exists(destination.appendingPathComponent("big1.bin")))
        #expect(TestFS.exists(destination.appendingPathComponent("small.txt")))
        #expect(!TestFS.exists(destination.appendingPathComponent("big2.bin")))
        // 内容一致性
        let copied = try Data(contentsOf: destination.appendingPathComponent("big1.bin"))
        #expect(copied == data)
    }
}
