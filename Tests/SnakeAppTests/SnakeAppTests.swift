import AppKit
import SQLite3
import XCTest
@testable import SnakeApp

@MainActor
final class SnakeAppTests: XCTestCase {
    func testSavedPasswordMetadataAndProfileAssociationRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snake-password-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snake.sqlite3")
        let persistence = try CorePersistence(databaseURL: url)
        let saved = SavedPassword(name: "team", username: "deploy")
        XCTAssertEqual(try persistence.save(saved, selectedProfileIDs: [], syncUsername: false), [])
        var profile = SSHProfile(name: "host", host: "127.0.0.1", username: "deploy", savedPasswordID: saved.id)
        try persistence.save(profile)
        XCTAssertEqual(try persistence.loadProfiles().first?.savedPasswordID, saved.id)
        let loaded = try XCTUnwrap(persistence.loadSavedPasswords().first)
        XCTAssertEqual([loaded.id, loaded.name, loaded.username] as [AnyHashable], [saved.id, saved.name, saved.username])
        XCTAssertNotNil(loaded.createdAt)
        XCTAssertEqual(loaded.updatedAt, loaded.createdAt)
        profile.username = "independent"
        profile.savedPasswordID = nil
        try persistence.save(profile)
        XCTAssertNil(try persistence.loadProfiles().first?.savedPasswordID)
        try persistence.deleteSavedPassword(id: saved.id)
        XCTAssertTrue(try persistence.loadSavedPasswords().isEmpty)
        XCTAssertEqual(try persistence.loadProfiles().first?.username, "independent")
    }

    func testProfileConnectionLabelUsesMonoFriendlyFormat() {
        let profile = SSHProfile(name: "api", host: "10.0.0.8", port: 2222, username: "deploy")
        XCTAssertEqual(profile.connectionLabel, "deploy@10.0.0.8:2222")
    }

    func testTagMigrationMovesLooseSessionsIntoFirstTagFolder() {
        let existing = SessionGroup(name: "生产", sortOrder: 0)
        let filed = SSHProfile(groupID: existing.id, name: "filed", host: "a", username: "u", tags: ["测试"])
        let reuse = SSHProfile(name: "reuse", host: "b", username: "u", tags: ["生产", "API"])
        let fresh = SSHProfile(name: "fresh", host: "c", username: "u", tags: ["测试"])
        let sibling = SSHProfile(name: "sibling", host: "d", username: "u", tags: [" 测试 "])
        let untagged = SSHProfile(name: "untagged", host: "e", username: "u")
        let result = SessionFolders.placingByFirstTag(groups: [existing], profiles: [filed, reuse, fresh, sibling, untagged])
        XCTAssertEqual(result.groups.map(\.name), ["生产", "测试"])
        let created = try? XCTUnwrap(result.groups.last)
        XCTAssertEqual(result.profiles[0].groupID, existing.id, "a session already in a folder stays put")
        XCTAssertEqual(result.profiles[1].groupID, existing.id, "an existing folder of that name is reused")
        XCTAssertEqual(result.profiles[2].groupID, created?.id)
        XCTAssertEqual(result.profiles[3].groupID, created?.id, "one folder per tag name")
        XCTAssertNil(result.profiles[4].groupID)
        XCTAssertEqual(result.profiles[1].tags, ["生产", "API"], "tags stay stored")
    }

    func testFolderNamesAreTrimmedAndUniqueIgnoringCase() {
        let folder = SessionGroup(name: "Prod")
        XCTAssertNil(SessionFolders.validatedName("  ", among: [folder]))
        XCTAssertNil(SessionFolders.validatedName(" prod ", among: [folder]))
        XCTAssertEqual(SessionFolders.validatedName(" PROD ", among: [folder], excluding: folder.id), "PROD")
        XCTAssertEqual(SessionFolders.validatedName(" 测试 ", among: [folder]), "测试")
    }

    func testFolderSearchCoversNameAddressAccountAndFolder() {
        let profile = SSHProfile(name: "阿里云", host: "39.107.43.50", username: "root", tags: ["hidden"])
        XCTAssertTrue(SessionFolders.matches(profile, query: "", folderName: nil))
        XCTAssertTrue(SessionFolders.matches(profile, query: "39.107", folderName: nil))
        XCTAssertTrue(SessionFolders.matches(profile, query: "ROOT", folderName: nil))
        XCTAssertTrue(SessionFolders.matches(profile, query: "生产", folderName: "生产服务器"))
        XCTAssertFalse(SessionFolders.matches(profile, query: "hidden", folderName: nil), "tags are no longer searched")
    }

    func testLongPressMoveTakesTheTargetsPlace() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(SessionFolders.moving("a", onto: "c", in: ids), ["b", "c", "a", "d"], "moving forward lands after the target")
        XCTAssertEqual(SessionFolders.moving("d", onto: "b", in: ids), ["a", "d", "b", "c"], "moving back lands before the target")
        XCTAssertEqual(SessionFolders.moving("b", onto: "b", in: ids), ids)
        XCTAssertEqual(SessionFolders.moving("x", onto: "b", in: ids), ids)
        XCTAssertEqual(SessionFolders.moving("a", onto: "x", in: ids), ids)
    }

    func testCardDragStartsOnMovementOrAfterAShortHold() {
        XCTAssertFalse(SessionFolders.dragActivates(distance: 0, held: 2), "holding still is not a drag")
        XCTAssertFalse(SessionFolders.dragActivates(distance: 3, held: 0.1), "a click with a small wobble stays a click")
        XCTAssertTrue(SessionFolders.dragActivates(distance: 6, held: 0), "dragging straight away works")
        XCTAssertTrue(SessionFolders.dragActivates(distance: 2, held: 0.3), "after a short hold any movement lifts the card")
        XCTAssertTrue(SessionFolders.dragActivates(distance: 40, held: 1), "drifting while holding no longer cancels")
    }

    func testFolderTreeHelpers() {
        let top = SessionGroup(name: "生产", sortOrder: 1)
        let other = SessionGroup(name: "测试", sortOrder: 0)
        let mid = SessionGroup(name: "华东", sortOrder: 0, parentID: top.id)
        let leaf = SessionGroup(name: "数据库", sortOrder: 0, parentID: mid.id)
        let orphan = SessionGroup(name: "孤儿", sortOrder: 2, parentID: UUID())
        let groups = [leaf, top, orphan, mid, other]
        XCTAssertEqual(SessionFolders.children(of: nil, in: groups).map(\.name), ["测试", "生产", "孤儿"],
                       "a folder whose parent vanished shows at the top level")
        XCTAssertEqual(SessionFolders.children(of: top.id, in: groups).map(\.name), ["华东"])
        XCTAssertEqual(SessionFolders.path(to: leaf.id, in: groups).map(\.name), ["生产", "华东", "数据库"])
        XCTAssertTrue(SessionFolders.isWithin(leaf.id, top.id, in: groups))
        XCTAssertTrue(SessionFolders.isWithin(top.id, top.id, in: groups))
        XCTAssertFalse(SessionFolders.isWithin(top.id, leaf.id, in: groups))
        XCTAssertFalse(SessionFolders.isWithin(nil, top.id, in: groups))
        let ordered = SessionFolders.parentsFirst(groups).map(\.id)
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: top.id)), try XCTUnwrap(ordered.firstIndex(of: mid.id)))
        XCTAssertLessThan(try XCTUnwrap(ordered.firstIndex(of: mid.id)), try XCTUnwrap(ordered.firstIndex(of: leaf.id)))
        XCTAssertNotNil(SessionFolders.validatedName("华东", among: groups), "names only clash with siblings")
        XCTAssertNil(SessionFolders.validatedName("华东", among: groups, parentID: top.id))
    }

    @MainActor
    func testNestedFoldersCreateMoveDeleteAndPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-nest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.snake.tests.nest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = root.appendingPathComponent("db.sqlite3")
        try CorePersistence(databaseURL: database).save(SSHProfile(name: "db-01", host: "10.0.0.9", username: "root"))
        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)

        let production = try XCTUnwrap(store.createFolder(named: "生产"))
        let east = try XCTUnwrap(store.createFolder(named: "华东", in: production.id))
        let databases = try XCTUnwrap(store.createFolder(named: "数据库", in: east.id))
        XCTAssertNotNil(store.createFolder(named: "华东"), "the same name is fine at another level")
        XCTAssertNil(store.createFolder(named: "华东", in: production.id), "but not among siblings")

        XCTAssertFalse(store.moveFolder(id: production.id, to: databases.id), "a folder cannot move into its own subfolder")
        let profileID = try XCTUnwrap(store.profiles.first?.id)
        store.move(profileID: profileID, to: east.id)
        XCTAssertEqual(store.folderName(for: try XCTUnwrap(store.profiles.first)), "生产 / 华东")
        XCTAssertTrue(store.folderPaths.map(\.path).contains("生产 / 华东 / 数据库"))

        store.deleteFolder(id: east.id)
        XCTAssertEqual(store.profiles.first?.groupID, production.id, "sessions move up one level")
        XCTAssertEqual(store.groups.first { $0.id == databases.id }?.parentID, production.id, "subfolders move up one level")

        XCTAssertTrue(store.moveFolder(id: databases.id, to: nil))
        let reloaded = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertNil(reloaded.groups.first { $0.id == databases.id }?.parentID)
        XCTAssertEqual(reloaded.profiles.first?.groupID, production.id)
        XCTAssertEqual(Set(reloaded.childFolders(of: nil).map(\.name)), ["生产", "华东", "数据库"])
    }

    @MainActor
    func testStoreReordersFoldersAndSessionsAndKeepsFolderIcons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.snake.tests.order.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = root.appendingPathComponent("db.sqlite3")
        let persistence = try CorePersistence(databaseURL: database)
        for (index, name) in ["one", "two", "three"].enumerated() {
            try persistence.save(SSHProfile(name: name, host: "10.0.0.\(index)", username: "root", sortOrder: index))
        }
        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        let alpha = try XCTUnwrap(store.createFolder(named: "Alpha"))
        let beta = try XCTUnwrap(store.createFolder(named: "Beta"))
        XCTAssertEqual(store.childFolders(of: nil).map(\.name), ["Alpha", "Beta"])
        store.reorderFolders([beta.id, alpha.id])
        XCTAssertEqual(store.childFolders(of: nil).map(\.name), ["Beta", "Alpha"])

        func id(_ name: String) throws -> UUID { try XCTUnwrap(store.profiles.first { $0.name == name }?.id) }
        store.reorderProfiles([try id("three"), try id("one"), try id("two")])
        XCTAssertEqual(store.profiles.sorted { $0.sortOrder < $1.sortOrder }.map(\.name), ["three", "one", "two"])

        store.move(profileID: try id("one"), to: alpha.id)
        store.move(profileID: try id("two"), to: alpha.id)
        let inAlpha = store.profiles.filter { $0.groupID == alpha.id }.sorted { $0.sortOrder < $1.sortOrder }
        XCTAssertEqual(inAlpha.map(\.name), ["one", "two"], "moving into a folder appends at its end")
        store.move(profileID: try id("one"), to: nil)
        XCTAssertNil(store.profiles.first { $0.name == "one" }?.groupID)

        let png = try XCTUnwrap(NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.systemOrange.setFill(); rect.fill(); return true
        }.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) })
        // Folder icons share the app's real icon folder; never leave this one behind.
        defer { ProfileIconStore.delete(for: beta.id) }
        try store.setFolderIcon(png, for: beta.id)
        XCTAssertNotNil(ProfileIconStore.data(for: beta.id))
        store.deleteFolder(id: beta.id)
        XCTAssertNil(ProfileIconStore.data(for: beta.id), "deleting a folder removes its icon")

        let reloaded = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(reloaded.childFolders(of: nil).map(\.name), ["Alpha"])
        XCTAssertEqual(reloaded.profiles.first { $0.name == "two" }?.groupID, alpha.id)
    }

    @MainActor
    func testSessionTimestampsSurviveReorderingAndMoveOnEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-stamps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.snake.tests.stamps.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = root.appendingPathComponent("db.sqlite3")
        let persistence = try CorePersistence(databaseURL: database)
        let first = SSHProfile(name: "one", host: "10.0.0.1", username: "root", sortOrder: 0)
        let second = SSHProfile(name: "two", host: "10.0.0.2", username: "root", sortOrder: 1)
        try persistence.save(first)
        try persistence.save(second)
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE ssh_profiles SET created_at = 100, updated_at = 200", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)

        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        let old = SSHProfileTimestamps(createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.profileTimestamps[first.id], old, "launching re-saves every session without editing it")
        store.reorderProfiles([second.id, first.id])
        XCTAssertEqual(store.profileTimestamps[first.id], old, "reordering is not an edit")

        var renamed = try XCTUnwrap(store.profiles.first { $0.id == first.id })
        renamed.name = "one-renamed"
        try store.save(profile: renamed)
        let edited = try XCTUnwrap(store.profileTimestamps[first.id])
        XCTAssertEqual(edited.createdAt, old.createdAt)
        XCTAssertGreaterThan(edited.updatedAt, old.updatedAt)
        XCTAssertEqual(store.profileTimestamps[second.id], old)

        store.delete(profile: renamed)
        XCTAssertNil(store.profileTimestamps[first.id])
    }

    @MainActor
    func testStoreMigratesTagsOnceAndDeletingAFolderKeepsItsSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.snake.tests.folders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = root.appendingPathComponent("db.sqlite3")
        let tagged = SSHProfile(name: "tagged", host: "10.0.0.1", username: "root", tags: ["测试"])
        try CorePersistence(databaseURL: database).save(tagged)

        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        let folder = try XCTUnwrap(store.groups.first { $0.name == "测试" })
        XCTAssertEqual(store.profiles.first?.groupID, folder.id)
        XCTAssertNil(store.createFolder(named: "测试"), "duplicate names are refused")
        let other = try XCTUnwrap(store.createFolder(named: "生产"))
        XCTAssertTrue(store.renameFolder(id: other.id, to: "生产服务器"))
        XCTAssertFalse(store.renameFolder(id: other.id, to: " 测试 "))

        store.deleteFolder(id: folder.id)
        XCTAssertEqual(store.profiles.map(\.name), ["tagged"], "deleting a folder never deletes sessions")
        XCTAssertNil(store.profiles.first?.groupID)

        // The migration ran once: a reload must not recreate the deleted folder.
        let reloaded = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(reloaded.groups.map(\.name), ["生产服务器"])
        XCTAssertNil(reloaded.profiles.first?.groupID)
    }

    func testCustomProfileIconMarkerAndCropOutput() throws {
        let profile = SSHProfile(
            name: "custom-icon",
            host: "127.0.0.1",
            username: "root",
            symbolName: SSHProfile.customIconSymbolName
        )
        XCTAssertTrue(profile.usesCustomIcon)

        let source = NSImage(size: NSSize(width: 640, height: 360))
        source.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 360).fill()
        source.unlockFocus()
        let data = try XCTUnwrap(ProfileIconCropRenderer.pngData(
            from: source,
            zoom: 1.4,
            offset: CGSize(width: 18, height: -9),
            viewportSize: 300
        ))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(bitmap.pixelsWide, 512)
        XCTAssertEqual(bitmap.pixelsHigh, 512)
    }

    func testTransferProgressIsBounded() {
        let job = TransferJob(sourceProfileName: "本机", targetProfileName: "api", sourcePath: "/a", targetPath: "/b", totalBytes: 100, completedBytes: 140)
        XCTAssertEqual(job.progress, 1)
    }

    func testRemoteSymbolicLinkKeepsTargetAndDirectoryBehavior() throws {
        let file = RemoteFile(
            name: "current",
            path: "/srv/current",
            isDirectory: true,
            isSymbolicLink: true,
            linkTarget: "releases/2026-09-01"
        )
        XCTAssertTrue(file.isDirectory)
        XCTAssertTrue(file.isSymbolicLink)
        XCTAssertEqual(file.linkTarget, "releases/2026-09-01")

        let payload = RemoteFileTransferPayload(
            sourceRuntimeID: UUID(),
            sourceProfileID: UUID(),
            sourcePath: file.path,
            fileName: file.name,
            fileSize: file.size,
            isDirectory: file.isDirectory,
            isSymbolicLink: file.isSymbolicLink,
            linkTarget: file.linkTarget
        )
        let decoded = try JSONDecoder().decode(
            RemoteFileTransferPayload.self,
            from: JSONEncoder().encode(payload)
        )
        XCTAssertTrue(decoded.isSymbolicLink)
        XCTAssertEqual(decoded.linkTarget, file.linkTarget)
    }

    func testNewTerminalTabRequestsConnectionImmediately() {
        let profile = SSHProfile(name: "server", host: "127.0.0.1", username: "root")
        let runtime = WorkspaceTabRuntime(terminal: profile)
        XCTAssertEqual(runtime.terminal?.state, .connecting)
        XCTAssertEqual(runtime.terminal?.launchRequested, true)
    }

    func testTerminalConnectionAutomaticallyRetriesOnlyOneConnectionFailure() {
        XCTAssertTrue(TerminalConnectionRetryPolicy.shouldRetry(
            .Connection(message: "temporarily unavailable", stage: "tcp_connect"),
            retryIndex: 0
        ))
        XCTAssertFalse(TerminalConnectionRetryPolicy.shouldRetry(
            .Connection(message: "closed", stage: "ssh_handshake"),
            retryIndex: 1
        ))
        XCTAssertFalse(TerminalConnectionRetryPolicy.shouldRetry(
            .Authentication(message: "invalid password", stage: "auth_password"),
            retryIndex: 0
        ))
        XCTAssertFalse(TerminalConnectionRetryPolicy.shouldRetry(
            .InvalidInput(message: "host is empty"),
            retryIndex: 0
        ))
    }

    func testSFTPUploadRecordDurationFreezesWhenFinished() {
        let start = Date(timeIntervalSince1970: 1_000)
        let record = SFTPUploadRecord(
            jobID: UUID(),
            fileName: "archive.zip",
            remotePath: "/srv/archive.zip",
            fileSize: 1024,
            startedAt: start,
            finishedAt: start.addingTimeInterval(7.5),
            state: .succeeded,
            localURL: URL(fileURLWithPath: "/tmp/archive.zip"),
            overwrite: true
        )
        XCTAssertEqual(record.duration(at: start.addingTimeInterval(60)), 7.5, accuracy: 0.001)
    }

    func testTerminalRemoteDirectoryParsesOSC7AndRejectsUnsafePaths() {
        XCTAssertEqual(
            LocalUploadCoordinator.normalizedRemoteDirectory(from: "file://server/srv/发布%20目录"),
            "/srv/发布 目录"
        )
        XCTAssertEqual(
            LocalUploadCoordinator.normalizedRemoteDirectory(from: "/var/www/../releases"),
            "/var/releases"
        )
        XCTAssertNil(LocalUploadCoordinator.normalizedRemoteDirectory(from: "relative/path"))
        XCTAssertNil(LocalUploadCoordinator.normalizedRemoteDirectory(from: "file://server/tmp\nunsafe"))
    }

    func testTerminalShellHooksAreTemporarySessionCommands() {
        for shell in ["bash", "zsh", "fish"] {
            let command = TerminalShellIntegration.hookCommand(for: shell)
            XCTAssertNotNil(command)
            XCTAssertTrue(command?.contains("]7;file://") == true)
            XCTAssertFalse(command?.contains(".bashrc") == true)
            XCTAssertFalse(command?.contains(".zshrc") == true)
            XCTAssertFalse(command?.contains("config.fish") == true)
        }
        XCTAssertNil(TerminalShellIntegration.hookCommand(for: "tcsh"))
    }

    func testAppKeepsRunningAfterLastWindowCloses() {
        let delegate = SnakeAppDelegate()
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testCloseFocusedItemClosesEmptySplitBeforeWindow() {
        let state = WorkspaceWindowState()
        XCTAssertNotNil(state.splitFocusedPane(.horizontal))
        XCTAssertEqual(state.bonsplit.allPaneIds.count, 2)

        XCTAssertTrue(state.closeCurrentItem())
        XCTAssertEqual(state.bonsplit.allPaneIds.count, 1)
        XCTAssertFalse(state.closeCurrentItem())
    }

    func testCloseFocusedItemClosesSelectedWorkspaceTab() {
        let state = WorkspaceWindowState()
        let profile = SSHProfile(name: "files", host: "127.0.0.1", username: "root")
        XCTAssertTrue(state.add(WorkspaceTabRuntime(sftp: profile)))

        XCTAssertTrue(state.closeCurrentItem())
        XCTAssertTrue(state.tabs.isEmpty)
    }

    func testCloseCurrentItemUsesLastInteractedPaneWithDuplicateTitles() {
        let state = WorkspaceWindowState()
        let profile = SSHProfile(name: "duplicate", host: "127.0.0.1", username: "root")
        XCTAssertTrue(state.add(WorkspaceTabRuntime(sftp: profile)))
        let firstTabID = try! XCTUnwrap(state.bonsplit.allTabIds.first)
        let firstPaneID = try! XCTUnwrap(state.bonsplit.focusedPaneId)

        let secondPaneID = try! XCTUnwrap(state.splitFocusedPane(.horizontal))
        XCTAssertTrue(state.add(WorkspaceTabRuntime(sftp: profile), to: secondPaneID))
        let secondTabID = try! XCTUnwrap(state.bonsplit.tabs(inPane: secondPaneID).first?.id)

        state.bonsplit.focusPane(firstPaneID)
        XCTAssertEqual(state.activePaneID, firstPaneID)
        XCTAssertTrue(state.closeCurrentItem())

        XCTAssertNil(state.tabs[firstTabID])
        XCTAssertNotNil(state.tabs[secondTabID])
    }

    func testTabContextMenuSplitsTheClickedPane() {
        let state = WorkspaceWindowState()
        XCTAssertTrue(state.add(WorkspaceTabRuntime(sftp: SSHProfile(name: "files", host: "127.0.0.1", username: "root"))))
        let tabID = try! XCTUnwrap(state.bonsplit.allTabIds.first)
        let paneID = try! XCTUnwrap(state.bonsplit.focusedPaneId)

        state.performTabContextAction(.splitHorizontal, tabID: tabID, paneID: paneID)

        XCTAssertEqual(state.bonsplit.allPaneIds.count, 2)
        XCTAssertEqual(state.tabs.count, 1)
    }

    func testTabContextMenuClosesOnlyOtherTabsInSamePane() {
        let state = WorkspaceWindowState()
        for index in 1...3 {
            XCTAssertTrue(state.add(WorkspaceTabRuntime(sftp: SSHProfile(
                name: "files-\(index)",
                host: "127.0.0.1",
                username: "root"
            ))))
        }
        let keptTabID = state.bonsplit.allTabIds[1]
        let paneID = try! XCTUnwrap(state.bonsplit.focusedPaneId)

        state.performTabContextAction(.closeOthers, tabID: keptTabID, paneID: paneID)

        XCTAssertEqual(state.bonsplit.allTabIds, [keptTabID])
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertNotNil(state.tabs[keptTabID])
    }

    func testTabContextMenuDetachForwardsExactTabAndPane() {
        let state = WorkspaceWindowState()
        XCTAssertTrue(state.add(WorkspaceTabRuntime(sftp: SSHProfile(name: "files", host: "127.0.0.1", username: "root"))))
        let tabID = try! XCTUnwrap(state.bonsplit.allTabIds.first)
        let paneID = try! XCTUnwrap(state.bonsplit.focusedPaneId)
        var receivedMatches = false
        state.tabDetachHandler = { _, detachedTabID, detachedPaneID in
            receivedMatches = detachedTabID == tabID && detachedPaneID == paneID
        }

        state.performTabContextAction(.detach, tabID: tabID, paneID: paneID)

        XCTAssertTrue(receivedMatches)
    }

    func testRemotePermissionModeParsesOctalInput() {
        XCTAssertEqual(RemotePermissionMode.parse("0644"), 0o644)
        XCTAssertEqual(RemotePermissionMode.parse("755"), 0o755)
        XCTAssertEqual(RemotePermissionMode.parse("0o2755"), 0o2755)
        XCTAssertNil(RemotePermissionMode.parse("0888"))
        XCTAssertNil(RemotePermissionMode.parse("10000"))
        XCTAssertEqual(RemotePermissionMode.display("0755", isDirectory: true), "0755")
        XCTAssertEqual(RemotePermissionMode.display("", isDirectory: false), "0644")
    }

    func testVisualRemotePermissionSelectionMapsCheckboxesToMode() {
        var selection = RemotePermissionSelection(modeText: "0754", isDirectory: true)
        XCTAssertTrue(selection.contains(.ownerRead))
        XCTAssertTrue(selection.contains(.ownerWrite))
        XCTAssertTrue(selection.contains(.ownerExecute))
        XCTAssertTrue(selection.contains(.groupRead))
        XCTAssertFalse(selection.contains(.groupWrite))
        XCTAssertTrue(selection.contains(.groupExecute))
        XCTAssertTrue(selection.contains(.otherRead))
        XCTAssertFalse(selection.contains(.otherWrite))
        XCTAssertFalse(selection.contains(.otherExecute))

        selection.set(.groupWrite, enabled: true)
        selection.set(.ownerExecute, enabled: false)
        XCTAssertEqual(selection.display, "0674")
    }

    func testTerminalThemesHaveCompleteReadablePalettes() {
        XCTAssertEqual(TerminalTheme.light.ansiHex.count, 16)
        XCTAssertEqual(TerminalTheme.dark.ansiHex.count, 16)
        XCTAssertGreaterThanOrEqual(
            contrastRatio(TerminalTheme.light.foregroundHex, TerminalTheme.light.backgroundHex),
            4.5
        )
        XCTAssertGreaterThanOrEqual(
            contrastRatio(TerminalTheme.dark.foregroundHex, TerminalTheme.dark.backgroundHex),
            4.5
        )
    }

    func testApplyingTerminalThemeKeepsStableSurface() {
        let profile = SSHProfile(name: "theme", host: "127.0.0.1", username: "root")
        let runtime = TerminalRuntime(profile: profile)
        let surface = runtime.terminalSurface()

        runtime.applyTheme(.light)
        XCTAssertTrue(surface === runtime.terminalSurface())
        XCTAssertEqual(surface.nativeBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0, 1, accuracy: 0.001)

        runtime.applyTheme(.dark)
        XCTAssertTrue(surface === runtime.terminalSurface())
        XCTAssertEqual(
            surface.nativeBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0,
            17.0 / 255.0,
            accuracy: 0.002
        )
    }

    func testRustPersistenceRoundTripsWorkspaceConfiguration() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snake-core-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let persistence = try CorePersistence(databaseURL: databaseURL)
        let group = SessionGroup(name: "测试环境")
        let profile = SSHProfile(groupID: group.id, name: "api", host: "10.0.0.8", username: "deploy")
        let mapping = MountMapping(
            profileID: profile.id,
            name: "发布目录",
            remotePath: "/srv/releases",
            userAccessPath: "~/Snake/releases",
            managedMountPath: "/Users/Shared/.SnakeMounts/test"
        )

        try persistence.save(group)
        try persistence.save(profile)
        try persistence.save(mapping, profileSnapshot: profile.name)

        XCTAssertEqual(try persistence.loadGroups(), [group])
        XCTAssertEqual(try persistence.loadProfiles(), [profile])
        XCTAssertEqual(try persistence.loadMountMappings().first?.id, mapping.id)
    }

    private func contrastRatio(_ foreground: UInt32, _ background: UInt32) -> Double {
        let lighter = max(relativeLuminance(foreground), relativeLuminance(background))
        let darker = min(relativeLuminance(foreground), relativeLuminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ hex: UInt32) -> Double {
        let red = linearComponent(UInt8((hex >> 16) & 0xFF))
        let green = linearComponent(UInt8((hex >> 8) & 0xFF))
        let blue = linearComponent(UInt8(hex & 0xFF))
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    private func linearComponent(_ byte: UInt8) -> Double {
        let component = Double(byte) / 255
        if component <= 0.04045 { return component / 12.92 }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}
