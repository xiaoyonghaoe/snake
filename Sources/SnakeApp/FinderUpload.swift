import AppKit
import SwiftUI
import OSLog

let finderDropLog = Logger(subsystem: "com.snake.client", category: "FinderDrop")

/// Finder publishes one file URL per pasteboard item, including directories.
/// Never interpret plain text, remote-file references, or workspace tabs as files.
enum FinderUploadPasteboard {
    static let workspaceTab = NSPasteboard.PasteboardType("com.snake.workspace-tab")
    static let remoteFile = NSPasteboard.PasteboardType("com.snake.remote-file-reference")

    static func accepts(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.fileURL) && !types.contains(workspaceTab) && !types.contains(remoteFile)
            && !types.contains(WorkspaceDragPayload.profileType)
    }

    static func urls(from pasteboard: NSPasteboard) throws -> [URL] {
        guard accepts(pasteboard) else { throw FinderUploadError.invalidFiles }
        var seen = Set<String>()
        var result: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let normalized = try localURL(from: item.data(forType: .fileURL) as NSData?)
            if seen.insert(normalized.path).inserted { result.append(normalized) }
        }
        guard !result.isEmpty else { throw FinderUploadError.invalidFiles }
        return result
    }

    static func localURL(from item: NSSecureCoding?) throws -> URL {
        let url: URL?
        if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
            url = (item as? NSURL).map { $0 as URL }
        }
        guard let url, url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" else { throw FinderUploadError.invalidFiles }
        return url.standardizedFileURL
    }

    /// SwiftUI's SFTP table is itself a drop destination. Decode its providers
    /// with the same validation used by the native SSH/SFTP hosting surface.
    @MainActor
    static func urls(from providers: [NSItemProvider]) async throws -> [URL] {
        guard !providers.isEmpty, providers.allSatisfy({ provider in
            provider.hasItemConformingToTypeIdentifier(NSPasteboard.PasteboardType.fileURL.rawValue)
                && !([workspaceTab, remoteFile] + WorkspaceDragPayload.types).contains {
                    provider.hasItemConformingToTypeIdentifier($0.rawValue)
                }
        }) else { throw FinderUploadError.invalidFiles }
        var seen = Set<String>()
        var urls: [URL] = []
        for provider in providers {
            finderDropLog.notice("Provider URL decode started")
            let url: URL = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue) { data, error in
                    do {
                        guard error == nil, let data else { throw FinderUploadError.invalidFiles }
                        continuation.resume(returning: try localURL(from: data as NSData))
                        finderDropLog.notice("Provider URL decode completed")
                    } catch {
                        finderDropLog.error("Provider URL decode failed")
                        continuation.resume(throwing: error)
                    }
                }
            }
            if seen.insert(url.path).inserted { urls.append(url) }
        }
        return urls
    }
}

/// Finder file copies are file URLs, while ordinary terminal text remains a
/// normal paste. Keep this policy separate from drag-and-drop routing.
enum FinderClipboardPaste {
    static func isShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command]
            && event.charactersIgnoringModifiers?.lowercased() == "v"
    }

    /// Insert names, never local paths. Quoting keeps a copied name from being
    /// interpreted as multiple shell arguments or a command substitution.
    static func fileNamesText(for urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let names = urls.map(\.lastPathComponent)
        guard names.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            return nil
        }
        return names.map { name in
            if name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-+".unicodeScalars.contains($0) }) {
                return name
            }
            return "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

enum FinderUploadError: LocalizedError {
    case invalidFiles
    var errorDescription: String? { L10n.text("无法读取访达文件，请重新复制或拖入文件或文件夹。") }
}

enum FinderUploadTarget: Equatable {
    case directory(String)
    case confirmDirectory
    case unavailable(String)

    var title: String {
        switch self {
        case .directory(let path): L10n.format("上传到 %@", path)
        case .confirmDirectory: L10n.text("松开后选择上传目录")
        case .unavailable(let message): message
        }
    }

    var canUpload: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// Whether a native drop surface is actually drawn on screen.
///
/// Bonsplit keeps every tab's content alive at the same time
/// (`BonsplitConfiguration.contentViewLifecycle == .keepAllAlive`) and hides the
/// unselected ones with `.opacity(0)`, so their hosting views keep the same frame as
/// the visible tab. `isHiddenOrHasHiddenAncestor` does not see that: measured on a
/// `ZStack` with one `.opacity(0)` child, the hidden view keeps `alphaValue == 1` and
/// `isHidden == false`, while an ancestor has `alphaValue == 0`. Without this check a
/// Finder drop can be claimed by a tab that is not on screen.
@MainActor
enum FinderDropVisibility {
    static func isDrawn(_ view: NSView) -> Bool {
        var node: NSView? = view
        while let current = node {
            if current.isHidden || current.alphaValue < 0.01 { return false }
            node = current.superview
        }
        return !view.bounds.isEmpty && !view.visibleRect.isEmpty
    }
}

/// A real AppKit ancestor of both SwiftTerm and the SFTP browser. It moves with
/// the tab and converts current window coordinates rather than caching frames.
struct FinderUploadSurface<Content: View>: NSViewRepresentable {
    let content: Content
    let runtimeID: WorkspaceTabID
    let isActive: () -> Bool
    let target: () -> FinderUploadTarget
    let perform: ([URL], FinderUploadTarget, NSWindow) -> Void
    /// Diagnostic identity of the owning tab, for the drag log.
    let identity: String

    func makeNSView(context: Context) -> FinderUploadHostingView<Content> {
        let view = FinderUploadHostingView(rootView: content)
        configure(view)
        return view
    }

    func updateNSView(_ view: FinderUploadHostingView<Content>, context: Context) {
        view.rootView = content
        configure(view)
    }

    private func configure(_ view: FinderUploadHostingView<Content>) {
        let active = isActive()
        view.pasteRuntimeID = runtimeID
        view.requiresUploadArea = true
        view.isActiveTarget = isActive
        view.uploadTarget = target
        view.performUpload = perform
        view.dropIdentity = identity
        // Only the tab on screen may be an AppKit drop destination; the others stay in
        // the hierarchy but must not capture a drag aimed at the visible one.
        view.setDropEnabled(active)
        if view.lastConfiguration != active {
            view.lastConfiguration = active
            finderDropLog.notice("Surface configured: \(identity, privacy: .public) active=\(active, privacy: .public) view=\(UInt(bitPattern: ObjectIdentifier(view).hashValue), privacy: .public)")
        }
    }
}

@MainActor
protocol FinderUploadPasteSurface: AnyObject {
    var pasteRuntimeID: WorkspaceTabID? { get }
}

@MainActor
protocol FinderUploadDestination: AnyObject {
    var destinationView: NSView { get }
    var isAvailableTarget: Bool { get }
    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation
    func draggingExited(_ sender: (any NSDraggingInfo)?)
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool
    func concludeDragOperation(_ sender: (any NSDraggingInfo)?)
}

final class FinderUploadHostingView<Content: View>: NSHostingView<Content>, FinderUploadDestination, FinderUploadPasteSurface {
    var pasteRuntimeID: WorkspaceTabID?
    var requiresUploadArea = false
    var isActiveTarget: () -> Bool = { false }
    var uploadTarget: () -> FinderUploadTarget = { .unavailable(L10n.text("请先连接")) }
    var performUpload: ([URL], FinderUploadTarget, NSWindow) -> Void = { _, _, _ in }
    /// Owning tab, used only by the drag log.
    var dropIdentity = "-"
    /// Last value handed to `setDropEnabled`, so `configure` only logs transitions.
    var lastConfiguration: Bool?
    private var dropEnabled = true
    private var indicator: FinderUploadIndicator?
    var destinationView: NSView { self }
    var isAvailableTarget: Bool {
        isActiveTarget() && window?.attachedSheet == nil && FinderDropVisibility.isDrawn(self)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    /// Keeps this surface from being an AppKit drag destination while its tab is not
    /// the one on screen. The destination predicate alone is not enough: several tab
    /// contents share the same frame, so AppKit may hand the drag to any of them.
    func setDropEnabled(_ enabled: Bool) {
        // 状态没变就什么都不做：`init` 已经注册过 `.fileURL`，`viewDidMoveToWindow` 会补一次，
        // 而 `registerForDraggedTypes` 的覆写在启用时始终强制包含 `.fileURL`。每次 SwiftUI
        // 重算都重写注册只会白白搅动 AppKit 的拖拽目的地（拖拽进行中甚至可能让目标被重建）。
        guard dropEnabled != enabled else { return }
        dropEnabled = enabled
        if enabled {
            registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
        } else {
            unregisterDraggedTypes()
        }
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // SwiftUI can change registrations when its content updates.
        guard dropEnabled else {
            super.registerForDraggedTypes(newTypes.filter { $0 != .fileURL })
            return
        }
        super.registerForDraggedTypes(Array(Set(newTypes + [.fileURL])))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearIndicator()
        guard dropEnabled else { return }
        registerForDraggedTypes(registeredDraggedTypes)
    }

    private var dropLogContext: String {
        "\(dropIdentity) view=\(UInt(bitPattern: ObjectIdentifier(self).hashValue)) active=\(isActiveTarget()) drawn=\(FinderDropVisibility.isDrawn(self))"
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        finderDropLog.notice("Native entered: fileURL=\(FinderUploadPasteboard.accepts(sender.draggingPasteboard)), active=\(self.isAvailableTarget), inArea=\(self.containsDropLocation(sender)), \(self.dropLogContext, privacy: .public)")
        guard FinderUploadPasteboard.accepts(sender.draggingPasteboard) else { return super.draggingEntered(sender) }
        return updateDrag(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard FinderUploadPasteboard.accepts(sender.draggingPasteboard) else { return super.draggingUpdated(sender) }
        return updateDrag(sender)
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearIndicator()
        super.draggingExited(sender)
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearIndicator()
        super.concludeDragOperation(sender)
    }
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        clearIndicator()
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard FinderUploadPasteboard.accepts(sender.draggingPasteboard) else { return super.prepareForDragOperation(sender) }
        let ready = isAvailableTarget && containsDropLocation(sender)
            && sender.draggingSourceOperationMask.contains(.copy) && uploadTarget().canUpload
        finderDropLog.notice("Native prepare: ready=\(ready), \(self.dropLogContext, privacy: .public)")
        return ready
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        finderDropLog.notice("Native perform: accepted=\(self.prepareForDragOperation(sender)), \(self.dropLogContext, privacy: .public)")
        defer { clearIndicator() }
        // Preserve SwiftUI's remote-file and Bonsplit handlers for other types.
        guard FinderUploadPasteboard.accepts(sender.draggingPasteboard) else { return super.performDragOperation(sender) }
        guard prepareForDragOperation(sender), let window else { return false }
        // Snapshot the destination at mouse-up. Subsequent cd/navigation or tab
        // focus changes must not send this batch to a different directory.
        let destination = uploadTarget()
        do {
            let urls = try FinderUploadPasteboard.urls(from: sender.draggingPasteboard)
            performUpload(urls, destination, window)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.text("无法上传")
            alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
            return false
        }
    }

    private func updateDrag(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isAvailableTarget, containsDropLocation(sender), FinderUploadPasteboard.accepts(sender.draggingPasteboard),
              sender.draggingSourceOperationMask.contains(.copy) else {
            clearIndicator()
            return []
        }
        let target = uploadTarget()
        if indicator == nil {
            let view = FinderUploadIndicator(frame: bounds)
            view.autoresizingMask = [.width, .height]
            addSubview(view, positioned: .above, relativeTo: nil)
            indicator = view
        }
        indicator?.show(target)
        return target.canUpload ? .copy : []
    }

    private func clearIndicator() {
        indicator?.removeFromSuperview()
        indicator = nil
    }

    private func containsDropLocation(_ sender: any NSDraggingInfo) -> Bool {
        guard window === sender.draggingDestinationWindow else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        guard bounds.contains(point) && visibleRect.contains(point) else { return false }
        guard requiresUploadArea else { return true }
        return WorkspaceDropGeometry.views(FinderUploadAreaView.self, in: self).contains {
            WorkspaceDropGeometry.visibleFrame(of: $0).contains(sender.draggingLocation)
        }
    }
}

/// Marks only the terminal surface / SFTP table, excluding the address editor
/// and connection toolbar even though they share a hosting ancestor.
struct FinderUploadArea: NSViewRepresentable {
    func makeNSView(context: Context) -> FinderUploadAreaView { FinderUploadAreaView() }
    func updateNSView(_ view: FinderUploadAreaView, context: Context) {}
}

final class FinderUploadAreaView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FinderUploadIndicator: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 2
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ target: FinderUploadTarget) {
        let color = target.canUpload ? NSColor.controlAccentColor : .systemOrange
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderColor = color.cgColor
        label.textColor = color
        label.stringValue = target.title + (target.canUpload ? L10n.text("\n文件夹将保留目录结构") : "")
    }
}

/// Window-level fallback for an unregistered native child (for example a
/// terminal scroller). No sidebar/title-bar fallback to the focused session.
@MainActor
final class FinderUploadWindowRouter: NSObject, NSDraggingDestination {
    private weak var current: (any FinderUploadDestination)?

    static func destination(in root: NSView, at point: NSPoint) -> (any FinderUploadDestination)? {
        // `keepAllAlive` keeps unselected tabs in the hierarchy with the same frame as
        // the visible one, so visibility has to be checked through ancestors' alpha.
        guard FinderDropVisibility.isDrawn(root),
              root.bounds.contains(root.convert(point, from: nil)),
              root.visibleRect.contains(root.convert(point, from: nil)) else { return nil }
        for child in root.subviews.reversed() {
            if let match = destination(in: child, at: point) { return match }
        }
        guard let candidate = root as? any FinderUploadDestination, candidate.isAvailableTarget else { return nil }
        return candidate
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard FinderUploadPasteboard.accepts(sender.draggingPasteboard) else {
            draggingExited(sender)
            return []
        }
        let next = sender.draggingDestinationWindow?.contentView.flatMap {
            Self.destination(in: $0, at: sender.draggingLocation)
        }
        if current?.destinationView !== next?.destinationView {
            if let next {
                finderDropLog.notice("Router picked view=\(UInt(bitPattern: ObjectIdentifier(next.destinationView).hashValue), privacy: .public)")
            } else {
                finderDropLog.notice("Router picked none")
            }
            current?.draggingExited(sender)
            current = next
        }
        return current?.draggingUpdated(sender) ?? []
    }
    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        current?.draggingExited(sender)
        current = nil
    }
    func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        _ = draggingUpdated(sender)
        return current?.prepareForDragOperation(sender) ?? false
    }
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        _ = draggingUpdated(sender)
        defer { draggingExited(sender) }
        return current?.performDragOperation(sender) ?? false
    }
    func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { draggingExited(sender) }
    func draggingEnded(_ sender: any NSDraggingInfo) { draggingExited(sender) }
}
