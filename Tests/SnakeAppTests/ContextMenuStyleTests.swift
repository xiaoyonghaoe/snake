import AppKit
import SwiftUI
import XCTest
@testable import SnakeApp

/// The SwiftUI menus must render the way the terminal's AppKit menu does.
@MainActor
final class ContextMenuStyleTests: XCTestCase {
    private func menu<V: View>(for view: V) throws -> NSMenu {
        let host = NSHostingView(rootView: view.frame(width: 200, height: 200))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        var view: NSView? = host.hitTest(NSPoint(x: 100, y: 100))
        while let current = view {
            if let menu = current.menu(for: event) { return menu }
            view = current.superview
        }
        throw XCTSkip("SwiftUI did not expose the context menu")
    }

    func testSwiftUIMenusKeepIconsHeadingsAndDestructiveLast() throws {
        let menu = try menu(for: Color.gray.snakeContextMenu {
            Button("打开终端", systemImage: "terminal") {}
            Section("管理") {
                Button("编辑会话", systemImage: "pencil") {}
            }
            Divider()
            Button("删除会话", systemImage: "trash", role: .destructive) {}
        })
        let actions = menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }
        XCTAssertEqual(actions.count, 3)
        XCTAssertTrue(actions.allSatisfy { $0.image != nil }, "every item shows its icon")
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).count, 1)
        XCTAssertFalse(menu.items.first?.isSeparatorItem ?? true, "the menu starts with an action, not a line")
        XCTAssertEqual(actions.last?.title, "删除会话")
    }

    func testTerminalBuilderMarksDestructiveItemsRed() {
        let menu = NSMenu()
        final class Target: NSObject { @objc func run() {} }
        let target = Target()
        let build = SnakeMenuBuilder(menu: menu, target: target)
        build.item("复制", symbol: "doc.on.doc", action: #selector(Target.run))
        build.header("管理")
        build.item("删除", symbol: "trash", destructive: true, action: #selector(Target.run))
        XCTAssertEqual(menu.items.map(\.isSeparatorItem), [false, true, false, false])
        XCTAssertTrue(menu.items[2].isSectionHeader)
        let color = menu.items[3].attributedTitle?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, .systemRed)
    }
}
