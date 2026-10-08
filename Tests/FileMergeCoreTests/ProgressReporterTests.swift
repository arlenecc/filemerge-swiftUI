import Foundation
import Testing
@testable import FileMergeCore

@Suite("ProgressReporter 进度上报")
struct ProgressReporterTests {
    @Test("节流限制回调次数")
    func throttlingLimitsEmissions() {
        let collector = SnapshotCollector()
        let reporter = ProgressReporter(handler: collector.handler, throttleInterval: 0.2)

        for _ in 0..<500 {
            reporter.add(files: 1, bytes: 10)
        }
        reporter.emit(force: true)

        let count = collector.all.count
        // 500 次累加在 0.2s 节流下只应产生极少量回调 + 1 次强制收尾
        #expect(count <= 10, "节流应显著减少回调次数，实际 \(count) 次")
        #expect(collector.last?.files == 500)
        #expect(collector.last?.bytes == 5000)
    }

    @Test("最终快照携带总量信息")
    func finalSnapshotCarriesTotals() {
        let collector = SnapshotCollector()
        let reporter = ProgressReporter(handler: collector.handler, throttleInterval: 60, totalFiles: 100, totalBytes: 1000)

        reporter.add(files: 40, bytes: 400)
        reporter.emit(force: true)

        #expect(collector.last?.files == 40)
        #expect(collector.last?.bytes == 400)
        #expect(collector.last?.totalFiles == 100)
        #expect(collector.last?.totalBytes == 1000)
    }

    @Test("序列号单调递增")
    func sequenceNumbersMonotonicallyIncrease() {
        let collector = SnapshotCollector()
        let reporter = ProgressReporter(handler: collector.handler, throttleInterval: 0)

        for _ in 1...5 {
            reporter.add(files: 1, bytes: 0)
            reporter.emit(force: true)
        }
        let seqs = collector.all.map(\.seq)
        // 每轮 add + emit(force) 各发射一次，共 10 次；seq 必须严格单调递增
        #expect(seqs.count == 10)
        #expect(seqs.first == 1)
        let increasing = zip(seqs, seqs.dropFirst()).allSatisfy { $1 > $0 }
        #expect(increasing, "seq 应严格单调递增：\(seqs)")
    }
}
