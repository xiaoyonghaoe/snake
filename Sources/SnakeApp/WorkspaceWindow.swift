import AppKit

/// SwiftUI can rebuild the application menu when its Settings scene opens.
/// Keep workspace Command-W semantics on the window that receives the event.
final class SnakeWorkspaceWindow: NSWindow {
    weak var workspaceCoordinator: WorkspaceWindowCoordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if workspaceCoordinator?.handleFinderPasteShortcut(event, in: self) == true { return true }
        if workspaceCoordinator?.handleWorkspaceCloseShortcut(event, in: self) == true { return true }
        if workspaceCoordinator?.handleNewSessionTabShortcut(event, in: self) == true { return true }
        if workspaceCoordinator?.handleSFTPShortcut(event, in: self) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
