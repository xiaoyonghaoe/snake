import AppKit
import Bonsplit
import SwiftUI
import OSLog

private let dragLog = Logger(subsystem: "com.snake.client", category: "WorkspaceDrag")

/// Native ancestor destination. SwiftUI may re-register types as its tree
/// changes, so preserve our routes here as well as on the window delegate.
final class WorkspaceHostingView<Content: View>: NSHostingView<Content> {
    weak var workspaceCoordinator: WorkspaceWindowCoordinator?
    private let files = FinderUploadWindowRouter()
    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([])
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let window, workspaceCoordinator?.handleWorkspaceCloseShortcut(event, in: window) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        super.registerForDraggedTypes(Array(Set(newTypes + WorkspaceDragPayload.types + [.fileURL])))
    }
    private func isWorkspace(_ sender: any NSDraggingInfo) -> Bool {
        (sender.draggingPasteboard.types ?? []).contains { WorkspaceDragPayload.types.contains($0) }
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragLog.debug("Root destination entered: workspace=\(self.isWorkspace(sender))")
        return draggingUpdated(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if isWorkspace(sender) { return workspaceCoordinator?.dragging.draggingUpdated(sender) ?? [] }
        if FinderUploadPasteboard.accepts(sender.draggingPasteboard) { return files.draggingUpdated(sender) }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isWorkspace(sender) { return workspaceCoordinator?.dragging.prepareForDragOperation(sender) ?? false }
        if FinderUploadPasteboard.accepts(sender.draggingPasteboard) { return files.prepareForDragOperation(sender) }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isWorkspace(sender) { return workspaceCoordinator?.dragging.performDragOperation(sender) ?? false }
        if FinderUploadPasteboard.accepts(sender.draggingPasteboard) { return files.performDragOperation(sender) }
        return super.performDragOperation(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        files.draggingExited(sender); workspaceCoordinator?.dragging.draggingExited(sender); super.draggingExited(sender)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { draggingExited(sender) }
}

enum WorkspaceDragSource: Codable, Equatable {
    case tab(windowID: WindowID, tabID: TabID)
    case profile(UUID)

    var pasteboardType: NSPasteboard.PasteboardType {
        switch self {
        case .tab: FinderUploadPasteboard.workspaceTab
        case .profile: WorkspaceDragPayload.profileType
        }
    }
    var operation: NSDragOperation {
        if case .profile = self { return .copy }
        return .move
    }
}

struct WorkspaceDragPayload: Codable, Equatable {
    static let profileType = NSPasteboard.PasteboardType("com.snake.ssh-profile")
    static let types = [FinderUploadPasteboard.workspaceTab, profileType]
    let transactionID: UUID
    let source: WorkspaceDragSource

    func matches(_ board: NSPasteboard) -> Bool {
        let types = board.types ?? []
        guard types.contains(source.pasteboardType),
              !types.contains(.fileURL), !types.contains(FinderUploadPasteboard.remoteFile),
              !types.contains(source.pasteboardType == Self.profileType ? FinderUploadPasteboard.workspaceTab : Self.profileType),
              let data = board.data(forType: source.pasteboardType) else { return false }
        return (try? JSONDecoder().decode(Self.self, from: data)) == self
    }
}

struct WorkspaceDragTransaction {
    enum Outcome { case active, cancelled, committed }
    let payload: WorkspaceDragPayload
    private(set) var outcome = Outcome.active
    mutating func cancel() { if outcome == .active { outcome = .cancelled } }
    mutating func commit(_ perform: () -> Bool) -> Bool {
        guard outcome == .active, perform() else { return false }
        outcome = .committed
        return true
    }
}

enum WorkspaceDropEdge: CaseIterable {
    case left, right, top, bottom
    var orientation: SplitOrientation { self == .left || self == .right ? .horizontal : .vertical }
    var insertFirst: Bool { self == .left || self == .top }
}

enum WorkspaceDropPlacement: Equatable {
    case center
    case insert(Int)
    case split(WorkspaceDropEdge)
}

struct WorkspaceDropTarget: Equatable {
    let windowID: WindowID
    let paneID: PaneID
    let placement: WorkspaceDropPlacement
    /// AppKit window coordinates, refreshed on every drag update.
    let previewRect: NSRect
}

enum WorkspaceDropGeometry {
    static func placement(at point: NSPoint, in rect: NSRect, empty: Bool) -> WorkspaceDropPlacement? {
        guard rect.contains(point) else { return nil }
        guard !empty else { return .center }
        // Use the current pane frame on every update and drop: 40% of its
        // width/height, without a fixed cap. Overlapping zones choose the
        // closest normalized edge, including near the content center.
        let horizontalDepth = rect.width * 0.4
        let verticalDepth = rect.height * 0.4
        let edges: [(edge: WorkspaceDropEdge, distance: CGFloat)] = [
            (.left, (point.x - rect.minX) / horizontalDepth),
            (.right, (rect.maxX - point.x) / horizontalDepth),
            (.top, (rect.maxY - point.y) / verticalDepth),
            (.bottom, (point.y - rect.minY) / verticalDepth)
        ]
        if let nearest = edges.min(by: { $0.distance < $1.distance }), nearest.distance <= 1 {
            return .split(nearest.edge)
        }
        return nil
    }

    static func preview(_ placement: WorkspaceDropPlacement, in rect: NSRect) -> NSRect {
        var result = rect
        switch placement {
        case .split(.left): result.size.width /= 2
        case .split(.right): result.origin.x += rect.width / 2; result.size.width /= 2
        case .split(.top): result.origin.y += rect.height / 2; result.size.height /= 2
        case .split(.bottom): result.size.height /= 2
        default: break
        }
        return result.insetBy(dx: 3, dy: 3)
    }

    @MainActor
    static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
    }

    @MainActor
    static func visibleFrame(of view: NSView) -> NSRect {
        guard !view.isHiddenOrHasHiddenAncestor, view.window != nil else { return .zero }
        return view.convert(view.bounds.intersection(view.visibleRect), to: nil)
    }

    @MainActor
    static func target(in window: NSWindow, state: WorkspaceWindowState, at point: NSPoint) -> WorkspaceDropTarget? {
        guard window.attachedSheet == nil, let root = window.contentView else { return nil }
        let regions = views(BonsplitDragRegionView.self, in: root)
        let bar = regions.first { $0.kind == .tabBar && visibleFrame(of: $0).contains(point) }
        if let bar {
            let tabs = state.bonsplit.tabs(inPane: bar.paneID)
            let visibleTabs = regions.compactMap { region -> (Int, NSRect)? in
                guard region.paneID == bar.paneID, case .tab(let id) = region.kind,
                      let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
                let frame = visibleFrame(of: region).intersection(visibleFrame(of: bar))
                return frame.isEmpty || frame.isNull ? nil : (index, frame)
            }.sorted { $0.0 < $1.0 }
            let slot = visibleTabs.first { point.x < $0.1.midX }
            let index = slot?.0 ?? visibleTabs.last.map { $0.0 + 1 } ?? tabs.count
            let frame = visibleFrame(of: bar)
            let caretX = slot?.1.minX ?? visibleTabs.last?.1.maxX ?? frame.minX
            return WorkspaceDropTarget(windowID: state.id, paneID: bar.paneID, placement: .insert(index),
                                       previewRect: NSRect(x: min(caretX, frame.maxX - 3), y: frame.minY + 3, width: 3, height: max(0, frame.height - 6)))
        }
        guard let content = regions.first(where: { $0.kind == .content && visibleFrame(of: $0).contains(point) }) else { return nil }
        let frame = visibleFrame(of: content)
        guard let placement = placement(at: point, in: frame, empty: state.bonsplit.tabs(inPane: content.paneID).isEmpty) else { return nil }
        return WorkspaceDropTarget(windowID: state.id, paneID: content.paneID, placement: placement,
                                   previewRect: preview(placement, in: frame))
    }
}

struct ProfileDragSourceRegion: NSViewRepresentable {
    let profileID: UUID
    func makeNSView(context: Context) -> ProfileDragSourceView { ProfileDragSourceView(profileID: profileID) }
    func updateNSView(_ view: ProfileDragSourceView, context: Context) { view.profileID = profileID }
}

final class ProfileDragSourceView: NSView {
    var profileID: UUID
    init(profileID: UUID) { self.profileID = profileID; super.init(frame: .zero) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(profileID:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A monitor detects only drag initiation (without intercepting ordinary
/// clicks). NSDraggingSession owns completion; no mouse-up-driven tab moves.
@MainActor
final class WorkspaceDragCoordinator: NSObject, NSDraggingSource, NSDraggingDestination {
    private weak var owner: WorkspaceWindowCoordinator?
    // Accessed on MainActor; nonisolated only so deinit can unregister the token.
    nonisolated(unsafe) private var monitor: Any?
    private var pending: (source: WorkspaceDragSource, view: NSView, origin: NSPoint)?
    private var transaction: WorkspaceDragTransaction?
    var active: WorkspaceDragPayload? { transaction?.payload }
    private var session: NSDraggingSession?
    private var cancelled: Bool { transaction?.outcome == .cancelled }
    private var committed: Bool { transaction?.outcome == .committed }
    private var indicator: WorkspaceDragIndicator?
    private var receivers: [WorkspaceNativeDropOverlay] = []
    private var previewTitle = ""

    init(owner: WorkspaceWindowCoordinator) {
        self.owner = owner
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.observe(event)
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func observe(_ event: NSEvent) -> NSEvent? {
        if active != nil {
            if event.type == .keyDown && event.keyCode == 53 { transaction?.cancel(); clearIndicator() }
            if event.type == .flagsChanged { updatePreview(at: NSEvent.mouseLocation) }
            return event
        }
        if event.type == .leftMouseUp { pending = nil; return event }
        if event.type == .leftMouseDown {
            pending = nil
            guard let window = event.window, window.attachedSheet == nil,
                  let state = owner?.workspaceState(for: window), let root = window.contentView else { return event }
            if let marker = WorkspaceDropGeometry.views(BonsplitDragRegionView.self, in: root).first(where: {
                if case .tab = $0.kind { return WorkspaceDropGeometry.visibleFrame(of: $0).contains(event.locationInWindow) }
                return false
            }), case .tab(let id) = marker.kind {
                pending = (.tab(windowID: state.id, tabID: id), marker, event.locationInWindow)
            } else if let marker = WorkspaceDropGeometry.views(ProfileDragSourceView.self, in: root).first(where: {
                WorkspaceDropGeometry.visibleFrame(of: $0).contains(event.locationInWindow)
            }) {
                pending = (.profile(marker.profileID), marker, event.locationInWindow)
            }
        } else if event.type == .leftMouseDragged, let pending, event.window === pending.view.window,
                  hypot(event.locationInWindow.x - pending.origin.x, event.locationInWindow.y - pending.origin.y) >= 5 {
            self.pending = nil
            guard owner?.dragSourceExists(pending.source) == true else { return event }
            let payload = WorkspaceDragPayload(transactionID: UUID(), source: pending.source)
            guard let data = try? JSONEncoder().encode(payload) else { return event }
            let item = NSPasteboardItem()
            item.setData(data, forType: pending.source.pasteboardType)
            let draggingItem = NSDraggingItem(pasteboardWriter: item)
            guard let sourceWindow = pending.view.window else { return event }
            let point = event.locationInWindow
            transaction = WorkspaceDragTransaction(payload: payload)
            installReceivers()
            let registrationCount = pending.view.window?.contentView?.registeredDraggedTypes.count ?? 0
            dragLog.debug("Native workspace drag started: rootTypes=\(registrationCount), appActive=\(NSApp.isActive)")
            previewTitle = title()
            draggingItem.setDraggingFrame(NSRect(x: point.x - 25, y: point.y - 18, width: 250, height: 36), contents: previewImage())
            // The geometry marker is deliberately transparent to hit testing.
            // Start from its owning window instead of that non-interactive view.
            session = sourceWindow.beginDraggingSession(items: [draggingItem], event: event, source: self)
            session?.animatesToStartingPositionsOnCancelOrFail = true
            return nil
        }
        return event
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard let active else { return [] }
        if context == .outsideApplication, case .profile = active.source { return [] }
        return active.source.operation
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) { updatePreview(at: screenPoint) }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragLog.debug("Native workspace drag ended: operation=\(operation.rawValue), committed=\(self.committed), cancelled=\(self.cancelled)")
        defer {
            clearIndicator()
            receivers.forEach { $0.removeFromSuperview() }
            receivers.removeAll()
            transaction = nil
            self.session = nil
            pending = nil
        }
        guard let active, !committed, !cancelled else { return }
        // Only tabs tear out. Invalid areas inside a Snake window cancel.
        if case .tab = active.source, owner?.containsSnakeWindow(at: screenPoint) == false,
           operation.isEmpty, NSEvent.pressedMouseButtons == 0 {
            owner?.detachDraggedTab(active.source, near: screenPoint)
        }
    }

    func recognizes(_ board: NSPasteboard) -> Bool { active?.matches(board) == true }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !cancelled, recognizes(sender.draggingPasteboard), let active,
              let window = sender.draggingDestinationWindow, let state = owner?.workspaceState(for: window),
              let target = WorkspaceDropGeometry.target(in: window, state: state, at: sender.draggingLocation) else {
            clearIndicator(); return []
        }
        show(target, in: window)
        return active.source.operation
    }
    func draggingExited(_ sender: (any NSDraggingInfo)?) { clearIndicator() }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !committed && !draggingUpdated(sender).isEmpty }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { clearIndicator() }
        guard prepareForDragOperation(sender), let active, let owner,
              let window = sender.draggingDestinationWindow, let state = owner.workspaceState(for: window),
              let target = WorkspaceDropGeometry.target(in: window, state: state, at: sender.draggingLocation) else { return false }
        let result = transaction?.commit {
            owner.commitWorkspaceDrop(active.source, target: target, openSFTP: NSEvent.modifierFlags.contains(.option))
        } ?? false
        dragLog.debug("Native workspace drop commit=\(result)")
        return result
    }
    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { clearIndicator() }
    func draggingEnded(_ sender: any NSDraggingInfo) { clearIndicator() }

    private func title() -> String {
        guard let active else { return "" }
        if case .profile = active.source {
            return NSEvent.modifierFlags.contains(.option) ? "新建 SFTP · 松开以打开" : "新建终端 · 按住 ⌥ 打开 SFTP"
        }
        return "移动标签 · 边缘分屏 / 拖出独立窗口"
    }

    private func previewImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 250, height: 36))
        image.lockFocus()
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 250, height: 36), xRadius: 8, yRadius: 8).fill()
        (title() as NSString).draw(in: NSRect(x: 10, y: 9, width: 234, height: 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor
        ])
        image.unlockFocus()
        return image
    }

    private func updatePreview(at screenPoint: NSPoint) {
        guard !cancelled else { return }
        if title() != previewTitle {
            previewTitle = title()
            let image = previewImage()
            session?.enumerateDraggingItems(options: [], for: nil, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                item.setDraggingFrame(item.draggingFrame, contents: image)
            }
        }
        guard let (window, state) = owner?.dragWindow(at: screenPoint),
              let target = WorkspaceDropGeometry.target(in: window, state: state, at: window.convertPoint(fromScreen: screenPoint)) else {
            clearIndicator(); return
        }
        show(target, in: window)
    }

    private func show(_ target: WorkspaceDropTarget, in window: NSWindow) {
        guard let root = window.contentView else { return }
        if indicator?.window !== window {
            clearIndicator()
            let view = WorkspaceDragIndicator()
            root.addSubview(view, positioned: .above, relativeTo: nil)
            indicator = view
        }
        indicator?.frame = root.convert(target.previewRect, from: nil)
        indicator?.label.stringValue = target.previewRect.width > 100 ? title() : ""
    }

    private func clearIndicator() { indicator?.removeFromSuperview(); indicator = nil }

    private func installReceivers() {
        receivers.forEach { $0.removeFromSuperview() }
        receivers = owner?.visibleWorkspaceWindows.compactMap { window in
            guard let root = window.contentView else { return nil }
            let receiver = WorkspaceNativeDropOverlay(frame: root.bounds)
            receiver.coordinator = self
            receiver.autoresizingMask = [.width, .height]
            root.addSubview(receiver, positioned: .above, relativeTo: nil)
            return receiver
        } ?? []
    }
}

/// Exists only during a workspace drag. A concrete AppKit destination above
/// SwiftUI's hosting layers prevents their hit testing from swallowing drops.
private final class WorkspaceNativeDropOverlay: NSView {
    weak var coordinator: WorkspaceDragCoordinator?
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(WorkspaceDragPayload.types)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dragLog.debug("Native overlay destination entered")
        return coordinator?.draggingEntered(sender) ?? []
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { coordinator?.draggingUpdated(sender) ?? [] }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { coordinator?.prepareForDragOperation(sender) ?? false }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { coordinator?.performDragOperation(sender) ?? false }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { coordinator?.draggingExited(sender) }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { coordinator?.concludeDragOperation(sender) }
}

private final class WorkspaceDragIndicator: NSView {
    let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor), label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8)])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
