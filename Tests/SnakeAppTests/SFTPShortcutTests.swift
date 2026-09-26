import AppKit
import XCTest
@testable import SnakeApp

@MainActor
final class SFTPShortcutTests: XCTestCase {
    func testKeyEventsUseCurrentConfigurationAndLeaveOtherShortcutsAlone() throws {
        var configured = Dictionary(uniqueKeysWithValues: SFTPShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        func event(_ key: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [.command]) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(SFTPShortcutPolicy.action(for: try event("f", code: 3), configured: configured), .search)
        XCTAssertEqual(SFTPShortcutPolicy.action(for: try event("\u{7f}", code: 51), configured: configured), .delete)
        XCTAssertEqual(SFTPShortcutPolicy.action(for: try event("u", code: 32), configured: configured), .uploadFile)
        XCTAssertNil(SFTPShortcutPolicy.action(for: try event("w", code: 13), configured: configured))
        XCTAssertNil(SFTPShortcutPolicy.action(for: try event("f", code: 3, modifiers: []), configured: configured))
        configured[.search] = SFTPShortcut(keyEquivalent: "g", modifiers: [.command, .shift])
        XCTAssertNil(SFTPShortcutPolicy.action(for: try event("f", code: 3), configured: configured))
        XCTAssertEqual(SFTPShortcutPolicy.action(for: try event("G", code: 5, modifiers: [.command, .shift, .capsLock]), configured: configured), .search)
    }

    func testCommandsReinstallAfterMainMenuRebuildAndUseUpdatedShortcut() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let suite = "snake-shortcut-menu-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            NSApp.mainMenu = previousMenu
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        let coordinator = WorkspaceWindowCoordinator(store: store)
        store.workspaceCoordinator = coordinator
        NSApp.mainMenu = NSMenu(title: "Test")
        coordinator.installApplicationCommands()
        let first = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        XCTAssertEqual(first.items.filter { $0.title == "在 SFTP 中检索" }.count, 1)
        let initialNewTab = try XCTUnwrap(first.items.first { $0.title == "新建 SSH 会话标签" })
        XCTAssertEqual(initialNewTab.keyEquivalent, "t")
        XCTAssertEqual(initialNewTab.keyEquivalentModifierMask, [.command])
        NSApp.mainMenu = NSMenu(title: "Rebuilt")
        let replacement = SFTPShortcut(keyEquivalent: "g", modifiers: [.command, .shift])
        XCTAssertNil(store.updateSFTPShortcut(.search, shortcut: replacement))
        let newTabShortcut = SFTPShortcut(keyEquivalent: "n", modifiers: [.command, .option])
        XCTAssertNil(store.updateNewSessionTabShortcut(newTabShortcut))
        coordinator.installApplicationCommands()
        let rebuilt = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        XCTAssertFalse(rebuilt === first)
        let search = try XCTUnwrap(rebuilt.items.first { $0.title == "在 SFTP 中检索" })
        XCTAssertEqual(rebuilt.items.filter { $0.title == search.title }.count, 1)
        XCTAssertEqual(search.keyEquivalent, "g")
        XCTAssertEqual(search.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(search.target === coordinator)
        let newTab = try XCTUnwrap(rebuilt.items.first { $0.title == "新建 SSH 会话标签" })
        XCTAssertEqual(newTab.keyEquivalent, "n")
        XCTAssertEqual(newTab.keyEquivalentModifierMask, [.command, .option])
        XCTAssertFalse(coordinator.validateMenuItem(search), "A non-workspace window must not run SFTP commands")
    }

    func testRecorderClickAcquiresFocusAndCapturesCommandKeyEquivalent() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let recorder = ShortcutRecorderField(frame: NSRect(x: 10, y: 10, width: 150, height: 28))
        window.contentView?.addSubview(recorder)
        var received: [SFTPShortcut] = []
        recorder.onRecord = { received.append($0) }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 15, y: 15),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        recorder.mouseDown(with: click)
        XCTAssertTrue(window.firstResponder === recorder, "Click must enter recording, not activate a text field editor")
        let command = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(recorder.performKeyEquivalent(with: command), "Recording must consume Command keys before application menus")
        XCTAssertEqual(received, [SFTPShortcutAction.search.defaultShortcut])
    }

    func testDefaultsLabelsAndPolicy() {
        XCTAssertEqual(WorkspaceShortcutPolicy.defaultNewTab.displayText, "⌘T")
        XCTAssertEqual(SFTPShortcutAction.search.defaultShortcut.displayText, "⌘F")
        XCTAssertEqual(SFTPShortcutAction.delete.defaultShortcut.displayText, "⌘⌫")
        XCTAssertEqual(SFTPShortcutAction.uploadFile.defaultShortcut.displayText, "⌘U")

        let defaults = Dictionary(uniqueKeysWithValues: SFTPShortcutAction.allCases.map { ($0, $0.defaultShortcut) })
        XCTAssertNotNil(SFTPShortcutPolicy.validationError(
            action: .search, shortcut: SFTPShortcut(keyEquivalent: "q", modifiers: [.command]), configured: defaults))
        XCTAssertNotNil(SFTPShortcutPolicy.validationError(
            action: .search, shortcut: SFTPShortcut(keyEquivalent: "u", modifiers: [.command]), configured: defaults))
        XCTAssertNotNil(SFTPShortcutPolicy.validationError(
            action: .search, shortcut: SFTPShortcut(keyEquivalent: "f", modifiers: [.shift]), configured: defaults))
        XCTAssertNil(SFTPShortcutPolicy.validationError(
            action: .search, shortcut: SFTPShortcut(keyEquivalent: "g", modifiers: [.control, .option]), configured: defaults))
        XCTAssertNotNil(SFTPShortcutPolicy.validationError(action: .search,
            shortcut: WorkspaceShortcutPolicy.defaultNewTab, configured: defaults))
        XCTAssertNotNil(WorkspaceShortcutPolicy.validationError(
            SFTPShortcutAction.uploadFile.defaultShortcut, sftpShortcuts: defaults))
    }

    func testStorePersistsValidShortcutsAndRejectsConflicts() throws {
        let suite = "snake-sftp-shortcut-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let database = directory.appendingPathComponent("test.sqlite3")
        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        let replacement = SFTPShortcut(keyEquivalent: "g", modifiers: [.control, .option])
        XCTAssertNil(store.updateSFTPShortcut(.search, shortcut: replacement))
        XCTAssertEqual(store.sftpSearchShortcut, replacement)
        XCTAssertNotNil(store.updateSFTPShortcut(.delete, shortcut: replacement))
        XCTAssertEqual(store.sftpDeleteShortcut, SFTPShortcutAction.delete.defaultShortcut)
        let newTab = SFTPShortcut(keyEquivalent: "n", modifiers: [.command, .option])
        XCTAssertNil(store.updateNewSessionTabShortcut(newTab))
        XCTAssertEqual(ApplicationStore(databaseURL: database, userDefaults: defaults).newSessionTabShortcut, newTab)
        XCTAssertNotNil(store.updateNewSessionTabShortcut(store.sftpUploadShortcut))

        let restored = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(restored.sftpSearchShortcut, replacement)
        restored.resetSFTPShortcuts()
        XCTAssertEqual(restored.sftpSearchShortcut, SFTPShortcutAction.search.defaultShortcut)
        restored.resetAllShortcuts()
        XCTAssertEqual(restored.newSessionTabShortcut, WorkspaceShortcutPolicy.defaultNewTab)

        let unsafe = SFTPShortcut(keyEquivalent: "x", modifiers: [.shift])
        defaults.set(try JSONEncoder().encode(unsafe), forKey: "com.snake.shortcuts.sftp-search")
        XCTAssertEqual(ApplicationStore(databaseURL: database, userDefaults: defaults).sftpSearchShortcut,
                       SFTPShortcutAction.search.defaultShortcut)
    }

    func testRuntimeCommandRequestsAreExplicitAndCapabilityAware() {
        let runtime = SFTPRuntime(profile: SSHProfile(name: "offline", host: "127.0.0.1", username: "test"))
        XCTAssertFalse(runtime.canSearchWithShortcut)
        XCTAssertFalse(runtime.canDeleteWithShortcut)
        XCTAssertFalse(runtime.canUploadFileWithShortcut)
        XCTAssertEqual(runtime.searchCommandRequest, 0)
        XCTAssertEqual(runtime.deleteCommandRequest, 0)
        XCTAssertEqual(runtime.uploadFileCommandRequest, 0)
        runtime.requestSearchCommand()
        runtime.requestDeleteCommand()
        runtime.requestUploadFileCommand()
        XCTAssertEqual(runtime.searchCommandRequest, 1)
        XCTAssertEqual(runtime.deleteCommandRequest, 1)
        XCTAssertEqual(runtime.uploadFileCommandRequest, 1)
    }

    func testWorkspaceWindowRoutesConfiguredShortcutToItsSelectedSFTP() throws {
        _ = NSApplication.shared
        let suite = "snake-window-shortcut-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        let coordinator = WorkspaceWindowCoordinator(store: store)
        let state = WorkspaceWindowState()
        let runtime = WorkspaceTabRuntime(sftp: SSHProfile(name: "test", host: "127.0.0.1", username: "test"))
        XCTAssertTrue(state.add(runtime))
        let window = SnakeWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        coordinator.register(window: window, state: state)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let upload = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "u", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32))
        XCTAssertTrue(window.performKeyEquivalent(with: upload))
        XCTAssertNotNil(runtime.sftp?.shortcutNotice, "An unconnected SFTP must show why upload cannot start")
        XCTAssertEqual(runtime.sftp?.uploadFileCommandRequest, 0)
        let search = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(window.performKeyEquivalent(with: search))
        XCTAssertEqual(runtime.sftp?.searchCommandRequest, 0)
        let oldShortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        XCTAssertFalse(coordinator.handleNewSessionTabShortcut(oldShortcut, in: window))
        let initialCount = state.bonsplit.allTabIds.count
        let newTab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        XCTAssertTrue(window.performKeyEquivalent(with: newTab))
        XCTAssertEqual(state.bonsplit.allTabIds.count, initialCount + 1)
        XCTAssertEqual(state.selectedRuntime?.kind, .sessions)
        XCTAssertEqual(state.selectedRuntime?.searchFocusRequest, 1)
        XCTAssertNil(store.updateNewSessionTabShortcut(
            SFTPShortcut(keyEquivalent: "n", modifiers: [.command, .option])))
        XCTAssertFalse(coordinator.handleNewSessionTabShortcut(newTab, in: window))
        let customized = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        XCTAssertTrue(window.performKeyEquivalent(with: customized))
        XCTAssertEqual(state.bonsplit.allTabIds.count, initialCount + 2)
        XCTAssertEqual(state.selectedRuntime?.searchFocusRequest, 1)
        let repeatEvent = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .option], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: true, keyCode: 45))
        XCTAssertTrue(window.performKeyEquivalent(with: repeatEvent))
        XCTAssertEqual(state.bonsplit.allTabIds.count, initialCount + 2)
    }
}
