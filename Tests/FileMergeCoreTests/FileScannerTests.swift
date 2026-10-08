import Foundation
import Testing
@testable import FileMergeCore

@Suite("FileScanner 目录扫描")
struct FileScannerTests {
    @Test("递归扫描统计嵌套文件数量与大小")
    func scanCountsNestedFilesAndSizes() async throws {
        let main = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "0123456789")          // 10 字节
        TestFS.write(main, "sub/b.txt", String(repeating: "b", count: 20)) // 20 字节
        TestFS.write(main, "sub/deep/c.txt", String(repeating: "c", count: 30)) // 30 字节
        try FileManager.default.createDirectory(at: main.appendingPathComponent("empty_dir"), withIntermediateDirectories: true)

        let scan = try await TestFS.scan(main, concurrency: 4)

        #expect(scan.stats.fileCount == 3)
        #expect(scan.stats.totalSize == 60)
        #expect(scan.root == main)
        // 文件按 relativePath 排序
        #expect(scan.files.map(\.relativePath) == ["a.txt", "sub/b.txt", "sub/deep/c.txt"])
        #expect(scan.files[0].size == 10)
        #expect(scan.files[1].size == 20)
        #expect(scan.files[2].size == 30)
    }

    @Test("跳过符号链接（文件链接与目录链接）")
    func scanSkipsSymlinks() async throws {
        let main = TestFS.makeTempDir()
        let target = TestFS.makeTempDir(named: "symlink-target-\(UUID().uuidString)")
        TestFS.write(target, "outside.txt", "outside")
        TestFS.write(main, "real.txt", "real")
        TestFS.makeSymlink(at: main.appendingPathComponent("link_file.txt"), to: target.appendingPathComponent("outside.txt"))
        TestFS.makeSymlink(at: main.appendingPathComponent("link_dir"), to: target)

        let scan = try await TestFS.scan(main, concurrency: 2)

        #expect(scan.files.map(\.relativePath) == ["real.txt"])
    }

    @Test("扫描过程上报进度且最终快照含总数")
    func scanReportsProgressWithFinalTotals() async throws {
        let main = TestFS.makeTempDir()
        for i in 0..<50 {
            TestFS.write(main, "f\(i % 5)/file\(i).txt", String(repeating: "x", count: i + 1))
        }
        let collector = SnapshotCollector()
        let scan = try await FileScanner(root: main, concurrency: 4).scan(onProgress: collector.handler)

        #expect(scan.stats.fileCount == 50)
        #expect(!collector.all.isEmpty)
        #expect(collector.last?.files == 50)
        #expect(collector.last?.bytes == UInt64((1...50).reduce(0, +)))
    }

    @Test("结果按相对路径排序")
    func scanSortedByRelativePath() async throws {
        let main = TestFS.makeTempDir()
        TestFS.write(main, "z.txt", "z")
        TestFS.write(main, "a.txt", "a")
        TestFS.write(main, "m/n.txt", "n")
        TestFS.write(main, "m/a.txt", "a2")
        let scan = try await TestFS.scan(main)
        #expect(scan.files.map(\.relativePath) == ["a.txt", "m/a.txt", "m/n.txt", "z.txt"])
    }

    @Test("扫描可被取消")
    func scanCancellationThrows() async throws {
        let main = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "a")
        let scanner = FileScanner(root: main, concurrency: 2)
        let task = Task { try await scanner.scan() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("预期抛出 CancellationError")
        } catch is CancellationError {
            // 符合预期
        } catch {
            Issue.record("预期 CancellationError，实际：\(error)")
        }
    }

    @Test("根不是目录时抛出 ScanError")
    func scanNonDirectoryRootThrows() async {
        let dir = TestFS.makeTempDir()
        let file = TestFS.write(dir, "plain.txt", "x")
        do {
            _ = try await FileScanner(root: file).scan()
            Issue.record("预期抛出错误")
        } catch let error as ScanError {
            #expect(error == .rootNotADirectory)
        } catch {
            Issue.record("预期 ScanError，实际：\(error)")
        }
    }

    @Test("根目录不可读时抛出 rootUnreadable 而不是静默返回空结果")
    func scanUnreadableRootThrows() async throws {
        let main = TestFS.makeTempDir()
        TestFS.write(main, "a.txt", "a")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: main.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: main.path) }

        do {
            _ = try await FileScanner(root: main).scan()
            Issue.record("预期抛出 ScanError.rootUnreadable")
        } catch let error as ScanError {
            #expect(error == .rootUnreadable)
        } catch {
            Issue.record("预期 ScanError，实际：\(error)")
        }
    }

    @Test("无法读取的目录记录警告且不中断扫描")
    func scanRecordsWarningForUnreadableDirectory() async throws {
        let main = TestFS.makeTempDir()
        TestFS.write(main, "ok.txt", "ok")
        let locked = main.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        TestFS.write(main, "locked/hidden.txt", "hidden")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let scan = try await TestFS.scan(main, concurrency: 2)
        #expect(scan.files.contains { $0.relativePath == "ok.txt" })
        #expect(!scan.files.contains { $0.relativePath == "locked/hidden.txt" })
        #expect(!scan.warnings.isEmpty, "无法读取的目录应记录警告")
    }
}
