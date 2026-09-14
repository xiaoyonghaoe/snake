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

enum FinderUploadError: LocalizedError {
    case invalidFiles
    var errorDescription: String? { L10n.text("无法读取拖入的文件，请从访达重新选择文件或文件夹。") }
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

/// A real AppKit ancestor of both SwiftTerm and the SFTP browser. It moves with
/// the tab and converts current window coordinates rather than caching frames.
struct FinderUploadSurface<Content: View>: NSViewRepresentable {
    let content: Content
    let isActive: () -> Bool
    let target: () -> FinderUploadTarget
    let perform: ([URL], FinderUploadTarget, NSWindow) -> Void

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
        view.requiresUploadArea = true
        view.isActiveTarget = isActive
        view.uploadTarget = target
        view.performUpload = perform
    }
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

final class FinderUploadHostingView<Content: View>: NSHostingView<Content>, FinderUploadDestination {
    var requiresUploadArea = false
    var isActiveTarget: () -> Bool = { false }
    var uploadTarget: () -> FinderUploadTarget = { .unavailable(L10n.text("请先连接")) }
    var performUpload: ([URL], FinderUploadTarget, NSWindow) -> Void = { _, _, _ in }
    private var indicator: FinderUploadIndicator?
    var destinationView: NSView { self }
    var isAvailableTarget: Bool { isActiveTarget() && window?.attachedSheet == nil && !isHiddenOrHasHiddenAncestor }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // SwiftUI can change registrations when its content updates.
        super.registerForDraggedTypes(Array(Set(newTypes + [.fileURL])))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearIndicator()
        registerForDraggedTypes(registeredDraggedTypes)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        finderDropLog.notice("Native entered: fileURL=\(FinderUploadPasteboard.accepts(sender.draggingPasteboard)), active=\(self.isAvailableTarget), inArea=\(self.containsDropLocation(sender))")
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
        return isAvailableTarget && containsDropLocation(sender)
            && sender.draggingSourceOperationMask.contains(.copy) && uploadTarget().canUpload
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        finderDropLog.notice("Native perform: accepted=\(self.prepareForDragOperation(sender))")
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
        guard !root.isHiddenOrHasHiddenAncestor,
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
