import AppKit
import SwiftUI

/// Host workspace controls in the actual title-bar toolbar, alongside macOS
/// window buttons. AppKit handles window dragging, full screen and resizing.
struct NativeWorkspaceToolbar: NSViewRepresentable {
    let content: AnyView
    let isDark: Bool

    func makeNSView(context: Context) -> WorkspaceToolbarAnchor {
        WorkspaceToolbarAnchor(content: content)
    }

    func updateNSView(_ view: WorkspaceToolbarAnchor, context: Context) {
        view.host.rootView = content
        view.workspaceAppearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

final class WorkspaceToolbarAnchor: NSView, NSToolbarDelegate {
    let host: NSHostingView<AnyView>
    var workspaceAppearance: NSAppearance? {
        didSet { window?.appearance = workspaceAppearance }
    }
    private let toolbar = NSToolbar(identifier: "com.snake.workspace.toolbar")
    private let controls = NSToolbarItem(itemIdentifier: .init("com.snake.workspace.controls"))

    init(content: AnyView) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 40)
        controls.view = host
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            host.heightAnchor.constraint(equalToConstant: 40)
        ])
        host.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controls.visibilityPriority = .high
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(content:)") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.toolbarStyle = .unified
        window.toolbar = toolbar
        window.titleVisibility = .hidden
        window.appearance = workspaceAppearance
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [controls.itemIdentifier] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [controls.itemIdentifier] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { controls }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
