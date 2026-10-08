import Darwin
import Foundation

/// 目录配置校验错误
public enum MergeValidationError: Error, Equatable, LocalizedError {
    /// 主目录无效（不存在或不是目录）
    case mainDirectoryInvalid
    /// 副目录无效（不存在或不是目录）
    case secondaryDirectoryInvalid
    /// 最终目录位于源目录内部（或与之相同），会导致合并自我覆盖
    case destinationInsideSource
    /// 源目录位于最终目录内部（或与之相同），同样不安全
    case sourceInsideDestination

    public var errorDescription: String? {
        switch self {
        case .mainDirectoryInvalid: "主目录无效：目录不存在或不可访问"
        case .secondaryDirectoryInvalid: "副目录无效：目录不存在或不可访问"
        case .destinationInsideSource: "最终目录不能位于主目录或副目录内部（也不能与它们相同）"
        case .sourceInsideDestination: "主目录或副目录不能位于最终目录内部（也不能与它相同）"
        }
    }
}

/// 合并前对三个目录关系的安全校验
public enum MergeValidator {
    public static func validate(main: URL, secondary: URL, destination: URL) throws {
        try validateExists(main, error: .mainDirectoryInvalid)
        try validateExists(secondary, error: .secondaryDirectoryInvalid)

        // 比较前先解析符号链接并折叠大小写：macOS 默认文件系统大小写不敏感，
        // 且目录可能经符号链接/别名以不同书写形式访问，否则同一目录会被误判为安全
        let d = normalized(destination)
        let m = normalized(main)
        let s = normalized(secondary)

        if isSameOrDescendant(d, of: m) || isSameOrDescendant(d, of: s) {
            throw MergeValidationError.destinationInsideSource
        }
        if isSameOrDescendant(m, of: d) || isSameOrDescendant(s, of: d) {
            throw MergeValidationError.sourceInsideDestination
        }
    }

    static func validateExists(_ url: URL, error: MergeValidationError) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw error
        }
    }

    /// 解析符号链接、展开 .. 并折叠大小写后的路径（用于目录关系比较）。
    /// realpath 只能解析已存在的路径：对最深存在的祖先做 realpath，再原样拼接不存在的尾部。
    static func normalized(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        var dropped: [String] = []
        var probe = path
        while realpath(probe, nil) == nil {
            guard probe != "/" else { break }
            dropped.insert((probe as NSString).lastPathComponent, at: 0)
            probe = (probe as NSString).deletingLastPathComponent
            if probe.isEmpty { probe = "/" }
        }
        if let resolved = realpath(probe, nil) {
            path = String(cString: resolved)
        }
        let full = dropped.isEmpty ? path : path + "/" + dropped.joined(separator: "/")
        return full.lowercased()
    }

    /// path 与 ancestor 相同，或位于 ancestor 内部
    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor == "/" ? "/" : (ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
        return path.hasPrefix(prefix)
    }
}
