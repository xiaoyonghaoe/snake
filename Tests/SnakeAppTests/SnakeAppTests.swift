import AppKit
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
        XCTAssertEqual(try persistence.loadSavedPasswords(), [saved])
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

    func testSessionTagsUseWhitespaceAndRemoveDuplicates() {
        XCTAssertEqual(SessionTags.parse("生产 API  内网\nAPI\t测试"), ["生产", "API", "内网", "测试"])
        XCTAssertEqual(SessionTags.format(["生产", "API", "内网"]), "生产 API 内网")
    }

    func testSessionTagMultiSelectRequiresEverySelectedTag() {
        XCTAssertTrue(SessionTagFilter.matches(profileTags: ["生产", "API", "内网"], selectedTags: ["生产", "API"]))
        XCTAssertFalse(SessionTagFilter.matches(profileTags: ["生产", "数据库"], selectedTags: ["生产", "API"]))
        XCTAssertTrue(SessionTagFilter.matches(profileTags: [], selectedTags: []))
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
        let transfer = TransferJob(
            sourceProfileName: "本机",
            targetProfileName: profile.name,
            sourcePath: "/tmp/a.zip",
            targetPath: "/srv/a.zip",
            totalBytes: 1024,
            completedBytes: 128,
            state: .paused
        )

        try persistence.save(group)
        try persistence.save(profile)
        try persistence.save(mapping, profileSnapshot: profile.name)
        try persistence.save(transfer)

        XCTAssertEqual(try persistence.loadGroups(), [group])
        XCTAssertEqual(try persistence.loadProfiles(), [profile])
        XCTAssertEqual(try persistence.loadMountMappings().first?.id, mapping.id)
        XCTAssertEqual(try persistence.loadTransferJobs().first?.id, transfer.id)
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
