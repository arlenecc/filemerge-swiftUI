import Testing
@testable import FileMergeCore

@Suite("冒烟测试")
struct SmokeTests {
    @Test("Swift Testing 运行器可用")
    func runnerWorks() {
        #expect(1 + 1 == 2)
    }
}
