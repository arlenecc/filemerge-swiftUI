import Foundation
import Testing
@testable import FileMergeCore

@Suite("FileHasher 文件哈希")
struct FileHasherTests {
    @Test("哈希结果符合已知 SHA256 值")
    func hashFileMatchesKnownSHA256() async throws {
        let dir = TestFS.makeTempDir()
        let file = TestFS.write(dir, "hello.txt", "hello")
        let hash = try await FileHasher.hashFile(at: file)
        // sha256("hello") 的公认值
        #expect(hash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test("相同内容哈希一致，不同内容哈希不同")
    func identicalContentSameHashDifferentContentDifferentHash() async throws {
        let dir = TestFS.makeTempDir()
        let a = TestFS.write(dir, "a.txt", "same content")
        let b = TestFS.write(dir, "b.txt", "same content")
        let c = TestFS.write(dir, "c.txt", "different content")
        let ha = try await FileHasher.hashFile(at: a)
        let hb = try await FileHasher.hashFile(at: b)
        let hc = try await FileHasher.hashFile(at: c)
        #expect(ha == hb)
        #expect(ha != hc)
    }

    @Test("分块读取哈希与整体读取哈希一致（5MB）")
    func chunkedHashMatchesWholeReadHash() async throws {
        let dir = TestFS.makeTempDir()
        let data = TestFS.randomData(5 * 1024 * 1024)
        let file = TestFS.write(dir, "big.bin", data)
        let chunked = try await FileHasher.hashFile(at: file, chunkSize: 64 * 1024)
        let whole = FileHasher.sha256Hex(of: data)
        #expect(chunked == whole)
    }

    @Test("头部哈希等于前 N 字节的哈希")
    func headHashEqualsHashOfHeadBytes() async throws {
        let dir = TestFS.makeTempDir()
        let data = TestFS.randomData(1024 * 1024)
        let file = TestFS.write(dir, "head.bin", data)
        let head = try await FileHasher.headHash(at: file, headBytes: 4096)
        let expected = FileHasher.sha256Hex(of: data.prefix(4096))
        #expect(head == expected)
    }

    @Test("空文件哈希稳定且符合公认值")
    func hashEmptyFileIsStable() async throws {
        let dir = TestFS.makeTempDir()
        let a = TestFS.write(dir, "e1.txt", "")
        let b = TestFS.write(dir, "e2.txt", "")
        let ha = try await FileHasher.hashFile(at: a)
        let hb = try await FileHasher.hashFile(at: b)
        #expect(ha == hb)
        // sha256("") 的公认值
        #expect(ha == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("哈希过程可被取消")
    func hashCancellationThrows() async throws {
        let dir = TestFS.makeTempDir()
        let file = TestFS.write(dir, "cancel.bin", TestFS.randomData(1024 * 1024))
        let task = Task { try await FileHasher.hashFile(at: file, chunkSize: 1024) }
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

    @Test("文件不存在时抛出错误")
    func hashMissingFileThrows() async throws {
        let dir = TestFS.makeTempDir()
        do {
            _ = try await FileHasher.hashFile(at: dir.appendingPathComponent("nope.txt"))
            Issue.record("预期抛出错误")
        } catch {
            #expect(!(error is CancellationError))
        }
    }
}
