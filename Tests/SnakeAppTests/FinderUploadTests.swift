import AppKit
import SwiftUI
import XCTest
@testable import SnakeApp

@MainActor
final class FinderUploadTests: XCTestCase {
    func testSFTPProviderURLsShareNativeValidationAndRejectMixedPayloads() async throws {
        let file = URL(fileURLWithPath: "/tmp/文件 100%.txt")
        let folder = URL(fileURLWithPath: "/tmp/中文 文件夹", isDirectory: true)
        XCTAssertEqual(try FinderUploadPasteboard.localURL(from: file as NSURL), file)
        XCTAssertEqual(try FinderUploadPasteboard.localURL(from: file.dataRepresentation as NSData), file)
        func provider(_ url: URL) -> NSItemProvider {
            NSItemProvider(item: url as NSURL, typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue)
        }
        let loaded = try await FinderUploadPasteboard.urls(from: [provider(file), provider(folder), provider(file)])
        XCTAssertEqual(loaded, [file.standardizedFileURL, folder.standardizedFileURL])
        for forbiddenType in [FinderUploadPasteboard.workspaceTab, FinderUploadPasteboard.remoteFile, WorkspaceDragPayload.profileType] {
            let mixed = provider(file)
            mixed.registerDataRepresentation(forTypeIdentifier: forbiddenType.rawValue, visibility: .all) { completion in
                completion(Data(), nil); return nil
            }
            do {
                _ = try await FinderUploadPasteboard.urls(from: [mixed])
                XCTFail("Mixed workspace/remote-file payload must not become a local upload")
            } catch { XCTAssertTrue(error is FinderUploadError) }
        }
        do {
            _ = try await FinderUploadPasteboard.urls(from: [provider(file), provider(URL(string: "https://example.com/file")!)])
            XCTFail("An invalid member must reject the whole batch")
        } catch { XCTAssertTrue(error is FinderUploadError) }
    }

    func testFinderBatchPreservesOrderDeduplicatesAndRejectsOtherDragTypes() throws {
        let board = NSPasteboard(name: .init("com.snake.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/文件 100%.txt")
        let folder = URL(fileURLWithPath: "/tmp/多层 文件夹", isDirectory: true)
        board.writeObjects([file as NSURL, folder as NSURL, file as NSURL])
        XCTAssertEqual(try FinderUploadPasteboard.urls(from: board), [file.standardizedFileURL, folder.standardizedFileURL])
        for type in [FinderUploadPasteboard.workspaceTab, FinderUploadPasteboard.remoteFile, WorkspaceDragPayload.profileType] {
            board.addTypes([type], owner: nil)
            board.setString("{}", forType: type)
            XCTAssertFalse(FinderUploadPasteboard.accepts(board))
            XCTAssertThrowsError(try FinderUploadPasteboard.urls(from: board))
            board.clearContents()
            board.writeObjects([file as NSURL])
        }
        board.clearContents()
        board.setString(file.absoluteString, forType: .string)
        XCTAssertFalse(FinderUploadPasteboard.accepts(board), "Text resembling a path is not a Finder file")
    }

    func testMixedInvalidItemsDoNotSilentlyUploadPartialBatch() {
        let board = NSPasteboard(name: .init("com.snake.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let valid = NSPasteboardItem()
        valid.setString("file:///tmp/valid.txt", forType: .fileURL)
        let invalid = NSPasteboardItem()
        invalid.setString("https://example.com/not-local", forType: .fileURL)
        board.writeObjects([valid, invalid])
        XCTAssertThrowsError(try FinderUploadPasteboard.urls(from: board))
    }

    func testDirectoryEnumerationPreservesStructureAcrossMacPathAliases() throws {
        let root = URL(fileURLWithPath: "/tmp/snake-upload-scan-\(UUID())")
        let folder = root.appendingPathComponent("中文 文件夹")
        let nested = folder.appendingPathComponent("子目录/empty.txt")
        let fm = FileManager.default
        try fm.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data().write(to: nested)
        try fm.createDirectory(at: folder.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)
        let items = try LocalUploadCoordinator.uploadItems(for: folder, destinationRoot: "/srv/target")
        XCTAssertEqual(Set(items.map(\.remotePath)), [
            "/srv/target/中文 文件夹", "/srv/target/中文 文件夹/子目录",
            "/srv/target/中文 文件夹/子目录/empty.txt", "/srv/target/中文 文件夹/空文件夹"
        ])
        XCTAssertEqual(items.filter { !$0.isDirectory }.first?.size, 0)
        XCTAssertTrue(items.prefix(3).allSatisfy(\.isDirectory))
        XCTAssertThrowsError(try LocalUploadCoordinator.uploadItems(for: root.appendingPathComponent("missing"), destinationRoot: "/srv"))
    }

    func testNativeDropTracksSplitGeometryAndReparentedWindowNotKeyboardFocus() throws {
        let firstWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        firstWindow.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        firstWindow.contentView = root
        let left = FinderUploadHostingView(rootView: Color.clear)
        let right = FinderUploadHostingView(rootView: Color.clear)
        left.translatesAutoresizingMaskIntoConstraints = true
        right.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(left)
        root.addSubview(right)
        left.frame = NSRect(x: 200, y: 0, width: 400, height: 560)
        right.frame = NSRect(x: 600, y: 0, width: 400, height: 560)
        left.isActiveTarget = { true }
        right.isActiveTarget = { true }
        left.uploadTarget = { .directory("/left") }
        right.uploadTarget = { .directory("/right") }
        let terminal = TerminalRuntime(profile: SSHProfile(name: "test", host: "localhost", username: "test"))
        let surface = terminal.terminalSurface()
        left.addSubview(surface)
        surface.frame = left.bounds

        let hiddenTab = FinderUploadHostingView(rootView: Color.clear)
        hiddenTab.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(hiddenTab)
        hiddenTab.frame = left.frame
        hiddenTab.isActiveTarget = { false }

        let board = NSPasteboard(name: .init("com.snake.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let file = URL(fileURLWithPath: "/tmp/probe.txt")
        board.writeObjects([file as NSURL])
        let info = TestDraggingInfo(window: firstWindow, board: board, location: NSPoint(x: 320, y: 180))
        let router = FinderUploadWindowRouter()
        var destinations: [FinderUploadTarget] = []
        left.performUpload = { urls, target, _ in
            XCTAssertEqual(urls, [file.standardizedFileURL])
            destinations.append(target)
        }
        right.performUpload = { _, target, _ in destinations.append(target) }

        XCTAssertTrue(FinderUploadWindowRouter.destination(in: root, at: info.draggingLocation)?.destinationView === left, "left=\(left.frame) right=\(right.frame) root=\(root.frame)")
        XCTAssertEqual(router.draggingEntered(info), .copy)
        // Normal mouse hit-testing must reach the native terminal under the indicator.
        XCTAssertTrue(left.hitTest(NSPoint(x: left.frame.minX + 100, y: left.frame.minY + 100)) === surface)
        XCTAssertTrue(router.performDragOperation(info))
        info.draggingLocation = NSPoint(x: 780, y: 180)
        XCTAssertEqual(router.draggingUpdated(info), .copy)
        right.uploadTarget = { .directory("/right/new-directory") }
        XCTAssertTrue(router.performDragOperation(info))
        XCTAssertEqual(destinations, [.directory("/left"), .directory("/right/new-directory")])

        // Sidebar/titlebar must never upload into the last focused terminal.
        for point in [NSPoint(x: 100, y: 180), NSPoint(x: 320, y: 580)] {
            info.draggingLocation = point
            XCTAssertEqual(router.draggingUpdated(info), [])
            XCTAssertFalse(router.performDragOperation(info))
        }

        let detached = NSWindow(contentRect: NSRect(x: 1200, y: 100, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        detached.isReleasedWhenClosed = false
        detached.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        left.removeFromSuperview()
        detached.contentView?.addSubview(left)
        left.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        detached.setFrameOrigin(NSPoint(x: 400, y: 200))
        info.draggingDestinationWindow = detached
        info.draggingLocation = NSPoint(x: 250, y: 180)
        XCTAssertTrue(router.performDragOperation(info))
        XCTAssertEqual(destinations.last, .directory("/left"))
        XCTAssertTrue(left.window === detached)
        XCTAssertTrue(left.registeredDraggedTypes.contains(.fileURL))
        left.isActiveTarget = { false }
        XCTAssertFalse(router.performDragOperation(info), "Detached/closed/hidden tabs cannot receive stale drops")
        firstWindow.close()
        detached.close()
    }

    func testDisconnectedSessionsRejectFinderDropTargets() {
        let profile = SSHProfile(name: "test", host: "localhost", username: "test")
        XCTAssertFalse(WorkspaceTabRuntime(terminal: profile).finderUploadTarget.canUpload)
        XCTAssertFalse(WorkspaceTabRuntime(sftp: profile).finderUploadTarget.canUpload)
    }

    func testFinderDragCancellationClearsOverlayAndRejectsStaleCoordinates() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FinderUploadHostingView(rootView: Color.clear)
        window.contentView = host
        host.isActiveTarget = { true }
        host.uploadTarget = { .directory("/tmp") }
        let board = NSPasteboard(name: .init("com.snake.tests.\(UUID())"))
        defer { board.releaseGlobally(); window.close() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/probe.txt") as NSURL])
        let info = TestDraggingInfo(window: window, board: board, location: NSPoint(x: 100, y: 100))
        let count = host.subviews.count
        XCTAssertEqual(host.draggingEntered(info), .copy)
        XCTAssertEqual(host.subviews.count, count + 1)
        host.draggingEnded(info)
        XCTAssertEqual(host.subviews.count, count)
        info.draggingLocation = NSPoint(x: 700, y: 100)
        XCTAssertFalse(host.prepareForDragOperation(info))
        XCTAssertFalse(host.performDragOperation(info))
    }

    func testUploadAreaExcludesPathEditorAndConnectionBelt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FinderUploadHostingView(rootView: Color.clear)
        window.contentView = host
        host.requiresUploadArea = true
        host.isActiveTarget = { true }
        host.uploadTarget = { .directory("/srv") }
        // NSHostingView uses top-down coordinates; reserve its top 60 points.
        let area = FinderUploadAreaView(frame: NSRect(x: 0, y: 60, width: 600, height: 340))
        host.addSubview(area)
        let board = NSPasteboard(name: .init("com.snake.tests.\(UUID())"))
        defer { board.releaseGlobally(); window.close() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/probe") as NSURL])
        let info = TestDraggingInfo(window: window, board: board, location: NSPoint(x: 200, y: 370))
        XCTAssertFalse(host.prepareForDragOperation(info))
        info.draggingLocation = NSPoint(x: 200, y: 100)
        XCTAssertTrue(host.prepareForDragOperation(info))
    }
}

/// Opt-in real SSH/SFTP verification. The fixture must be our loopback sshd,
/// using its test key and a host key already verified through Snake's UI.
@MainActor
final class FinderUploadIntegrationTests: XCTestCase {
    func testNativeDestinationsUploadThroughSFTPAndTerminalAfterWindowMove() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["SNAKE_LOCAL_SSH_FIXTURE_ROOT"],
              fixture.hasPrefix("/tmp/snake-finder-upload-") else {
            throw XCTSkip("Set SNAKE_LOCAL_SSH_FIXTURE_ROOT for the isolated loopback SSH fixture")
        }
        let fm = FileManager.default
        let suite = "com.snake.tests.upload.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = URL(fileURLWithPath: fixture).appendingPathComponent("integration-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        store.multipartThresholdMB = 1
        store.multipartConcurrency = 4
        let bookmark = try URL(fileURLWithPath: fixture).appendingPathComponent("client_key")
            .bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let profile = SSHProfile(name: "Loopback upload test", host: "127.0.0.1", port: 49326,
                                 username: NSUserName(), authMethod: .privateKey, privateKeyBookmark: bookmark)
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let secondTarget = root.appendingPathComponent("target-after-move")
        for url in [source, target, secondTarget] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let tree = source.appendingPathComponent("文件夹")
        try fm.createDirectory(at: tree.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        try fm.createDirectory(at: tree.appendingPathComponent("空文件夹"), withIntermediateDirectories: true)
        let contents: [String: Data] = [
            "Finder 100% 中文.txt": Data("Finder native upload fixture\n".utf8),
            "文件夹/子目录/nested.txt": Data("nested file\n".utf8),
            "文件夹/empty.txt": Data(),
            "文件夹/multipart.bin": Data(repeating: 0x6D, count: 2 * 1_024 * 1_024 + 17)
        ]
        for (path, data) in contents { try data.write(to: source.appendingPathComponent(path)) }

        let tab = WorkspaceTabRuntime(sftp: profile)
        let sftp = try XCTUnwrap(tab.sftp)
        defer { tab.close() }
        sftp.connectIfNeeded()
        try await waitUntil { sftp.connectionState != .connecting }
        XCTAssertEqual(sftp.connectionState, .connected, sftp.errorMessage ?? "SSH connection failed")
        guard sftp.connectionState == .connected else { return }
        sftp.navigate(to: target.path)
        try await waitUntil { sftp.loadingPath == nil }
        XCTAssertEqual(sftp.currentPath, target.path)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = FinderUploadHostingView(rootView: Color.clear)
        window.contentView = host
        host.isActiveTarget = { true }
        host.uploadTarget = { tab.finderUploadTarget }
        host.performUpload = { urls, target, window in tab.uploadFromFinder(urls: urls, target: target, window: window, store: store) }
        let board = NSPasteboard(name: .init("com.snake.tests.\(UUID())"))
        defer { board.releaseGlobally(); window.close() }
        let singleFile = source.appendingPathComponent("Finder 100% 中文.txt")
        board.writeObjects([singleFile as NSURL, tree as NSURL])
        let info = TestDraggingInfo(window: window, board: board, location: NSPoint(x: 300, y: 250))
        let router = FinderUploadWindowRouter()
        XCTAssertEqual(router.draggingEntered(info), .copy)
        XCTAssertTrue(router.prepareForDragOperation(info))
        XCTAssertTrue(router.performDragOperation(info))
        // Navigation immediately after a drop cannot redirect an accepted batch.
        sftp.navigate(to: secondTarget.path)
        try await waitUntil { !sftp.uploader.isPreparing }
        XCTAssertNil(sftp.uploader.errorMessage)
        XCTAssertEqual(sftp.uploadRecords.count, contents.count)
        XCTAssertTrue(sftp.uploadRecords.allSatisfy { $0.state == .succeeded }, "\(sftp.uploadRecords.map(\.state))")
        for (path, data) in contents { XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(path)), data) }
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("文件夹/空文件夹").path))
        XCTAssertFalse(fm.fileExists(atPath: secondTarget.appendingPathComponent(singleFile.lastPathComponent).path))

        // Exercise the SFTP table's provider route as well as its native ancestor.
        // The directory is captured before asynchronous provider decoding.
        let tableFile = source.appendingPathComponent("SFTP 表格投放.txt")
        let tableData = Data("SFTP provider upload\n".utf8)
        try tableData.write(to: tableFile)
        let previousRecords = sftp.uploadRecords.count
        sftp.uploadFromFinder(providers: [NSItemProvider(item: tableFile as NSURL, typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue)], to: secondTarget.path, store: store)
        sftp.navigate(to: target.path)
        try await waitUntil { sftp.uploadRecords.count > previousRecords && !sftp.uploader.isPreparing }
        XCTAssertEqual(try Data(contentsOf: secondTarget.appendingPathComponent(tableFile.lastPathComponent)), tableData)
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent(tableFile.lastPathComponent).path))

        // Exercise the terminal runtime, actual OSC 7 updates, then reparent the
        // same native destination into a different window before uploading.
        let terminalTab = WorkspaceTabRuntime(terminal: profile)
        let terminal = try XCTUnwrap(terminalTab.terminal)
        defer { terminalTab.close() }
        let surface = terminal.terminalSurface()
        host.addSubview(surface)
        surface.frame = host.bounds
        terminal.startIfNeeded(surface)
        try await waitUntil { terminal.state != .connecting }
        XCTAssertEqual(terminal.state, .connected, terminal.errorMessage ?? "Terminal failed")
        guard terminal.state == .connected else { return }
        try await waitUntil { terminal.currentRemoteDirectory != nil }
        terminal.send(Data("cd '\(secondTarget.path)'\n".utf8))
        try await waitUntil { terminal.currentRemoteDirectory == secondTarget.path }
        let detached = NSWindow(contentRect: NSRect(x: 850, y: 100, width: 600, height: 450), styleMask: [.borderless], backing: .buffered, defer: false)
        detached.isReleasedWhenClosed = false
        defer { detached.close() }
        window.contentView = NSView()
        detached.contentView = host
        detached.setFrameOrigin(NSPoint(x: 300, y: 200))
        host.uploadTarget = { terminalTab.finderUploadTarget }
        host.performUpload = { urls, target, window in terminalTab.uploadFromFinder(urls: urls, target: target, window: window, store: store) }
        info.draggingDestinationWindow = detached
        info.draggingLocation = NSPoint(x: 300, y: 200)
        board.clearContents()
        board.writeObjects([singleFile as NSURL])
        XCTAssertTrue(router.performDragOperation(info))
        try await waitUntil { !terminal.uploader.isPreparing }
        XCTAssertNil(terminal.uploader.errorMessage)
        XCTAssertEqual(terminal.uploader.records.first?.state, .succeeded)
        XCTAssertEqual(try Data(contentsOf: secondTarget.appendingPathComponent(singleFile.lastPathComponent)), contents[singleFile.lastPathComponent])

        // Safe overwrite must keep the old destination until the user chooses.
        let replacement = Data("replacement through safe staging\n".utf8)
        try replacement.write(to: singleFile)
        XCTAssertTrue(router.performDragOperation(info))
        try await waitUntil { terminal.uploader.pendingConflict != nil || !terminal.uploader.isPreparing }
        XCTAssertNotNil(terminal.uploader.pendingConflict)
        XCTAssertEqual(try Data(contentsOf: secondTarget.appendingPathComponent(singleFile.lastPathComponent)), contents[singleFile.lastPathComponent])
        terminal.uploader.resolveConflict(.overwrite)
        try await waitUntil { !terminal.uploader.isPreparing }
        XCTAssertEqual(terminal.uploader.records.first?.state, .succeeded)
        XCTAssertEqual(try Data(contentsOf: secondTarget.appendingPathComponent(singleFile.lastPathComponent)), replacement)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: secondTarget.path).contains { $0.hasPrefix(".snake-upload-") })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Local SSH fixture did not reach expected state within 25 seconds")
                throw CocoaError(.userCancelled)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@MainActor
private final class TestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(window: NSWindow, board: NSPasteboard, location: NSPoint) {
        draggingDestinationWindow = window
        draggingPasteboard = board
        draggingLocation = location
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
