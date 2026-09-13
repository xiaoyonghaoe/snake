import AppKit
import Bonsplit
import SwiftUI
import XCTest
@testable import SnakeApp

@MainActor
final class WorkspaceDraggingTests: XCTestCase {
    func testCommandWStillClosesOnlySelectedTabAfterSettingsRebuildsMenu() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let (window, state) = fixture.window()
        state.openManager(.sessions)
        state.openManager(.sessions)
        let left = try XCTUnwrap(state.activePaneID)
        let right = try XCTUnwrap(state.splitFocusedPane(.horizontal))
        state.openManager(.mounts)
        let rightRuntime = state.selectedRuntime
        state.bonsplit.focusPane(left)
        let closing = try XCTUnwrap(state.selectedRuntime)

        // Reproduce a Settings menu rebuild exposing native Close Window again.
        let menu = NSMenu(title: "Settings")
        let item = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        item.keyEquivalentModifierMask = [.command]
        item.target = window
        menu.addItem(item)
        NSApp.mainMenu = menu
        let event = try commandW(in: window)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertFalse(state.tabs.values.contains { $0 === closing })
        XCTAssertTrue(state.tabs.values.contains { $0 === rightRuntime })
        XCTAssertTrue(fixture.owner.workspaceState(for: window) === state, "The workspace window must remain registered")

        state.bonsplit.focusPane(right)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertTrue(window.performKeyEquivalent(with: event), "An empty workspace still consumes Command-W")
        XCTAssertEqual(state.bonsplit.allPaneIds.count, 1)
        XCTAssertTrue(fixture.owner.workspaceState(for: window) === state)
    }

    func testWorkspaceCloseShortcutIgnoresRepeatAndDoesNotCloseOtherWindow() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (firstWindow, first) = fixture.window()
        let (_, second) = fixture.window()
        first.openManager(.sessions)
        second.openManager(.sessions)
        XCTAssertTrue(firstWindow.performKeyEquivalent(with: try commandW(in: firstWindow, repeated: true)))
        XCTAssertEqual(first.tabs.count, 1)
        XCTAssertTrue(firstWindow.performKeyEquivalent(with: try commandW(in: firstWindow)))
        XCTAssertTrue(first.tabs.isEmpty)
        XCTAssertEqual(second.tabs.count, 1)
    }

    private func commandW(in window: NSWindow, repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: repeated, keyCode: 13))
    }

    func testTrailingDoubleClickCreatesOneChooserInClickedPane() throws {
        let state = WorkspaceWindowState()
        state.openManager(.mounts)
        let left = try XCTUnwrap(state.activePaneID)
        let right = try XCTUnwrap(state.splitFocusedPane(.horizontal))
        state.bonsplit.focusPane(left)
        state.bonsplit.onTabBarTrailingDoubleClick?(right)
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.bonsplit.tabs(inPane: left).count, 1)
        XCTAssertEqual(state.bonsplit.tabs(inPane: right).count, 1)
        XCTAssertEqual(state.selectedRuntime?.kind, .sessions)
        XCTAssertEqual(state.activePaneID, right)
        state.bonsplit.onTabBarTrailingDoubleClick?(right)
        XCTAssertEqual(state.tabs.count, 3)
        XCTAssertEqual(state.bonsplit.tabs(inPane: right).count, 2)
        state.closeCurrentItem()
        state.closeCurrentItem()
        // The right pane has been removed; a stale callback must not open elsewhere.
        state.bonsplit.onTabBarTrailingDoubleClick?(right)
        XCTAssertEqual(state.tabs.count, 1)
    }

    func testEmptyLastPaneCanOpenChooserByDoubleClick() throws {
        let state = WorkspaceWindowState()
        let pane = try XCTUnwrap(state.activePaneID)
        state.bonsplit.onTabBarTrailingDoubleClick?(pane)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.selectedRuntime?.kind, .sessions)
    }

    func testAppearanceDefaultsToLightAndRestoresLastChoice() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        XCTAssertFalse(fixture.store.isDarkAppearancePreferred)
        fixture.store.isDarkAppearancePreferred = true
        let restored = ApplicationStore(databaseURL: fixture.root.appendingPathComponent("appearance.sqlite3"), userDefaults: fixture.defaults)
        XCTAssertTrue(restored.isDarkAppearancePreferred)
        restored.isDarkAppearancePreferred = false
        let light = ApplicationStore(databaseURL: fixture.root.appendingPathComponent("appearance-light.sqlite3"), userDefaults: fixture.defaults)
        XCTAssertFalse(light.isDarkAppearancePreferred)
    }

    func testChooserConversionPreservesIdentityAndRejectsSecondConnection() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, state) = fixture.window()
        for asSFTP in [true, false] {
            state.openManager(.sessions)
            let pane = try XCTUnwrap(state.activePaneID)
            let tabID = try XCTUnwrap(state.bonsplit.selectedTab(inPane: pane)?.id)
            let runtime = try XCTUnwrap(state.tabs[tabID])
            let identity = runtime.id
            let order = state.bonsplit.tabs(inPane: pane).map(\.id)
            XCTAssertTrue(state.connectChooser(tabID: tabID, profileID: fixture.profile.id, asSFTP: asSFTP, store: fixture.store))
            XCTAssertTrue(state.tabs[tabID] === runtime)
            XCTAssertEqual(runtime.id, identity)
            XCTAssertEqual(state.bonsplit.tabs(inPane: pane).map(\.id), order)
            XCTAssertEqual(runtime.kind, asSFTP ? .sftp(profileID: fixture.profile.id) : .terminal(profileID: fixture.profile.id))
            XCTAssertEqual(state.bonsplit.selectedTab(inPane: pane)?.title, runtime.title)
            XCTAssertFalse(state.connectChooser(tabID: tabID, profileID: fixture.profile.id, asSFTP: !asSFTP, store: fixture.store))
        }
    }

    func testChooserConversionTargetsIDNotFocusedPaneAndRejectsMissingProfile() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, state) = fixture.window()
        state.openManager(.sessions)
        let left = try XCTUnwrap(state.activePaneID)
        let tab = try XCTUnwrap(state.bonsplit.selectedTab(inPane: left)?.id)
        let right = try XCTUnwrap(state.splitFocusedPane(.horizontal))
        state.openManager(.sessions)
        let rightRuntime = try XCTUnwrap(state.selectedRuntime)
        XCTAssertFalse(state.connectChooser(tabID: tab, profileID: UUID(), asSFTP: true, store: fixture.store))
        XCTAssertEqual(state.tabs[tab]?.kind, .sessions)
        XCTAssertTrue(state.connectChooser(tabID: tab, profileID: fixture.profile.id, asSFTP: true, store: fixture.store))
        XCTAssertEqual(rightRuntime.kind, .sessions)
        XCTAssertEqual(state.bonsplit.tabs(inPane: right).count, 1)
        XCTAssertEqual(state.tabs.count, 2)
    }

    func testManagerTabsKeepStateAcrossWindowsAndNeverHoldConnections() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, source) = fixture.window()
        let (_, target) = fixture.window()
        source.openManager(.sessions)
        let runtime = try XCTUnwrap(source.selectedRuntime)
        runtime.searchQuery = "production"
        runtime.selectedTags = ["prod"]
        let tab = try XCTUnwrap(source.bonsplit.allTabIds.first)
        let pane = try XCTUnwrap(target.activePaneID)
        XCTAssertTrue(fixture.owner.commitWorkspaceDrop(.tab(windowID: source.id, tabID: tab), target: .init(windowID: target.id, paneID: pane, placement: .center, previewRect: .zero), openSFTP: false))
        XCTAssertTrue(target.selectedRuntime === runtime)
        XCTAssertEqual(runtime.searchQuery, "production")
        XCTAssertEqual(runtime.selectedTags, ["prod"])
        XCTAssertNil(runtime.profile)
        XCTAssertNil(runtime.terminal)
        XCTAssertNil(runtime.sftp)
        target.openManager(.mounts)
        target.openManager(.mounts)
        XCTAssertEqual(target.tabs.count, 3)
        XCTAssertEqual(target.tabs.values.filter { $0.kind == .mounts }.count, 2)
        target.closeTabs(profileID: fixture.profile.id)
        XCTAssertEqual(target.tabs.count, 3)
    }

    func testSearchCreatesChooserOnlyWhenNeededAndFiltersAreIndependent() throws {
        let state = WorkspaceWindowState()
        state.openManager(.mounts)
        state.focusSessionSearch()
        let first = try XCTUnwrap(state.selectedRuntime)
        XCTAssertEqual(first.kind, .sessions)
        XCTAssertEqual(first.searchFocusRequest, 1)
        state.focusSessionSearch()
        XCTAssertEqual(first.searchFocusRequest, 2)
        XCTAssertEqual(state.tabs.count, 2)
        first.searchQuery = "one"
        first.selectedTags = ["prod"]
        state.openManager(.sessions)
        XCTAssertEqual(state.selectedRuntime?.searchQuery, "")
        XCTAssertEqual(state.selectedRuntime?.selectedTags, [])
        while state.canCloseCurrentItem { XCTAssertTrue(state.closeCurrentItem()) }
        XCTAssertTrue(state.tabs.isEmpty)
        XCTAssertEqual(state.bonsplit.allPaneIds.count, 1)
        XCTAssertFalse(state.closeCurrentItem())
    }

    func testHostingUpdatesKeepNativeDragTypesRegistered() {
        let host = WorkspaceHostingView(rootView: Text("workspace"))
        host.registerForDraggedTypes([.string])
        XCTAssertTrue(Set(host.registeredDraggedTypes).isSuperset(of: Set(WorkspaceDragPayload.types + [.fileURL, .string])))
        host.registerForDraggedTypes([])
        XCTAssertTrue(Set(host.registeredDraggedTypes).isSuperset(of: Set(WorkspaceDragPayload.types + [.fileURL])))
    }

    func testPopulatedPaneCenterRejectsDropAndTabBarInsertionReorders() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, state) = fixture.window()
        for _ in 0..<3 { state.add(WorkspaceTabRuntime(sftp: fixture.profile)) }
        let pane = try XCTUnwrap(state.bonsplit.focusedPaneId)
        let ids = state.bonsplit.tabs(inPane: pane).map(\.id)
        let source = WorkspaceDragSource.tab(windowID: state.id, tabID: ids[0])
        XCTAssertFalse(fixture.owner.commitWorkspaceDrop(source, target: .init(windowID: state.id, paneID: pane, placement: .center, previewRect: .zero), openSFTP: false))
        XCTAssertEqual(state.bonsplit.tabs(inPane: pane).map(\.id), ids)
        XCTAssertTrue(fixture.owner.commitWorkspaceDrop(source, target: .init(windowID: state.id, paneID: pane, placement: .insert(3), previewRect: .zero), openSFTP: false))
        XCTAssertEqual(state.bonsplit.tabs(inPane: pane).map(\.id), [ids[1], ids[2], ids[0]])
    }

    func testPayloadIsolationAndTransactionCancellation() throws {
        let source = WorkspaceDragSource.profile(UUID())
        let payload = WorkspaceDragPayload(transactionID: UUID(), source: source)
        let board = NSPasteboard(name: .init("com.snake.tests.drag.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setData(try JSONEncoder().encode(payload), forType: source.pasteboardType)
        XCTAssertTrue(payload.matches(board))
        XCTAssertFalse(WorkspaceDragPayload(transactionID: UUID(), source: source).matches(board))
        board.setString("file:///tmp/probe", forType: .fileURL)
        XCTAssertFalse(payload.matches(board))
        XCTAssertFalse(FinderUploadPasteboard.accepts(board))
        var cancelled = WorkspaceDragTransaction(payload: payload)
        cancelled.cancel()
        var calls = 0
        XCTAssertFalse(cancelled.commit { calls += 1; return true })
        XCTAssertEqual(calls, 0)
        var committed = WorkspaceDragTransaction(payload: payload)
        XCTAssertTrue(committed.commit { calls += 1; return true })
        XCTAssertFalse(committed.commit { calls += 1; return true })
        XCTAssertEqual(calls, 1)
    }

    func testFourEdgesAndEmptyPaneGeometry() {
        let rect = NSRect(x: 200, y: 50, width: 700, height: 450)
        let cases: [(NSPoint, WorkspaceDropEdge)] = [
            (.init(x: 210, y: 250), .left), (.init(x: 890, y: 250), .right),
            (.init(x: 500, y: 490), .top), (.init(x: 500, y: 60), .bottom)
        ]
        for (point, edge) in cases {
            XCTAssertEqual(WorkspaceDropGeometry.placement(at: point, in: rect, empty: false), .split(edge))
            XCTAssertEqual(WorkspaceDropGeometry.placement(at: point, in: rect, empty: true), .center)
        }
        // Each direction is reachable well before the window resize edge.
        XCTAssertEqual(WorkspaceDropGeometry.placement(at: .init(x: 360, y: 250), in: rect, empty: false), .split(.left))
        XCTAssertEqual(WorkspaceDropGeometry.placement(at: .init(x: 740, y: 250), in: rect, empty: false), .split(.right))
        XCTAssertEqual(WorkspaceDropGeometry.placement(at: .init(x: 500, y: 370), in: rect, empty: false), .split(.top))
        XCTAssertEqual(WorkspaceDropGeometry.placement(at: .init(x: 500, y: 180), in: rect, empty: false), .split(.bottom))
        XCTAssertEqual(WorkspaceDropGeometry.placement(at: .init(x: 800, y: 65), in: rect, empty: false), .split(.bottom))
        XCTAssertNil(WorkspaceDropGeometry.placement(at: .init(x: 950, y: 250), in: rect, empty: false))
        XCTAssertNil(WorkspaceDropGeometry.placement(at: .init(x: 500, y: 250), in: rect, empty: false))
    }

    func testGeometryUsesHoveredPaneAndTabMidpointsNotFocusedPane() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (window, state) = fixture.window()
        let left = try XCTUnwrap(state.bonsplit.focusedPaneId)
        let right = try XCTUnwrap(state.splitFocusedPane(.horizontal))
        state.add(WorkspaceTabRuntime(sftp: fixture.profile), to: right)
        state.add(WorkspaceTabRuntime(sftp: fixture.profile), to: right)
        state.bonsplit.focusPane(left)
        let root = try XCTUnwrap(window.contentView)
        func marker(_ pane: PaneID, _ kind: BonsplitDragRegionKind, _ frame: NSRect) {
            let view = BonsplitDragRegionView(paneID: pane, kind: kind)
            root.addSubview(view); view.frame = frame
        }
        marker(left, .content, NSRect(x: 180, y: 0, width: 350, height: 450))
        marker(right, .content, NSRect(x: 530, y: 0, width: 470, height: 450))
        marker(right, .tabBar, NSRect(x: 530, y: 450, width: 470, height: 34))
        let tabs = state.bonsplit.tabs(inPane: right)
        marker(right, .tab(tabs[0].id), NSRect(x: 530, y: 450, width: 160, height: 34))
        marker(right, .tab(tabs[1].id), NSRect(x: 690, y: 450, width: 160, height: 34))
        XCTAssertNil(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 750, y: 200)))
        let target = try XCTUnwrap(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 960, y: 200)))
        XCTAssertEqual(target.paneID, right)
        XCTAssertEqual(target.placement, .split(.right))
        XCTAssertEqual(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 715, y: 460))?.placement, .insert(1))
        XCTAssertEqual(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 810, y: 460))?.placement, .insert(2))
        XCTAssertNil(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 80, y: 200)))
        XCTAssertNil(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 750, y: 520)))
        window.setFrameOrigin(NSPoint(x: 800, y: 300))
        XCTAssertEqual(WorkspaceDropGeometry.target(in: window, state: state, at: .init(x: 960, y: 200)), target)
        // Resize the same live marker. The same pointer location must be
        // classified from its new width/height, not a cached drag-start rect.
        let content = try XCTUnwrap(WorkspaceDropGeometry.views(BonsplitDragRegionView.self, in: root).first { $0.paneID == right && $0.kind == .content })
        let pointer = NSPoint(x: 960, y: 300)
        XCTAssertEqual(WorkspaceDropGeometry.target(in: window, state: state, at: pointer)?.placement, .split(.right))
        window.setContentSize(NSSize(width: 1600, height: 1000))
        content.frame.size.width = 940
        XCTAssertEqual(WorkspaceDropGeometry.target(in: window, state: state, at: pointer)?.placement, .split(.top))
        content.frame.size.height = 900
        let resized = try XCTUnwrap(WorkspaceDropGeometry.target(in: window, state: state, at: pointer))
        XCTAssertEqual(resized.placement, .split(.bottom))
        XCTAssertEqual(resized.previewRect.height, 444)
    }

    func testCrossWindowMoveKeepsTerminalAndSFTPInstancesAndInsertionSlot() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, source) = fixture.window()
        let (_, target) = fixture.window()
        let terminalTab = WorkspaceTabRuntime(terminal: fixture.profile)
        let terminal = try XCTUnwrap(terminalTab.terminal)
        let surface = terminal.terminalSurface()
        terminal.updateRemoteDirectory("/tmp/current")
        let fileTab = WorkspaceTabRuntime(sftp: fixture.profile)
        fileTab.sftp?.currentPath = "/srv/releases"
        source.add(terminalTab); source.add(fileTab)
        target.add(WorkspaceTabRuntime(sftp: fixture.profile))
        target.add(WorkspaceTabRuntime(sftp: fixture.profile))
        let originalIDs = target.bonsplit.allTabIds
        let pane = try XCTUnwrap(target.bonsplit.focusedPaneId)
        for runtime in [terminalTab, fileTab] {
            let id = try XCTUnwrap(source.tabs.first { $0.value === runtime }?.key)
            XCTAssertTrue(fixture.owner.commitWorkspaceDrop(.tab(windowID: source.id, tabID: id), target: .init(windowID: target.id, paneID: pane, placement: .insert(1), previewRect: .zero), openSFTP: false))
            XCTAssertNil(source.tabs[id])
            let inserted = target.bonsplit.tabs(inPane: pane)[1].id
            XCTAssertTrue(target.tabs[inserted] === runtime)
        }
        XCTAssertTrue(terminal.terminalSurface() === surface)
        XCTAssertEqual(terminal.currentRemoteDirectory, "/tmp/current")
        XCTAssertEqual(fileTab.sftp?.currentPath, "/srv/releases")
        XCTAssertEqual(target.bonsplit.tabs(inPane: pane).first?.id, originalIDs.first)
        XCTAssertEqual(target.bonsplit.tabs(inPane: pane).last?.id, originalIDs.last)
    }

    func testSidebarDefaultAndOptionCreateDifferentNewRuntimes() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, target) = fixture.window()
        let pane = try XCTUnwrap(target.bonsplit.focusedPaneId)
        let emptyDrop = WorkspaceDropTarget(windowID: target.id, paneID: pane, placement: .center, previewRect: .zero)
        XCTAssertTrue(fixture.owner.commitWorkspaceDrop(.profile(fixture.profile.id), target: emptyDrop, openSFTP: false))
        XCTAssertNotNil(target.selectedRuntime?.terminal)
        let first = target.selectedRuntime
        let tabBarDrop = WorkspaceDropTarget(windowID: target.id, paneID: pane, placement: .insert(1), previewRect: .zero)
        XCTAssertTrue(fixture.owner.commitWorkspaceDrop(.profile(fixture.profile.id), target: tabBarDrop, openSFTP: true))
        XCTAssertNotNil(target.selectedRuntime?.sftp)
        XCTAssertFalse(target.selectedRuntime === first)
        XCTAssertEqual(target.tabs.count, 2)
        XCTAssertFalse(fixture.owner.commitWorkspaceDrop(.profile(UUID()), target: tabBarDrop, openSFTP: false))
        XCTAssertEqual(target.tabs.count, 2)
    }

    func testEverySplitDirectionPreservesRuntimeAndAllowsAnEmptySourcePane() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        for edge in WorkspaceDropEdge.allCases {
            let (_, state) = fixture.window()
            let runtime = WorkspaceTabRuntime(sftp: fixture.profile)
            state.add(runtime)
            let pane = try XCTUnwrap(state.bonsplit.focusedPaneId)
            let tab = try XCTUnwrap(state.bonsplit.allTabIds.first)
            XCTAssertTrue(fixture.owner.commitWorkspaceDrop(.tab(windowID: state.id, tabID: tab), target: .init(windowID: state.id, paneID: pane, placement: .split(edge), previewRect: .zero), openSFTP: false))
            XCTAssertEqual(state.bonsplit.allPaneIds.count, 2)
            XCTAssertTrue(state.tabs[tab] === runtime)
            XCTAssertTrue(state.bonsplit.tabs(inPane: pane).isEmpty)
            let newPane = edge.insertFirst ? state.bonsplit.allPaneIds.first : state.bonsplit.allPaneIds.last
            XCTAssertEqual(state.bonsplit.selectedTab(inPane: try XCTUnwrap(newPane))?.id, tab)
        }
    }

    func testRejectedTargetRollsBackSplitAndLeavesSourceUntouched() throws {
        let fixture = try DragFixture()
        defer { fixture.cleanUp() }
        let (_, source) = fixture.window()
        let (_, target) = fixture.window()
        let runtime = WorkspaceTabRuntime(sftp: fixture.profile)
        source.add(runtime)
        let tab = try XCTUnwrap(source.bonsplit.allTabIds.first)
        let pane = try XCTUnwrap(target.bonsplit.focusedPaneId)
        let veto = RejectCreationDelegate()
        target.bonsplit.delegate = veto
        let drop = WorkspaceDropTarget(windowID: target.id, paneID: pane, placement: .split(.left), previewRect: .zero)
        XCTAssertFalse(fixture.owner.commitWorkspaceDrop(.tab(windowID: source.id, tabID: tab), target: drop, openSFTP: false))
        XCTAssertTrue(source.tabs[tab] === runtime)
        XCTAssertEqual(target.bonsplit.allPaneIds, [pane])
        XCTAssertTrue(target.tabs.isEmpty)
    }
}

private final class RejectCreationDelegate: BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool { false }
}

@MainActor
private final class DragFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let store: ApplicationStore
    let owner: WorkspaceWindowCoordinator
    let profile = SSHProfile(name: "same name", host: "localhost", username: "test")
    var windows: [(NSWindow, WorkspaceWindowState)] = []
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-drag-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "com.snake.tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        owner = WorkspaceWindowCoordinator(store: store)
        try store.save(profile: profile)
    }
    func window() -> (NSWindow, WorkspaceWindowState) {
        let window = SnakeWorkspaceWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 550), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 550))
        let state = WorkspaceWindowState()
        owner.register(window: window, state: state)
        windows.append((window, state))
        return (window, state)
    }
    func cleanUp() {
        for (window, state) in windows { state.tabs.values.forEach { $0.close() }; window.close() }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
