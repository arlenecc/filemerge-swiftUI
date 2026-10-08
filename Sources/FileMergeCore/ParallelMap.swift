import Foundation

/// 有界并发的批量异步转换：滑动窗口调度，始终维持至多 concurrency 个任务在飞，
/// 一个任务完成立即补位下一个，避免分块串行的队头阻塞（大文件不拖慢其他任务）。
/// 结果顺序与输入顺序一致。
public enum ParallelMap {
    public static func run<Element: Sendable, T: Sendable>(
        _ elements: [Element],
        concurrency: Int,
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        let width = max(1, concurrency)
        if elements.isEmpty { return [] }

        var results = [T?](repeating: nil, count: elements.count)
        var iterator = elements.enumerated().makeIterator()

        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var inFlight = 0

            // 先填满窗口
            while inFlight < width, let (index, element) = iterator.next() {
                group.addTask { (index, try await transform(element)) }
                inFlight += 1
            }

            // 每完成一个补位一个；group.next() 返回最先完成的任务
            while inFlight > 0 {
                let (index, value) = try await group.next()!
                results[index] = value
                inFlight -= 1
                if let (nextIndex, nextElement) = iterator.next() {
                    group.addTask { (nextIndex, try await transform(nextElement)) }
                    inFlight += 1
                }
            }
        }

        return results.map { $0! }
    }
}
