import AppKit
import SwiftUI
import XCTest
@testable import SnakeApp

/// Bonsplit renders every tab of a pane at once (`keepAllAlive`), so an unselected
/// SFTP tab stays in the view hierarchy with the same frame as the visible one. These
/// tests pin the two guards that keep a Finder drop from being delivered to it:
/// ancestor-transparency visibility, and drop registration following the selection.
@MainActor
final class FinderDropRoutingTests: XCTestCase {
    // MARK: - Visibility

    func testTransparentAncestorCountsAsNotDrawn() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let wrapper = NSView(frame: root.bounds)
        let leaf = NSView(frame: root.bounds)
        root.addSubview(wrapper)
        wrapper.addSubview(leaf)

        XCTAssertTrue(FinderDropVisibility.isDrawn(leaf))

        // SwiftUI hides unselected tab content with `.opacity(0)` on an ancestor; the
        // leaf itself keeps alphaValue == 1, so isHiddenOrHasHiddenAncestor misses it.
        wrapper.alphaValue = 0
        XCTAssertFalse(leaf.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(FinderDropVisibility.isDrawn(leaf))

        wrapper.alphaValue = 1
        leaf.isHidden = true
        XCTAssertFalse(FinderDropVisibility.isDrawn(leaf))

        leaf.isHidden = false
        leaf.frame = .zero
        XCTAssertFalse(FinderDropVisibility.isDrawn(leaf), "零尺寸视图不参与拖拽")
    }

    // MARK: - Window router

    func testRouterSkipsACandidateHiddenByAncestorTransparency() {
        let (container, _) = makeContainer()

        let visible = FakeDropDestination(frame: container.bounds)
        let hiddenWrapper = NSView(frame: container.bounds)
        let hidden = FakeDropDestination(frame: container.bounds)
        hiddenWrapper.alphaValue = 0
        hiddenWrapper.addSubview(hidden)

        // Later subviews are inspected first, so the hidden candidate is in front of
        // the visible one in the walk order.
        container.addSubview(visible)
        container.addSubview(hiddenWrapper)
        container.layoutSubtreeIfNeeded()

        let picked = FinderUploadWindowRouter.destination(in: container, at: NSPoint(x: 50, y: 50))
        XCTAssertTrue(picked?.destinationView === visible, "隐藏标签的落点必须被跳过")
    }

    func testRouterPrefersTheFrontmostVisibleCandidate() {
        let (container, _) = makeContainer()

        let back = FakeDropDestination(frame: container.bounds)
        let front = FakeDropDestination(frame: container.bounds)
        container.addSubview(back)
        container.addSubview(front)
        container.layoutSubtreeIfNeeded()

        let picked = FinderUploadWindowRouter.destination(in: container, at: NSPoint(x: 50, y: 50))
        XCTAssertTrue(picked?.destinationView === front)
    }

    func testRouterIgnoresUnavailableCandidates() {
        let (container, _) = makeContainer()

        let unavailable = FakeDropDestination(frame: container.bounds)
        unavailable.available = false
        container.addSubview(unavailable)
        container.layoutSubtreeIfNeeded()

        XCTAssertNil(FinderUploadWindowRouter.destination(in: container, at: NSPoint(x: 50, y: 50)))
    }

    func testRouterIgnoresPointsOutsideTheRoot() {
        let (container, _) = makeContainer()

        let candidate = FakeDropDestination(frame: container.bounds)
        container.addSubview(candidate)
        container.layoutSubtreeIfNeeded()

        XCTAssertNil(FinderUploadWindowRouter.destination(in: container, at: NSPoint(x: 500, y: 500)))
    }

    // MARK: - Two tab contents alive at once (the reported regression)

    /// Mirrors Bonsplit's `keepAllAlive`: both tab contents are rendered and the
    /// unselected one is only hidden with `.opacity(0)`.
    func testRouterPicksTheSelectedTabWhenBothTabContentsAreAlive() {
        let firstSelected = makeAliveTabHost(firstSelected: true)
        defer { firstSelected.window.orderOut(nil) }
        let surfaces = collectDestinations(in: firstSelected.host)
        XCTAssertEqual(surfaces.count, 2, "两个标签的内容同时存活")

        let picked = FinderUploadWindowRouter.destination(in: firstSelected.host, at: NSPoint(x: 50, y: 50))
        XCTAssertTrue(picked?.isAvailableTarget == true)
        XCTAssertTrue(surfaces.contains { $0.destinationView === picked?.destinationView })

        // The tab that is not on screen must be unusable, whichever one the walk reaches first.
        let hidden = surfaces.first { $0.destinationView !== picked?.destinationView }
        XCTAssertNotNil(hidden)
        XCTAssertFalse(hidden!.isAvailableTarget, "隐藏标签不得接受访达拖拽")

        // The other selection must route the drop to the other tab.
        let secondSelected = makeAliveTabHost(firstSelected: false)
        defer { secondSelected.window.orderOut(nil) }
        let pickedSecond = FinderUploadWindowRouter.destination(in: secondSelected.host, at: NSPoint(x: 50, y: 50))
        XCTAssertTrue(pickedSecond?.isAvailableTarget == true)
        XCTAssertTrue(
            collectDestinations(in: secondSelected.host).contains { $0.destinationView === pickedSecond?.destinationView }
        )
        XCTAssertNotEqual(
            ObjectIdentifier(picked!.destinationView),
            ObjectIdentifier(pickedSecond!.destinationView),
            "切换标签后落点必须随之切换"
        )
    }

    /// Builds two always-alive tab surfaces, one of them hidden with `.opacity(0)`.
    private func makeAliveTabHost(firstSelected: Bool) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        _ = NSApplication.shared
        let root = AnyView(
            ZStack {
                FinderUploadSurface(
                    content: Text("first"),
                    runtimeID: WorkspaceTabID(),
                    isActive: { firstSelected },
                    target: { .directory("/first") },
                    perform: { _, _, _ in },
                    identity: "first"
                )
                .opacity(firstSelected ? 1 : 0)
                .allowsHitTesting(firstSelected)

                FinderUploadSurface(
                    content: Text("second"),
                    runtimeID: WorkspaceTabID(),
                    isActive: { !firstSelected },
                    target: { .directory("/second") },
                    perform: { _, _, _ in },
                    identity: "second"
                )
                .opacity(firstSelected ? 0 : 1)
                .allowsHitTesting(!firstSelected)
            }
        )
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func collectDestinations(in root: NSView) -> [any FinderUploadDestination] {        var result: [any FinderUploadDestination] = []
        if let destination = root as? any FinderUploadDestination { result.append(destination) }
        for child in root.subviews { result.append(contentsOf: collectDestinations(in: child)) }
        return result
    }

    // MARK: - Registration

    func testDropRegistrationFollowsTheSelection() {
        let view = FinderUploadHostingView(rootView: Text("probe"))
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))

        view.setDropEnabled(false)
        XCTAssertFalse(view.registeredDraggedTypes.contains(.fileURL), "非选中标签不能作为 AppKit 拖拽目的地")

        view.setDropEnabled(true)
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
    }

    func testUnavailableTargetsAreRejectedByTheSurface() {
        let view = FinderUploadHostingView(rootView: Text("probe"))
        view.isActiveTarget = { false }
        XCTAssertFalse(view.isAvailableTarget)

        view.isActiveTarget = { true }
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.frame = wrapper.bounds
        wrapper.addSubview(view)
        XCTAssertTrue(view.isAvailableTarget)

        wrapper.alphaValue = 0
        XCTAssertFalse(view.isAvailableTarget, "祖先透明时不得接受拖拽")
    }

    // MARK: - Helpers

    private func makeContainer() -> (NSView, NSWindow?) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        container.layoutSubtreeIfNeeded()
        return (container, nil)
    }
}

/// Minimal stand-in for a tab's drop surface.
@MainActor
private final class FakeDropDestination: NSView, FinderUploadDestination {
    var available = true
    var destinationView: NSView { self }
    var isAvailableTarget: Bool { available }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {}
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}
}
