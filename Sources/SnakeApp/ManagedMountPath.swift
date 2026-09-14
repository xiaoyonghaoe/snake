import CryptoKit
import Foundation

enum ManagedMountPath {
    static let root = "/Users/Shared/.SnakeMounts"

    static func isStable(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.hasPrefix("v1-") && name.count == 67
            && name.dropFirst(3).allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func localPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func make(profile: SSHProfile, local: String, remote: String) throws -> String {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, (1...65535).contains(profile.port), !local.isEmpty, remote.hasPrefix("/") else {
            throw ApplicationStoreError.invalidMapping
        }
        var remote = remote
        while remote.count > 1 && remote.hasSuffix("/") { remote.removeLast() }
        let bytes = try JSONSerialization.data(
            withJSONObject: [host, profile.port, localPath(local), remote],
            options: [.withoutEscapingSlashes]
        )
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "\(root)/v1-\(digest)"
    }

    static func validateTarget(_ path: String, mounted: Set<String>) throws {
        guard MountOperations.isManagedMountPath(path), !mounted.contains(path) else {
            throw ApplicationStoreError.mappingConflict(L10n.text("目标挂载目录已被占用，请先安全卸载。"))
        }
        let manager = FileManager.default
        guard (try? manager.destinationOfSymbolicLink(atPath: path)) == nil else {
            throw ApplicationStoreError.mappingConflict(L10n.text("目标挂载目录是软链接，无法使用。"))
        }
        var directory: ObjCBool = false
        if manager.fileExists(atPath: path, isDirectory: &directory) {
            guard directory.boolValue, try manager.contentsOfDirectory(atPath: path).isEmpty else {
                throw ApplicationStoreError.mappingConflict(L10n.format("目标挂载目录包含文件，无法覆盖：%@", path))
            }
        }
    }
}

/// Only moves a link known to point to the old mount. The backup allows a
/// configuration save failure to restore the original link without touching data.
final class MappingLinkChange {
    private let oldURL: URL
    private let newURL: URL
    private let backupURL: URL
    private var moved = false
    private var created = false

    init(from old: MountMapping, to new: MountMapping) throws {
        oldURL = URL(fileURLWithPath: ManagedMountPath.localPath(old.userAccessPath))
        newURL = URL(fileURLWithPath: ManagedMountPath.localPath(new.userAccessPath))
        backupURL = oldURL.deletingLastPathComponent().appendingPathComponent(".snake-link-\(UUID().uuidString)")
        guard oldURL != newURL || old.managedMountPath != new.managedMountPath else { return }
        let manager = FileManager.default
        guard let destination = try? manager.destinationOfSymbolicLink(atPath: oldURL.path) else { return }
        let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
            : oldURL.deletingLastPathComponent().appendingPathComponent(destination)
        guard target.standardizedFileURL.path == old.managedMountPath else { return }
        if newURL != oldURL,
           manager.fileExists(atPath: newURL.path) ||
           (try? manager.destinationOfSymbolicLink(atPath: newURL.path)) != nil {
            throw ApplicationStoreError.mappingConflict(L10n.text("新的本地目录已被占用。"))
        }
        do {
            try manager.createDirectory(at: newURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: oldURL, to: backupURL)
            moved = true
            try manager.createSymbolicLink(atPath: newURL.path, withDestinationPath: new.managedMountPath)
            created = true
        } catch {
            rollback()
            throw error
        }
    }

    func commit() {
        if moved { try? FileManager.default.removeItem(at: backupURL) }
        moved = false
        created = false
    }

    func rollback() {
        let manager = FileManager.default
        if created { try? manager.removeItem(at: newURL) }
        if moved { try? manager.moveItem(at: backupURL, to: oldURL) }
        moved = false
        created = false
    }
}
