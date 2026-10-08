import Foundation
import Testing
@testable import FileMergeCore
@testable import FileMergeUI

@MainActor
@Suite("AppViewModel 界面状态机")
struct AppViewModelTests {
    /// 构造：主目录 2 个文件，副目录 1 个唯一 + 1 个重复，最终目录独立
    private func makeFixture() -> (main: URL, secondary: URL, destination: URL) {
        let main = UITestFS.makeTempDir()
        let secondary = UITestFS.makeTempDir()
        let destination = UITestFS.makeTempDir()
        UITestFS.write(main, "a.txt", "AAA")
        UITestFS.write(main, "sub/b.txt", "BBB")
        UITestFS.write(secondary, "c.txt", "CCC")
        UITestFS.write(secondary, "dup.txt", "AAA")
        return (main, secondary, destination)
    }

    @Test("分析完成后填充统计与预估，允许开始合并")
    func analysisPopulatesStatsAndEstimate() async {
        let fixture = makeFixture()
        let vm = AppViewModel()
        vm.setMainDir(fixture.main)
        vm.setSecondaryDir(fixture.secondary)
        vm.setDestinationDir(fixture.destination)
        #expect(vm.canStartAnalysis)

        await vm.startAnalysis()

        #expect(vm.phase == .analyzed)
        #expect(vm.mainStats?.fileCount == 2)
        #expect(vm.mainStats?.totalSize == 6)
        #expect(vm.secondaryStats?.fileCount == 2)
        #expect(vm.secondaryStats?.totalSize == 6)
        #expect(vm.estimate?.fileCount == 3)
        #expect(vm.estimate?.totalSize == 9)
        #expect(vm.estimate?.duplicates == 1)
        #expect(vm.estimate?.savedBytes == 3)
        #expect(vm.canStartMerge)
        #expect(!vm.busy)
    }

    @Test("合并后最终目录内容正确且记录完成日志")
    func mergeProducesFinalDirectoryAndLogs() async {
        let fixture = makeFixture()
        let vm = AppViewModel()
        vm.setMainDir(fixture.main)
        vm.setSecondaryDir(fixture.secondary)
        vm.setDestinationDir(fixture.destination)

        await vm.startAnalysis()
        await vm.startMerge()

        #expect(vm.phase == .merged)
        #expect(UITestFS.read(fixture.destination.appendingPathComponent("a.txt")) == "AAA")
        #expect(UITestFS.read(fixture.destination.appendingPathComponent("sub/b.txt")) == "BBB")
        #expect(UITestFS.read(fixture.destination.appendingPathComponent("c.txt")) == "CCC")
        #expect(!UITestFS.exists(fixture.destination.appendingPathComponent("dup.txt")))
        #expect(vm.logEntries.contains { $0.text.contains("合并完成") })
        #expect(vm.progressValue == 1.0)
    }

    @Test("最终目录位于主目录内部时报校验错误")
    func validationFailureShowsError() async {
        let fixture = makeFixture()
        let vm = AppViewModel()
        vm.setMainDir(fixture.main)
        vm.setSecondaryDir(fixture.secondary)
        vm.setDestinationDir(fixture.main.appendingPathComponent("out", isDirectory: true))

        await vm.startAnalysis()

        guard case .failed = vm.phase else {
            Issue.record("预期 phase == .failed，实际：\(vm.phase)")
            return
        }
        #expect(!vm.canStartMerge)
        #expect(vm.mainStats == nil)
    }

    @Test("未完成分析时直接合并报错")
    func mergeWithoutAnalysisFails() async {
        let fixture = makeFixture()
        let vm = AppViewModel()
        vm.setMainDir(fixture.main)
        vm.setSecondaryDir(fixture.secondary)
        vm.setDestinationDir(fixture.destination)

        await vm.startMerge()

        guard case .failed = vm.phase else {
            Issue.record("预期 phase == .failed，实际：\(vm.phase)")
            return
        }
        #expect(!UITestFS.exists(fixture.destination.appendingPathComponent("a.txt")))
    }

    @Test("缺少目录时无法分析且报错")
    func analysisWithoutAllDirsFails() async {
        let vm = AppViewModel()
        await vm.startAnalysis()
        guard case .failed = vm.phase else {
            Issue.record("预期 phase == .failed")
            return
        }
    }

    @Test("更换主目录后旧分析结果失效")
    func changingMainDirInvalidatesAnalysis() async {
        let fixture = makeFixture()
        let vm = AppViewModel()
        vm.setMainDir(fixture.main)
        vm.setSecondaryDir(fixture.secondary)
        vm.setDestinationDir(fixture.destination)
        await vm.startAnalysis()
        #expect(vm.canStartMerge)

        vm.setMainDir(UITestFS.makeTempDir())

        #expect(vm.mainStats == nil)
        #expect(vm.estimate == nil)
        #expect(!vm.canStartMerge)
        #expect(vm.phase == .idle)
    }

    @Test("仅更换最终目录不影响已有分析结果")
    func changingDestinationKeepsAnalysis() async {
        let fixture = makeFixture()
        let vm = AppViewModel()
        vm.setMainDir(fixture.main)
        vm.setSecondaryDir(fixture.secondary)
        vm.setDestinationDir(fixture.destination)
        await vm.startAnalysis()
        #expect(vm.canStartMerge)

        vm.setDestinationDir(UITestFS.makeTempDir())

        #expect(vm.estimate != nil)
        #expect(vm.canStartMerge)
    }
}
