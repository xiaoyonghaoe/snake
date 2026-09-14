import CryptoKit
import Darwin
import Foundation
import SnakeCoreBindings

enum TransferVerification: Equatable, Sendable {
    case pending, checking(String), passed(String), unavailable(String), failed(String), notApplicable(String)

    var label: String {
        switch self {
        case .pending: L10n.text("等待校验")
        case .checking(let algorithm): L10n.format("正在校验 · %@", algorithm)
        case .passed(let algorithm): L10n.format("校验通过 · %@", algorithm)
        case .unavailable(let reason): L10n.format("未校验：%@", reason)
        case .failed(let reason): L10n.format("校验失败：%@", reason)
        case .notApplicable(let reason): reason
        }
    }
    var isWarning: Bool { if case .unavailable = self { true } else { false } }
    var isChecking: Bool { if case .checking = self { true } else { false } }
}

enum TransferIntegrity {
    static func bestEffortCapability(_ probe: () throws -> CoreChecksumCapability) -> CoreChecksumCapability {
        do { return try probe() }
        catch {
            // Unknown exec capability also selects the pure-SFTP upload path;
            // a broken login shell must not prevent an otherwise valid upload.
            return CoreChecksumCapability(tool: "sftp-only", algorithm: "", reason: L10n.text("校验能力探测失败，已跳过校验"))
        }
    }

    static func optionalDigest(_ compute: () throws -> String) throws -> String? {
        do { return try compute() }
        catch CoreError.TransferCancelled { throw CoreError.TransferCancelled }
        catch { return nil }
    }

    static func bestEffortVerification(algorithm: String, local: () throws -> String, remote: () throws -> String) throws -> TransferVerification {
        guard let localHash = try optionalDigest(local), let remoteHash = try optionalDigest(remote) else {
            return .unavailable(L10n.format("%@ 校验无法完成，已跳过", algorithm))
        }
        // A confirmed mismatch is not an unavailable tool. Never publish
        // data known to differ from its source, even in best-effort mode.
        try compare(localHash, remoteHash)
        return .passed(algorithm)
    }

    struct LocalVersion: Equatable, Sendable {
        let size: Int64
        let modified: Date
        let inode: UInt64
        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
            modified = attributes[.modificationDate] as? Date ?? .distantPast
            inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
    }

    static func error(_ message: String) -> CoreError { .InvalidInput(message: message) }

    static func localDigest(url: URL, algorithm: String, control: CoreTransferControl) throws -> String {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw error(L10n.text("无法读取本地文件进行校验")) }
        defer { Darwin.close(fd) }
        return try localDigest(fd: fd, algorithm: algorithm, control: control)
    }

    static func localDigest(fd: Int32, algorithm: String, control: CoreTransferControl) throws -> String {
        guard ["SHA-256", "MD5"].contains(algorithm) else { throw error(L10n.text("未知校验算法")) }
        var sha = SHA256()
        var md5 = Insecure.MD5()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        var offset: off_t = 0
        while true {
            try control.checkpoint()
            let count = pread(fd, &buffer, buffer.count, offset)
            if count < 0 { if errno == EINTR { continue }; throw error(L10n.text("读取本地校验文件失败")) }
            if count == 0 { break }
            let data = Data(buffer[0..<count])
            if algorithm == "SHA-256" { sha.update(data: data) } else { md5.update(data: data) }
            offset += off_t(count)
        }
        return (algorithm == "SHA-256" ? Array(sha.finalize()) : Array(md5.finalize())).map { String(format: "%02x", $0) }.joined()
    }

    static func compare(_ local: String, _ remote: String) throws {
        guard local == remote else { throw error(L10n.text("文件摘要不一致，暂存文件未发布，请重新传输")) }
    }
}

/// Every descendant is opened relative to an already-open directory descriptor
/// with O_NOFOLLOW. Rename and unlink are also descriptor-relative, so a path
/// swapped to a symlink during a transfer cannot redirect writes elsewhere.
final class DownloadLocation: @unchecked Sendable {
    let fd: Int32
    let url: URL
    init(root: URL) throws {
        url = root.resolvingSymlinksInPath().standardizedFileURL
        fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw TransferIntegrity.error(L10n.text("无法打开下载目录")) }
    }
    private init(fd: Int32, url: URL) { self.fd = fd; self.url = url }
    deinit { Darwin.close(fd) }

    static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw TransferIntegrity.error(L10n.text("远端文件名不安全"))
        }
    }

    func directory(_ components: [String], create: Bool = true) throws -> DownloadLocation {
        var directory = self
        for component in components {
            try Self.validate(component)
            if create, mkdirat(directory.fd, component, 0o755) != 0, errno != EEXIST {
                throw TransferIntegrity.error(L10n.format("无法创建下载子目录：%@", component))
            }
            let child = openat(directory.fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw TransferIntegrity.error(L10n.format("下载路径包含软链接或非目录：%@", component)) }
            directory = DownloadLocation(fd: child, url: directory.url.appendingPathComponent(component))
        }
        return directory
    }

    func exists(_ name: String) throws -> Bool {
        try Self.validate(name)
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        if errno == ENOENT { return false }
        throw TransferIntegrity.error(L10n.format("无法检查本地目标：%@", name))
    }

    func publish(staging: String, name: String, overwrite: Bool) throws {
        try Self.validate(staging); try Self.validate(name)
        let flags: UInt32 = overwrite ? 0 : UInt32(RENAME_EXCL)
        guard renameatx_np(fd, staging, fd, name, flags) == 0 else {
            throw TransferIntegrity.error(L10n.format("发布下载文件失败，目标可能已存在或权限不足：%@", name))
        }
    }

    func createLink(name: String, target: String, overwrite: Bool) throws {
        try Self.validate(name)
        guard !target.contains("\0") else { throw TransferIntegrity.error(L10n.text("软链接目标无效")) }
        let temporary = ".snake-download-\(UUID().uuidString)"
        guard symlinkat(target, fd, temporary) == 0 else { throw TransferIntegrity.error(L10n.text("无法创建软链接")) }
        defer { unlinkat(fd, temporary, 0) }
        var buffer = [CChar](repeating: 0, count: target.utf8.count + 1)
        let size = readlinkat(fd, temporary, &buffer, buffer.count)
        guard size == target.utf8.count, String(decoding: buffer.prefix(Int(size)).map { UInt8(bitPattern: $0) }, as: UTF8.self) == target else {
            throw TransferIntegrity.error(L10n.text("软链接目标校验失败"))
        }
        try publish(staging: temporary, name: name, overwrite: overwrite)
    }
}

final class DownloadStaging: @unchecked Sendable {
    let parent: DownloadLocation
    let name = ".snake-download-\(UUID().uuidString)"
    let fd: Int32
    init(parent: DownloadLocation, size: UInt64) throws {
        self.parent = parent
        fd = openat(parent.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TransferIntegrity.error(L10n.text("无法创建本地暂存文件")) }
        guard size <= UInt64(Int64.max), ftruncate(fd, off_t(size)) == 0 else {
            Darwin.close(fd); unlinkat(parent.fd, name, 0)
            throw TransferIntegrity.error(L10n.text("无法分配本地暂存文件"))
        }
    }
    deinit { Darwin.close(fd); unlinkat(parent.fd, name, 0) }
    func publish(as finalName: String, overwrite: Bool) throws {
        guard fsync(fd) == 0 else { throw TransferIntegrity.error(L10n.text("下载文件写入磁盘失败")) }
        try parent.publish(staging: name, name: finalName, overwrite: overwrite)
    }
}
