import XCTest
@testable import SnakeApp

/// Covers the local cache used when opening a remote file: layout, atomic writes,
/// retention/size cleanup, and the guarantee that only files this app created are
/// ever removed from the chosen folder.
final class RemoteOpenCacheTests: XCTestCase {
    private var root: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent("snake-open-cache-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Layout

    func testDefaultRootLivesInTheSystemCacheDirectory() {
        let cache = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        XCTAssertEqual(
            RemoteOpenCache.defaultRoot().path,
            cache.appendingPathComponent("Snake/RemoteOpen", isDirectory: true).path
        )
    }

    func testFileURLIsStableAndDistinctPerRemotePath() {
        let directory = RemoteOpenCache.profileDirectory(root: root, profileID: UUID())
        let first = RemoteOpenCache.fileURL(in: directory, remotePath: "/var/log/app.log", fileName: "app.log")
        let again = RemoteOpenCache.fileURL(in: directory, remotePath: "/var/log/app.log", fileName: "app.log")
        let other = RemoteOpenCache.fileURL(in: directory, remotePath: "/var/log/other.log", fileName: "other.log")

        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertTrue(first.lastPathComponent.hasSuffix("-app.log"))
        XCTAssertTrue(RemoteOpenCache.isOwnedFileName(first.lastPathComponent))
    }

    func testOwnedNameRecognitionRejectsUserFiles() {
        XCTAssertTrue(RemoteOpenCache.isOwnedFileName("0123456789abcdef-report.txt"))
        XCTAssertFalse(RemoteOpenCache.isOwnedFileName("report.txt"))
        XCTAssertFalse(RemoteOpenCache.isOwnedFileName("0123456789abcdeF-report.txt"))
        XCTAssertFalse(RemoteOpenCache.isOwnedFileName("0123456789abcdef"))
        XCTAssertFalse(RemoteOpenCache.isOwnedFileName("0123456789abcdef-"))
    }

    // MARK: - Writing

    func testPrepareCreatesOwnerOnlyDirectory() throws {
        let directory = RemoteOpenCache.profileDirectory(root: root, profileID: UUID())
        try RemoteOpenCache.prepare(directory: directory, owned: true)
        let attributes = try fileManager.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
    }

    func testPrepareLeavesAnExistingFolderPermissionsAlone() throws {
        let existing = root.appendingPathComponent("chosen", isDirectory: true)
        try fileManager.createDirectory(at: existing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try RemoteOpenCache.prepare(directory: existing, owned: false)
        let attributes = try fileManager.attributesOfItem(atPath: existing.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o755)
    }

    func testStoreWritesOwnerOnlyFileWithoutResidue() throws {
        let target = root.appendingPathComponent("0123456789abcdef-a.txt")
        try RemoteOpenCache.store(at: target) { temporary in
            try Data("payload".utf8).write(to: temporary)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "payload")
        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try residueFiles(), [], "临时文件必须被清理")
    }

    func testStoreReplacesExistingFile() throws {
        let target = root.appendingPathComponent("0123456789abcdef-a.txt")
        try Data("old".utf8).write(to: target)
        try RemoteOpenCache.store(at: target) { temporary in
            try Data("new".utf8).write(to: temporary)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertEqual(try residueFiles(), [])
    }

    func testStoreLeavesPreviousContentWhenWritingFails() throws {
        let target = root.appendingPathComponent("0123456789abcdef-a.txt")
        try Data("complete".utf8).write(to: target)
        XCTAssertThrowsError(
            try RemoteOpenCache.store(at: target) { temporary in
                try Data("half".utf8).write(to: temporary)
                throw CocoaError(.fileWriteUnknown)
            }
        )
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "complete", "失败不得破坏上一份完整内容")
        XCTAssertEqual(try residueFiles(), [])
    }

    func testStoreLeavesNoTargetWhenThereWasNoneAndWritingFails() throws {
        let target = root.appendingPathComponent("0123456789abcdef-new.txt")
        XCTAssertThrowsError(
            try RemoteOpenCache.store(at: target) { _ in throw CocoaError(.fileWriteUnknown) }
        )
        XCTAssertFalse(fileManager.fileExists(atPath: target.path))
        XCTAssertEqual(try residueFiles(), [])
    }

    // MARK: - Cleanup

    func testPruneRemovesExpiredEntriesOnly() throws {
        let fresh = try writeOwnedFile(name: "0123456789abcdef-fresh.txt", bytes: 10, age: 60 * 60)
        let expired = try writeOwnedFile(name: "fedcba9876543210-old.txt", bytes: 10, age: 9 * 24 * 60 * 60)

        let report = try RemoteOpenCache.prune(root: root, policy: .sevenDays, sizeLimit: .unlimited)

        XCTAssertFalse(fileManager.fileExists(atPath: expired.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertEqual(report.files, 1)
    }

    func testPruneKeepsEverythingWhenPolicyIsNever() throws {
        let expired = try writeOwnedFile(name: "fedcba9876543210-old.txt", bytes: 10, age: 400 * 24 * 60 * 60)
        let report = try RemoteOpenCache.prune(root: root, policy: .never, sizeLimit: .unlimited)
        XCTAssertTrue(fileManager.fileExists(atPath: expired.path))
        XCTAssertEqual(report.removedFiles, 0)
    }

    func testPruneEvictsLeastRecentlyUsedUntilUnderTheLimit() throws {
        let oldest = try writeOwnedFile(name: "aaaa000000000000-a.bin", bytes: 400, age: 3 * 24 * 60 * 60)
        let middle = try writeOwnedFile(name: "bbbb000000000000-b.bin", bytes: 400, age: 2 * 24 * 60 * 60)
        let newest = try writeOwnedFile(name: "cccc000000000000-c.bin", bytes: 400, age: 1 * 24 * 60 * 60)

        // The public 250 MB budget is far above these files, so nothing is evicted.
        var report = try RemoteOpenCache.prune(root: root, policy: .never, sizeLimit: .mb250)
        XCTAssertEqual(report.removedFiles, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: oldest.path))

        // A byte budget below the 1200-byte total evicts the least recently used entry.
        report = try RemoteOpenCache.prune(root: root, policy: .never, sizeLimitBytes: 900)
        XCTAssertFalse(fileManager.fileExists(atPath: oldest.path), "最久未用的应先被删除")
        XCTAssertEqual(report.files, 2)
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: middle.path))
        XCTAssertTrue(fileManager.fileExists(atPath: newest.path))
    }

    func testPruneKeepsTheNewestEntryEvenWhenItAloneExceedsTheLimit() throws {
        let newest = try writeOwnedFile(name: "cccc000000000000-c.bin", bytes: 5_000, age: 60)
        let older = try writeOwnedFile(name: "aaaa000000000000-a.bin", bytes: 5_000, age: 3 * 24 * 60 * 60)
        _ = try RemoteOpenCache.prune(root: root, policy: .never, sizeLimitBytes: 1_000)
        XCTAssertTrue(fileManager.fileExists(atPath: newest.path), "刚打开的文件必须保留")
        XCTAssertFalse(fileManager.fileExists(atPath: older.path))
    }

    func testPruneNeverTouchesForeignFiles() throws {
        let foreignFile = root.appendingPathComponent("keep-me.txt")
        try Data("mine".utf8).write(to: foreignFile)
        let foreignDirectory = root.appendingPathComponent("not-a-uuid", isDirectory: true)
        try fileManager.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
        let foreignInside = foreignDirectory.appendingPathComponent("0123456789abcdef-x.txt")
        try Data("mine".utf8).write(to: foreignInside)

        let profile = RemoteOpenCache.profileDirectory(root: root, profileID: UUID())
        try RemoteOpenCache.prepare(directory: profile, owned: true)
        let unrelatedInside = profile.appendingPathComponent("notes.md")
        try Data("mine".utf8).write(to: unrelatedInside)
        let expired = RemoteOpenCache.fileURL(in: profile, remotePath: "/expired", fileName: "expired")
        try Data("cached".utf8).write(to: expired)
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-400 * 24 * 60 * 60)], ofItemAtPath: expired.path)

        let report = try RemoteOpenCache.prune(root: root, policy: .sevenDays, sizeLimit: .mb250)

        XCTAssertTrue(fileManager.fileExists(atPath: foreignFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: foreignInside.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedInside.path), "非本缓存命名的文件不得删除")
        XCTAssertFalse(fileManager.fileExists(atPath: expired.path))
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertEqual(report.files, 0)
    }

    func testPruneRemovesStalePartialFilesAndKeepsFreshOnes() throws {
        let profile = RemoteOpenCache.profileDirectory(root: root, profileID: UUID())
        try RemoteOpenCache.prepare(directory: profile, owned: true)
        let stale = profile.appendingPathComponent("0123456789abcdef-a.txt.partial-\(UUID().uuidString)")
        let fresh = profile.appendingPathComponent("0123456789abcdef-b.txt.partial-\(UUID().uuidString)")
        try Data("x".utf8).write(to: stale)
        try Data("x".utf8).write(to: fresh)
        try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 24 * 60 * 60)], ofItemAtPath: stale.path)

        _ = try RemoteOpenCache.prune(root: root, policy: .never, sizeLimit: .unlimited)

        XCTAssertFalse(fileManager.fileExists(atPath: stale.path))
        XCTAssertTrue(fileManager.fileExists(atPath: fresh.path))
    }

    func testClearRemovesOwnEntriesAndKeepsForeignFiles() throws {
        let foreignFile = root.appendingPathComponent("keep-me.txt")
        try Data("mine".utf8).write(to: foreignFile)
        let profile = RemoteOpenCache.profileDirectory(root: root, profileID: UUID())
        try RemoteOpenCache.prepare(directory: profile, owned: true)
        let cached = RemoteOpenCache.fileURL(in: profile, remotePath: "/a", fileName: "a")
        try Data("cached".utf8).write(to: cached)

        let report = try RemoteOpenCache.clear(root: root)

        XCTAssertFalse(fileManager.fileExists(atPath: cached.path))
        XCTAssertTrue(fileManager.fileExists(atPath: foreignFile.path))
        XCTAssertEqual(report.removedFiles, 1)
        XCTAssertEqual(report.files, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: profile.path), "清空后的自有目录应被移除")
    }

    func testUsageCountsOnlyOwnEntries() throws {
        let foreignFile = root.appendingPathComponent("keep-me.txt")
        try Data(String(repeating: "x", count: 100).utf8).write(to: foreignFile)
        _ = try writeOwnedFile(name: "0123456789abcdef-a.bin", bytes: 10, age: 0)
        _ = try writeOwnedFile(name: "fedcba9876543210-b.bin", bytes: 20, age: 0)

        let report = try RemoteOpenCache.usage(root: root)

        XCTAssertEqual(report.files, 2)
        XCTAssertEqual(report.bytes, 30)
        XCTAssertEqual(report.removedFiles, 0)
    }

    func testUsageOnMissingRootIsEmpty() throws {
        let missing = root.appendingPathComponent("never-created", isDirectory: true)
        let report = try RemoteOpenCache.usage(root: missing)
        XCTAssertEqual(report, RemoteOpenCacheReport())
    }

    // MARK: - Settings

    @MainActor
    func testCacheSettingsPersistAndFallBack() throws {
        let suite = "snake-open-cache-settings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let database = root.appendingPathComponent("settings.sqlite3")
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(store.remoteOpenCleanupPolicy, .sevenDays)
        XCTAssertEqual(store.remoteOpenSizeLimit, .mb500)
        XCTAssertNil(store.remoteOpenDirectoryBookmark)
        XCTAssertEqual(store.remoteOpenDirectoryPath, RemoteOpenCache.defaultRoot().path)
        XCTAssertNil(store.remoteOpenCacheNotice)

        store.remoteOpenCleanupPolicy = .thirtyDays
        store.remoteOpenSizeLimit = .gb2
        let chosen = try RemoteOpenCache.bookmark(for: root)
        store.remoteOpenDirectoryBookmark = chosen

        let restored = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(restored.remoteOpenCleanupPolicy, .thirtyDays)
        XCTAssertEqual(restored.remoteOpenSizeLimit, .gb2)
        XCTAssertEqual(restored.remoteOpenDirectoryBookmark, chosen)
        XCTAssertEqual(
            URL(fileURLWithPath: restored.remoteOpenDirectoryPath).resolvingSymlinksInPath().path,
            root.resolvingSymlinksInPath().path
        )
        XCTAssertNil(restored.remoteOpenCacheNotice)

        defaults.set(99, forKey: "com.snake.transfer.remote-open-retention")
        defaults.set(7, forKey: "com.snake.transfer.remote-open-size-limit")
        let fallback = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(fallback.remoteOpenCleanupPolicy, .sevenDays)
        XCTAssertEqual(fallback.remoteOpenSizeLimit, .mb500)
    }

    @MainActor
    func testUnresolvableBookmarkFallsBackToDefaultLocation() throws {
        let suite = "snake-open-cache-stale-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data([0x00, 0x01, 0x02]), forKey: "com.snake.transfer.remote-open-directory")
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("stale.sqlite3"), userDefaults: defaults)

        XCTAssertEqual(store.remoteOpenDirectoryPath, RemoteOpenCache.defaultRoot().path)
        XCTAssertEqual(store.remoteOpenCacheNotice, L10n.text("所选目录不可用，已恢复默认位置。"))
    }

    // MARK: - Deleting one session

    func testRemoveProfileDirectoryKeepsForeignContentAndTheDirectory() throws {
        let owned = try writeOwnedFile(name: "0123456789abcdef-report.pdf", bytes: 128, age: 0)
        let directory = owned.deletingLastPathComponent()
        let userFile = directory.appendingPathComponent("我的笔记.md")
        try Data("mine".utf8).write(to: userFile)
        let userDirectory = directory.appendingPathComponent("我的子目录", isDirectory: true)
        try fileManager.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        let nested = userDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: nested)

        let report = RemoteOpenCache.removeProfileDirectory(root: root, profileID: Self.sharedProfileID)

        XCTAssertEqual(report.removedFiles, 1, "只应删除自己下载的那一份")
        XCTAssertFalse(fileManager.fileExists(atPath: owned.path))
        XCTAssertTrue(fileManager.fileExists(atPath: userFile.path), "用户文件不得删除")
        XCTAssertTrue(fileManager.fileExists(atPath: nested.path), "用户子目录里的内容不得删除")
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path), "目录里还有用户内容时必须保留")
    }

    func testRemoveProfileDirectoryDeletesTheDirectoryWhenOnlyOwnedEntriesRemain() throws {
        let owned = try writeOwnedFile(name: "0123456789abcdef-report.pdf", bytes: 64, age: 0)
        let directory = owned.deletingLastPathComponent()
        let stalePartial = directory.appendingPathComponent("0123456789abcdef-report.pdf.partial-\(UUID().uuidString)")
        try Data("half".utf8).write(to: stalePartial)

        let report = RemoteOpenCache.removeProfileDirectory(root: root, profileID: Self.sharedProfileID)

        XCTAssertEqual(report.removedFiles, 2)
        XCTAssertEqual(report.removedBytes, 68)
        XCTAssertFalse(fileManager.fileExists(atPath: directory.path), "只剩缓存副本时目录应一并删除")
    }

    func testRemoveProfileDirectoryIgnoresForeignNames() throws {
        let directory = RemoteOpenCache.profileDirectory(root: root, profileID: Self.sharedProfileID)
        try RemoteOpenCache.prepare(directory: directory, owned: true)
        let foreign = [
            "notes.md",
            "0123456789abcde-report.pdf",
            "0123456789ABCDEF-report.pdf",
            "0123456789abcdef",
        ]
        for name in foreign {
            try Data("mine".utf8).write(to: directory.appendingPathComponent(name))
        }
        let foreignDirectory = directory.appendingPathComponent("我的目录", isDirectory: true)
        try fileManager.createDirectory(at: foreignDirectory, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: foreignDirectory.appendingPathComponent("0123456789abcdef-x.txt"))

        let report = RemoteOpenCache.removeProfileDirectory(root: root, profileID: Self.sharedProfileID)

        XCTAssertEqual(report.removedFiles, 0, "名字不符合缓存规则的条目一律不碰")
        for name in foreign {
            XCTAssertTrue(fileManager.fileExists(atPath: directory.appendingPathComponent(name).path), name)
        }
        XCTAssertTrue(fileManager.fileExists(atPath: foreignDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
    }

    func testRemoveProfileDirectoryIsANoOpForAMissingSession() {
        let report = RemoteOpenCache.removeProfileDirectory(root: root, profileID: UUID())
        XCTAssertEqual(report, RemoteOpenCacheReport())
        XCTAssertTrue(fileManager.fileExists(atPath: root.path))
    }

    /// 边界：`<16 位小写十六进制>-<名字>` 本身就是合法缓存名，即使名字里含
    /// `.partial-`。只有后缀确实能解析成 UUID 时才算「写入中的临时文件」。
    func testPartialNameNeedsAUUIDSuffixToCountAsATemporaryFile() {
        XCTAssertFalse(RemoteOpenCache.isOwnedPartialName("0123456789abcdef-a.partial-notauuid"))
        XCTAssertTrue(RemoteOpenCache.isOwnedFileName("0123456789abcdef-a.partial-notauuid"))
        XCTAssertTrue(RemoteOpenCache.isOwnedPartialName("0123456789abcdef-a.partial-\(UUID().uuidString)"))
    }

    func testRemoveProfileDirectoryRefusesASymlinkedSessionDirectory() throws {
        let target = fileManager.temporaryDirectory.appendingPathComponent("snake-link-target-\(UUID())", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: target) }
        let victim = target.appendingPathComponent("0123456789abcdef-victim.txt")
        try Data("precious".utf8).write(to: victim)

        let profileID = UUID()
        try fileManager.createSymbolicLink(at: root.appendingPathComponent(profileID.uuidString), withDestinationURL: target)

        let report = RemoteOpenCache.removeProfileDirectory(root: root, profileID: profileID)

        XCTAssertEqual(report.removedFiles, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: victim.path), "符号链接不得把删除导向别处")
    }

    func testRemoveProfileDirectoryRefusesAFileNamedLikeASession() throws {
        let profileID = UUID()
        let file = root.appendingPathComponent(profileID.uuidString)
        try Data("mine".utf8).write(to: file)

        let report = RemoteOpenCache.removeProfileDirectory(root: root, profileID: profileID)

        XCTAssertEqual(report.removedFiles, 0)
        XCTAssertTrue(fileManager.fileExists(atPath: file.path))
    }

    func testClearKeepsAProfileDirectoryItCannotList() throws {
        let directory = RemoteOpenCache.profileDirectory(root: root, profileID: Self.sharedProfileID)
        try RemoteOpenCache.prepare(directory: directory, owned: true)
        try Data("mine".utf8).write(to: directory.appendingPathComponent("我的笔记.md"))

        // `contentsOfDirectory(atPath:)` 失败时不能被当成「空目录」——removeItem 对目录是递归删除。
        let surrogate = UnlistableFileManager()
        let scan = try RemoteOpenCache.scan(root: root, fileManager: surrogate)
        XCTAssertEqual(scan.profileDirectories.count, 1, "扫描必须仍能看到该会话目录，否则这条断言无意义")

        _ = try RemoteOpenCache.clear(root: root, fileManager: surrogate)

        XCTAssertTrue(surrogate.removedPaths.isEmpty, "列不出目录时不得删除任何东西")
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path))
    }

    /// 端到端：删除 SSH 会话不得带走用户放在缓存目录里的文件。
    @MainActor
    func testDeletingASessionKeepsUserFilesInTheChosenCacheFolder() async throws {
        let suite = "snake-open-cache-delete-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ApplicationStore(databaseURL: root.appendingPathComponent("delete.sqlite3"), userDefaults: defaults)
        let profile = SSHProfile(name: "cache-delete", host: "127.0.0.1", username: "tester")
        try store.save(profile: profile, credential: nil)

        // 切换目录时会顺带清理「上一个」根目录；这里先关掉保留期与容量策略，避免测试
        // 动到开发机上真实的默认缓存。
        store.remoteOpenCleanupPolicy = .never
        store.remoteOpenSizeLimit = .unlimited
        XCTAssertNil(store.setRemoteOpenDirectory(root))

        let directory = RemoteOpenCache.profileDirectory(root: root, profileID: profile.id)
        try RemoteOpenCache.prepare(directory: directory, owned: true)
        let owned = RemoteOpenCache.fileURL(in: directory, remotePath: "/remote/report.pdf", fileName: "report.pdf")
        try Data("cached".utf8).write(to: owned)
        let userFile = directory.appendingPathComponent("我的笔记.md")
        try Data("mine".utf8).write(to: userFile)

        store.delete(profile: profile)

        // 必须等清理真的发生（副本消失），否则「用户文件还在」会因为任务没跑而假通过。
        let deadline = Date().addingTimeInterval(5)
        while fileManager.fileExists(atPath: owned.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(fileManager.fileExists(atPath: owned.path), "该会话的缓存副本应被清理")
        XCTAssertTrue(fileManager.fileExists(atPath: userFile.path), "用户文件不得删除")
        XCTAssertTrue(fileManager.fileExists(atPath: directory.path), "目录里还有用户内容时必须保留")
    }

    // MARK: - Helpers

    @discardableResult
    private func writeOwnedFile(name: String, bytes: Int, age: TimeInterval) throws -> URL {
        let profile = RemoteOpenCache.profileDirectory(root: root, profileID: Self.sharedProfileID)
        try RemoteOpenCache.prepare(directory: profile, owned: true)
        let url = profile.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        if age > 0 {
            try fileManager.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        return url
    }

    /// Every owned file in these tests lives under one profile directory.
    private static let sharedProfileID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func residueFiles() throws -> [String] {
        let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)!
        var residue: [String] = []
        for case let url as URL in enumerator where url.lastPathComponent.contains(".partial-") {
            residue.append(url.lastPathComponent)
        }
        return residue
    }
}

/// 扫描（URL 版列举）照常工作，但 `contentsOfDirectory(atPath:)` 会失败，用来验证
/// 「列不出目录」不会被当成「空目录」。删除动作只记录、不真正执行。
private final class UnlistableFileManager: FileManager, @unchecked Sendable {
    private(set) var removedPaths: [String] = []

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        throw CocoaError(.fileReadNoPermission)
    }

    override func removeItem(atPath path: String) throws {
        removedPaths.append(path)
    }

    override func removeItem(at url: URL) throws {
        removedPaths.append(url.path)
    }
}
