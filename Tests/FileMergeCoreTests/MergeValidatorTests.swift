import Foundation
import Testing
@testable import FileMergeCore

@Suite("MergeValidator 目录安全校验")
struct MergeValidatorTests {
    @Test("合法配置通过校验")
    func validConfigurationPasses() throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        try MergeValidator.validate(main: main, secondary: secondary, destination: destination)
    }

    @Test("最终目录在主目录内部被拒绝")
    func destinationInsideMainRejected() throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = main.appendingPathComponent("merge_out", isDirectory: true)
        assertThrowsDestinationInsideSource {
            try MergeValidator.validate(main: main, secondary: secondary, destination: destination)
        }
    }

    @Test("最终目录在副目录内部被拒绝")
    func destinationInsideSecondaryRejected() throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let destination = secondary.appendingPathComponent("out", isDirectory: true)
        assertThrowsDestinationInsideSource {
            try MergeValidator.validate(main: main, secondary: secondary, destination: destination)
        }
    }

    @Test("最终目录等于主目录被拒绝")
    func destinationEqualToMainRejected() throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        assertThrowsDestinationInsideSource {
            try MergeValidator.validate(main: main, secondary: secondary, destination: main)
        }
    }

    @Test("主目录在最终目录内部被拒绝")
    func sourceInsideDestinationRejected() throws {
        let root = TestFS.makeTempDir()
        let main = root.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        let secondary = TestFS.makeTempDir()
        assertThrowsSourceInsideDestination {
            try MergeValidator.validate(main: main, secondary: secondary, destination: root)
        }
    }

    @Test("经符号链接别名指向主目录内部的最终目录被拒绝")
    func symlinkAliasedDestinationRejected() throws {
        let main = TestFS.makeTempDir()
        let secondary = TestFS.makeTempDir()
        let alias = main.deletingLastPathComponent()
            .appendingPathComponent("alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: main)
        defer { try? FileManager.default.removeItem(at: alias) }

        // 目标经符号链接别名指向主目录内部：路径解析后必须被识别
        let destination = alias.appendingPathComponent("out", isDirectory: true)
        do {
            try MergeValidator.validate(main: main, secondary: secondary, destination: destination)
            Issue.record("预期 MergeValidationError.destinationInsideSource")
        } catch let error as MergeValidationError {
            #expect(error == .destinationInsideSource)
        } catch {
            Issue.record("预期 MergeValidationError，实际：\(error)")
        }
    }

    @Test("主目录不存在被拒绝")
    func missingMainRejected() throws {
        let secondary = TestFS.makeTempDir()
        let destination = TestFS.makeTempDir()
        #expect(throws: MergeValidationError.self) {
            try MergeValidator.validate(
                main: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                secondary: secondary,
                destination: destination
            )
        }
    }

    private func assertThrowsDestinationInsideSource(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("预期 MergeValidationError.destinationInsideSource")
        } catch let error as MergeValidationError {
            #expect(error == .destinationInsideSource)
        } catch {
            Issue.record("预期 MergeValidationError，实际：\(error)")
        }
    }

    private func assertThrowsSourceInsideDestination(_ body: () throws -> Void) {
        do {
            try body()
            Issue.record("预期 MergeValidationError.sourceInsideDestination")
        } catch let error as MergeValidationError {
            #expect(error == .sourceInsideDestination)
        } catch {
            Issue.record("预期 MergeValidationError，实际：\(error)")
        }
    }
}
