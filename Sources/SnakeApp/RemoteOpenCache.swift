import CryptoKit
import Foundation

/// How long an opened remote file stays in the local cache.
public enum RemoteOpenCleanupPolicy: Int, CaseIterable, Identifiable, Sendable {
    case never = 0
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30

    public var id: Int { rawValue }

    /// Number of days, or `nil` when automatic time-based cleanup is off.
    public var days: Int? { self == .never ? nil : rawValue }

    public var title: String {
        switch self {
        case .never: L10n.text("永不")
        case .oneDay: L10n.text("1 天")
        case .sevenDays: L10n.text("7 天")
        case .thirtyDays: L10n.text("30 天")
        }
    }
}

/// Total size the local cache is allowed to occupy.
public enum RemoteOpenSizeLimit: Int, CaseIterable, Identifiable, Sendable {
    case unlimited = 0
    case mb250 = 250
    case mb500 = 500
    case gb2 = 2048

    public var id: Int { rawValue }

    /// Byte budget, or `nil` when no size limit is set.
    public var bytes: Int64? { self == .unlimited ? nil : Int64(rawValue) * 1_048_576 }

    /// Size labels are unit text and stay verbatim; only "unlimited" is localized.
    public var title: String {
        switch self {
        case .unlimited: L10n.text("不限")
        case .mb250: "250 MB"
        case .mb500: "500 MB"
        case .gb2: "2 GB"
        }
    }
}

/// What a cache maintenance pass did, and what it left behind.
public struct RemoteOpenCacheReport: Equatable, Sendable {
    public var files: Int = 0
    public var bytes: Int64 = 0
    public var removedFiles: Int = 0
    public var removedBytes: Int64 = 0

    public init(files: Int = 0, bytes: Int64 = 0, removedFiles: Int = 0, removedBytes: Int64 = 0) {
        self.files = files
        self.bytes = bytes
        self.removedFiles = removedFiles
        self.removedBytes = removedBytes
    }
}

/// Everything the "open a remote file" path needs from Settings.
public struct RemoteOpenCacheConfiguration: Sendable {
    public var directoryBookmark: Data?
    public var policy: RemoteOpenCleanupPolicy
    public var sizeLimit: RemoteOpenSizeLimit

    public init(directoryBookmark: Data?, policy: RemoteOpenCleanupPolicy, sizeLimit: RemoteOpenSizeLimit) {
        self.directoryBookmark = directoryBookmark
        self.policy = policy
        self.sizeLimit = sizeLimit
    }

    public static let `default` = RemoteOpenCacheConfiguration(
        directoryBookmark: nil,
        policy: .sevenDays,
        sizeLimit: .mb500
    )
}

/// The local cache used when opening a remote file in an external application.
///
/// Layout is fixed at `<root>/<profile-uuid>/<sha256(remote path)[0..16]>-<file name>`.
/// Everything this type touches is derived from that layout: a user's own files in a
/// chosen folder, directories whose name is not a UUID, and files whose name does not
/// match our prefix are never read, moved, or deleted. Automatic cleanup (by age and
/// by size) and "clear now" both rely on that invariant.
enum RemoteOpenCache {
    static let defaultRootRelativePath = "Snake/RemoteOpen"
    static let filePrefixLength = 16
    /// Lifetime of a leftover `.partial-*` file from a crash or a hard kill.
    static let stalePartialLifetime: TimeInterval = 24 * 60 * 60
    static let ownedDirectoryPermissions = 0o700
    static let ownedFilePermissions = 0o600

    // MARK: - Location

    struct Location: Sendable {
        var url: URL
        var isDefault: Bool
        /// True when a security scope was opened and must be closed by the caller.
        var scoped: Bool
        /// True when a stored bookmark could not be resolved and the default was used.
        var fellBackFromBookmark: Bool
    }

    /// `~/Library/Caches/Snake/RemoteOpen`.
    static func defaultRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(defaultRootRelativePath, isDirectory: true)
    }

    /// Creates a bookmark for a folder the user chose in an open panel.
    ///
    /// App-scoped bookmarks require the `com.apple.security.files.bookmarks.app-scope`
    /// entitlement, which this app does not carry; a plain bookmark is used instead so
    /// the choice still survives relaunches.
    static func bookmark(for url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves the cache root for the current settings.
    ///
    /// A bookmarked folder that can no longer be resolved falls back to the default
    /// location and reports it, so opening a file never fails because the user moved
    /// or removed the folder they had chosen.
    static func location(bookmark: Data?, accessScope: Bool, fileManager: FileManager = .default) -> Location {
        guard let bookmark else {
            return Location(url: defaultRoot(fileManager: fileManager), isDefault: true, scoped: false, fellBackFromBookmark: false)
        }
        var stale = false
        let resolved = (try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )) ?? (try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ))
        guard let url = resolved else {
            return Location(url: defaultRoot(fileManager: fileManager), isDefault: true, scoped: false, fellBackFromBookmark: true)
        }
        // A stale-but-resolvable bookmark still points at the right folder; macOS only
        // asks us to write a fresh one, so it is not treated as a fallback.
        let scoped = accessScope ? url.startAccessingSecurityScopedResource() : false
        return Location(url: url, isDefault: false, scoped: scoped, fellBackFromBookmark: false)
    }

    static func profileDirectory(root: URL, profileID: UUID) -> URL {
        root.appendingPathComponent(profileID.uuidString, isDirectory: true)
    }

    static func fileURL(in directory: URL, remotePath: String, fileName: String) -> URL {
        let digest = SHA256.hash(data: Data(remotePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(String(digest.prefix(filePrefixLength)) + "-" + fileName, isDirectory: false)
    }

    /// True only for names this cache created: 16 hex characters, a dash, and a name.
    static func isOwnedFileName(_ name: String) -> Bool {
        guard name.count > filePrefixLength + 1 else { return false }
        let prefix = name.prefix(filePrefixLength)
        guard prefix.allSatisfy({ $0.isHexDigit && ($0.isNumber || $0.isLowercase) }) else { return false }
        return name[name.index(name.startIndex, offsetBy: filePrefixLength)] == "-"
    }

    /// True for an in-flight temporary file: `<owned name>.partial-<uuid>`.
    static func isOwnedPartialName(_ name: String) -> Bool {
        guard let marker = name.range(of: ".partial-", options: .backwards) else { return false }
        let base = String(name[name.startIndex..<marker.lowerBound])
        let suffix = String(name[marker.upperBound...])
        return isOwnedFileName(base) && UUID(uuidString: suffix) != nil
    }

    // MARK: - Writing

    /// Creates `directory` when needed. Attributes apply only on creation, so an
    /// existing folder the user chose keeps its own permissions.
    static func prepare(directory: URL, owned: Bool, fileManager: FileManager = .default) throws {
        let attributes: [FileAttributeKey: Any]? = owned ? [.posixPermissions: ownedDirectoryPermissions] : nil
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: attributes)
    }

    /// Downloads into a sibling temporary file and only then replaces the target, so a
    /// failed or interrupted transfer can never leave truncated content behind.
    static func store(at target: URL, fileManager: FileManager = .default, writing: (URL) throws -> Void) throws {
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            "\(target.lastPathComponent).partial-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try writing(temporary)
        try fileManager.setAttributes([.posixPermissions: ownedFilePermissions], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: target.path) {
            do {
                _ = try fileManager.replaceItemAt(target, withItemAt: temporary, backupItemName: nil, options: [.usingNewMetadataOnly])
                return
            } catch {
                try? fileManager.removeItem(at: target)
            }
        }
        try fileManager.moveItem(at: temporary, to: target)
    }

    /// The default location lives in the system cache directory; keep it out of backups.
    static func excludeFromBackup(_ url: URL) {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: - Maintenance

    /// Current usage of cache entries this app created.
    static func usage(root: URL, fileManager: FileManager = .default) throws -> RemoteOpenCacheReport {
        let scan = try scan(root: root, fileManager: fileManager)
        return RemoteOpenCacheReport(
            files: scan.files.count,
            bytes: scan.files.reduce(Int64(0)) { $0 + $1.size }
        )
    }

    /// Removes stale temporaries, then entries older than `policy`, then the
    /// least recently used entries until the cache fits inside `sizeLimit`.
    ///
    /// The most recently used entry is kept even when it alone exceeds the limit:
    /// dropping the file the user just opened would only cause it to be downloaded
    /// again on the next click.
    @discardableResult
    static func prune(
        root: URL,
        policy: RemoteOpenCleanupPolicy,
        sizeLimit: RemoteOpenSizeLimit,
        now: Date = .now,
        fileManager: FileManager = .default
    ) throws -> RemoteOpenCacheReport {
        try prune(root: root, policy: policy, sizeLimitBytes: sizeLimit.bytes, now: now, fileManager: fileManager)
    }

    /// The same pass with an explicit byte budget, so the eviction loop stays testable
    /// without writing hundreds of megabytes.
    @discardableResult
    static func prune(
        root: URL,
        policy: RemoteOpenCleanupPolicy,
        sizeLimitBytes: Int64?,
        now: Date = .now,
        fileManager: FileManager = .default
    ) throws -> RemoteOpenCacheReport {
        let before = try scan(root: root, fileManager: fileManager)
        var removedFiles = 0
        var removedBytes: Int64 = 0

        for partial in before.partials where now.timeIntervalSince(partial.modified) > stalePartialLifetime {
            try? fileManager.removeItem(at: partial.url)
        }

        if let days = policy.days {
            let cutoff = now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
            for entry in before.files where entry.modified < cutoff {
                try? fileManager.removeItem(at: entry.url)
                removedFiles += 1
                removedBytes += entry.size
            }
        }

        if let limit = sizeLimitBytes {
            var survivors = before.files.filter { fileManager.fileExists(atPath: $0.url.path) }
            var total = survivors.reduce(Int64(0)) { $0 + $1.size }
            survivors.sort { $0.modified < $1.modified }
            var index = 0
            while total > limit, index < survivors.count - 1 {
                let victim = survivors[index]
                index += 1
                try? fileManager.removeItem(at: victim.url)
                total -= victim.size
                removedFiles += 1
                removedBytes += victim.size
            }
        }

        removeEmptyProfileDirectories(before.profileDirectories, fileManager: fileManager)

        let remaining = try scan(root: root, fileManager: fileManager)
        return RemoteOpenCacheReport(
            files: remaining.files.count,
            bytes: remaining.files.reduce(Int64(0)) { $0 + $1.size },
            removedFiles: removedFiles,
            removedBytes: removedBytes
        )
    }

    /// Removes every entry this app created, leaving anything else in the folder alone.
    @discardableResult
    static func clear(root: URL, fileManager: FileManager = .default) throws -> RemoteOpenCacheReport {
        let scan = try scan(root: root, fileManager: fileManager)
        var removedFiles = 0
        var removedBytes: Int64 = 0
        for entry in scan.files + scan.partials {
            try? fileManager.removeItem(at: entry.url)
            removedFiles += 1
            removedBytes += entry.size
        }
        removeEmptyProfileDirectories(scan.profileDirectories, fileManager: fileManager)
        return RemoteOpenCacheReport(files: 0, bytes: 0, removedFiles: removedFiles, removedBytes: removedBytes)
    }

    /// Removes only what this cache created for one session, then the directory itself
    /// once nothing else is left in it.
    ///
    /// Deleting a session must never recurse into a folder the user chose: entries whose
    /// names are not ours stay untouched, and a directory that still holds content — or
    /// that cannot be listed — is kept. `FileManager.removeItem` on a directory is
    /// recursive, so a failed listing must never be read as "empty".
    ///
    /// Only `removedFiles`/`removedBytes` are meaningful in the returned report: whatever
    /// the directory still contains belongs to the user and is not counted as cache usage.
    @discardableResult
    static func removeProfileDirectory(
        root: URL,
        profileID: UUID,
        fileManager: FileManager = .default
    ) -> RemoteOpenCacheReport {
        let directory = profileDirectory(root: root, profileID: profileID)
        guard isOwnedProfileDirectory(directory) else { return RemoteOpenCacheReport() }

        var report = RemoteOpenCacheReport()
        for entry in ownedEntries(inProfileDirectory: directory, fileManager: fileManager) {
            do {
                try fileManager.removeItem(at: entry.url)
                report.removedFiles += 1
                report.removedBytes += entry.size
            } catch {}
        }

        if let remaining = try? fileManager.contentsOfDirectory(atPath: directory.path), remaining.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
        return report
    }

    // MARK: - Internals

    struct Entry {
        let url: URL
        let size: Int64
        let modified: Date
        let profileDirectory: URL
    }

    struct Scan {
        var files: [Entry] = []
        var partials: [Entry] = []
        var profileDirectories: [URL] = []
    }

    /// Enumerates only paths that match our layout; everything else is ignored.
    static func scan(root: URL, fileManager: FileManager = .default) throws -> Scan {
        var result = Scan()
        guard fileManager.fileExists(atPath: root.path) else { return result }
        let children = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            guard isOwnedProfileDirectory(child) else { continue }
            result.profileDirectories.append(child)
            for entry in ownedEntries(inProfileDirectory: child, fileManager: fileManager) {
                if isOwnedPartialName(entry.url.lastPathComponent) {
                    result.partials.append(entry)
                } else {
                    result.files.append(entry)
                }
            }
        }
        return result
    }

    /// True only for a session directory this app created: a real directory whose name is
    /// a UUID. `isDirectory` is false for a symbolic link to a directory, so a link can
    /// never make a later cleanup delete through it.
    private static func isOwnedProfileDirectory(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isDirectory == true,
              values.isSymbolicLink != true else { return false }
        return UUID(uuidString: url.lastPathComponent) != nil
    }

    /// Entries this cache created inside one session directory.
    ///
    /// Ownership is decided by name alone: `<16 lowercase hex>-<name>` for a cached copy,
    /// plus `.partial-<uuid>` for an in-flight temporary file. Anything else belongs to
    /// the user and is never read, moved or deleted.
    private static func ownedEntries(inProfileDirectory directory: URL, fileManager: FileManager) -> [Entry] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        )) ?? []
        var result: [Entry] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: keys)
            guard values?.isDirectory != true else { continue }
            let name = entry.lastPathComponent
            guard isOwnedFileName(name) || isOwnedPartialName(name) else { continue }
            result.append(Entry(
                url: entry,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast,
                profileDirectory: directory
            ))
        }
        return result
    }

    private static func removeEmptyProfileDirectories(_ directories: [URL], fileManager: FileManager) {
        for directory in directories {
            // `removeItem` deletes a directory recursively, so a listing that fails must
            // never be treated as an empty folder.
            guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
                  contents.isEmpty else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }
}
