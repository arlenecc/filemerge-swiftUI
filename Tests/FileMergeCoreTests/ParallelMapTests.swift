import Foundation
import Testing
@testable import FileMergeCore

/// 并发计数器：锁操作封装在同步方法内
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    func enter() {
        lock.lock()
        current += 1
        peak = max(peak, current)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var observedPeak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

@Suite("ParallelMap 有界并发")
struct ParallelMapTests {
    @Test("任务乱序完成时结果仍保持输入顺序")
    func preservesOrderOnOutOfOrderCompletion() async throws {
        let elements = Array(0..<64)
        // 索引越小延迟越长 → 完成顺序与输入顺序大致相反
        let output = try await ParallelMap.run(elements, concurrency: 8) { value -> Int in
            try await Task.sleep(for: .milliseconds(1 + (elements.count - value)))
            return value
        }
        #expect(output == elements)
    }

    @Test("空输入返回空输出")
    func emptyInputReturnsEmpty() async throws {
        let output: [Int] = try await ParallelMap.run([Int](), concurrency: 4) { $0 }
        #expect(output.isEmpty)
    }

    @Test("并发度不超过指定上限")
    func respectsConcurrencyLimit() async throws {
        let probe = ConcurrencyProbe()

        let output = try await ParallelMap.run(Array(0..<200), concurrency: 3) { value -> Int in
            probe.enter()
            try await Task.sleep(for: .milliseconds(1))
            probe.leave()
            return value
        }

        #expect(output.count == 200)
        let peak = probe.observedPeak
        #expect(peak <= 3, "峰值并发 \(peak) 应不超过 3")
        #expect(peak > 1, "应实际并发执行（峰值 \(peak)）")
    }

    @Test("外部取消后整体抛出取消错误")
    func cancellationPropagates() async throws {
        let task = Task {
            _ = try await ParallelMap.run(Array(0..<1000), concurrency: 4) { _ -> Int in
                try await Task.sleep(for: .milliseconds(10))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(20))
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

    @Test("transform 抛出错误时整体失败")
    func errorPropagates() async throws {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await ParallelMap.run(Array(0..<10), concurrency: 2) { value -> Int in
                if value == 3 { throw Boom() }
                return value
            }
        }
    }
}
