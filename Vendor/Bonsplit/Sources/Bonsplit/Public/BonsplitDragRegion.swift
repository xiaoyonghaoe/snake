import AppKit
import SwiftUI

/// Geometry-only markers for hosts using native NSDraggingSession routing.
/// They never intercept mouse input and never register file-drop types.
public enum BonsplitDragRegionKind: Equatable {
    case content
    case tabBar
    case tab(TabID)
}

public struct BonsplitDragRegion: NSViewRepresentable {
    public let paneID: PaneID
    public let kind: BonsplitDragRegionKind

    public init(paneID: PaneID, kind: BonsplitDragRegionKind) {
        self.paneID = paneID
        self.kind = kind
    }

    public func makeNSView(context: Context) -> BonsplitDragRegionView {
        BonsplitDragRegionView(paneID: paneID, kind: kind)
    }

    public func updateNSView(_ view: BonsplitDragRegionView, context: Context) {
        view.paneID = paneID
        view.kind = kind
    }
}

public final class BonsplitDragRegionView: NSView {
    public var paneID: PaneID
    public var kind: BonsplitDragRegionKind

    public init(paneID: PaneID, kind: BonsplitDragRegionKind) {
        self.paneID = paneID
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(paneID:kind:)") }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
