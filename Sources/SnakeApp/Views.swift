import AppKit
import Bonsplit
import SnakeCoreBindings
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let snakeRemoteFile = UTType(exportedAs: "com.snake.remote-file-reference")
}

/// Attaches the Finder/remote drop target only to the tab that is on screen.
///
/// Bonsplit keeps every tab's content alive (`keepAllAlive`) and hides the unselected
/// ones with `.opacity(0)`, which does not stop AppKit from offering them a drop. A
/// hidden table that stayed registered could swallow a drag meant for the visible tab,
/// so the drop target is simply absent while the tab is not on screen.
private struct SFTPFinderDropModifier: ViewModifier {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: SFTPRuntime
    let isOnScreen: () -> Bool
    @Binding var receivesRemoteFile: Bool
    @Binding var receivesFinderFiles: Bool
    let perform: ([NSItemProvider]) -> Void

    func body(content: Content) -> some View {
        if isOnScreen() {
            content.onDrop(
                of: [UTType.snakeRemoteFile.identifier, UTType.fileURL.identifier],
                delegate: SFTPFileDropDelegate(
                    isTargeted: $receivesRemoteFile,
                    receivesFinderFiles: $receivesFinderFiles,
                    isOnScreen: isOnScreen,
                    identity: "SFTP \(runtime.profile.name) runtime=\(runtime.id.rawValue.uuidString.prefix(8))",
                    finderTarget: { runtime.finderUploadTarget },
                    upload: { providers, path in runtime.uploadFromFinder(providers: providers, to: path, store: store) },
                    perform: perform
                )
            )
        } else {
            content
        }
    }
}

private struct SFTPFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var receivesFinderFiles: Bool
    let isOnScreen: () -> Bool
    let identity: String
    let finderTarget: () -> FinderUploadTarget
    let upload: ([NSItemProvider], String) -> Void
    let perform: ([NSItemProvider]) -> Void

    private func isWorkspace(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: WorkspaceDragPayload.types.map(\.rawValue))
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Only the tab that is actually on screen may take a Finder drop: Bonsplit
        // keeps every tab's content alive, so a hidden table is still in the hierarchy.
        guard isOnScreen() else { return false }
        let remote = info.hasItemsConforming(to: [UTType.snakeRemoteFile.identifier])
        let local = info.hasItemsConforming(to: [UTType.fileURL.identifier])
        return !isWorkspace(info) && remote != local
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { dropExited(info: info); return }
        isTargeted = info.hasItemsConforming(to: [UTType.snakeRemoteFile.identifier])
        receivesFinderFiles = !isTargeted && !isWorkspace(info) && info.hasItemsConforming(to: [UTType.fileURL.identifier])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            return DropProposal(operation: .forbidden)
        }
        dropEntered(info: info)
        if receivesFinderFiles { return DropProposal(operation: finderTarget().canUpload ? .copy : .forbidden) }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        receivesFinderFiles = false
    }

    func performDrop(info: DropInfo) -> Bool {
        finderDropLog.notice("Table perform: onScreen=\(self.isOnScreen()), \(self.identity, privacy: .public)")
        dropExited(info: info)
        guard validateDrop(info: info) else { return false }
        // Route by the validated drag type, not by the number of providers
        // returned for another type. A Finder provider must never be sent to
        // the remote-reference JSON decoder (which would silently ignore it).
        if info.hasItemsConforming(to: [UTType.fileURL.identifier]) {
            guard case .directory(let path) = finderTarget() else { return false }
            let files = info.itemProviders(for: [UTType.fileURL.identifier])
            finderDropLog.notice("Table Finder payload: items=\(files.count)")
            guard !files.isEmpty else { return false }
            upload(files, path)
            return true
        }
        let remoteProviders = info.itemProviders(for: [UTType.snakeRemoteFile.identifier])
        finderDropLog.notice("Table remote payload: items=\(remoteProviders.count)")
        guard !remoteProviders.isEmpty else { return false }
        perform(remoteProviders)
        return true
    }
}

public struct SnakeWorkspaceRootView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject private var windowState: WorkspaceWindowState

    public init(windowState: WorkspaceWindowState) { self.windowState = windowState }

    public var body: some View {
        WorkspaceView(windowState: windowState)
            .frame(minWidth: 1024, minHeight: 700)
            .background(NativeWorkspaceToolbar(content: AnyView(
                SnakeToolbar(windowState: windowState)
                    .environmentObject(store)
                    .environment(\.locale, store.appLanguage.locale)
                    .environment(\.colorScheme, store.isDarkAppearancePreferred ? .dark : .light)
            ), isDark: store.isDarkAppearancePreferred))
            .background(SnakeStyle.canvas)
            .environment(\.locale, store.appLanguage.locale)
            .preferredColorScheme(store.isDarkAppearancePreferred ? .dark : .light)
    }
}

public struct SnakeWindowScene: View {
    @StateObject private var windowState = WorkspaceWindowState()

    public init() {}

    public var body: some View {
        SnakeWorkspaceRootView(windowState: windowState)
            .background(WindowRegistrationView(windowState: windowState))
    }
}

private struct WindowRegistrationView: NSViewRepresentable {
    @ObservedObject var windowState: WorkspaceWindowState
    @EnvironmentObject private var store: ApplicationStore

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                store.workspaceCoordinator?.register(window: window, state: windowState)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                store.workspaceCoordinator?.register(window: window, state: windowState)
            }
        }
    }
}

private struct SnakeToolbar: View {
    @ObservedObject var windowState: WorkspaceWindowState

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("Snake")
                    .font(.system(size: 15, weight: .semibold))
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            Button { windowState.openManager(.mounts) } label: {
                Image(systemName: WorkspaceTabKind.mounts.symbolName)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SnakeIconButtonStyle(selected: windowState.selectedRuntime?.kind == .mounts, minSize: CGSize(width: 34, height: 30)))
            .help("打开磁盘映射与 SSH 隧道").accessibilityLabel("打开磁盘映射与 SSH 隧道")

            Button { windowState.showManager(.mcp) } label: {
                Image(systemName: WorkspaceTabKind.mcp.symbolName)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SnakeIconButtonStyle(selected: windowState.selectedRuntime?.kind == .mcp, minSize: CGSize(width: 34, height: 30)))
            .help("打开 MCP 服务").accessibilityLabel("打开 MCP 服务")

            Button { windowState.showManager(.passwords) } label: {
                Image(systemName: WorkspaceTabKind.passwords.symbolName)
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SnakeIconButtonStyle(selected: windowState.selectedRuntime?.kind == .passwords, minSize: CGSize(width: 34, height: 30)))
            .help("打开密码管理").accessibilityLabel("打开密码管理")

        }
        .padding(.horizontal, 4)
        .frame(height: 40)
    }
}

/// Dragging on the SSH page: sessions and folders reorder among their siblings
/// while the others slide aside, a session dropped on a folder moves into it, a
/// folder dropped on the middle of another moves inside it, and any level of the
/// breadcrumb path takes a card out to that level.
private enum CatalogItem: Hashable {
    case folder(UUID)
    case profile(UUID)
    /// A breadcrumb level; `nil` is the top level.
    case crumb(UUID?)
    /// The wide "move up one level" zone shown over the search field inside a folder.
    case moveUp
}

private enum CatalogDropIntent: Equatable {
    case reorder(onto: CatalogItem)
    case into(UUID?)
}

/// One press on a card; it becomes a drag once `SessionFolders.dragActivates`.
/// Card frames are frozen when the press starts, so cards sliding aside never
/// change what is under the pointer.
private struct CatalogPress: Equatable {
    let item: CatalogItem
    let started: Date
    let frames: [CatalogItem: CGRect]
    var translation = CGSize.zero
    var location = CGPoint.zero
    var isActive = false
    /// What the pointer is over right now, and since when; a reorder only takes
    /// effect once the pointer has rested on it (see `SessionCatalogView.reorderDwell`).
    var hoverIntent: CatalogDropIntent?
    var hoverSince = Date.distantPast
}

/// A reorder target the pointer has rested on long enough to slide cards aside.
private struct CatalogHover: Equatable {
    let intent: CatalogDropIntent
    let since: Date
}

private struct CatalogFrameKey: PreferenceKey {
    static let defaultValue: [CatalogItem: CGRect] = [:]
    static func reduce(value: inout [CatalogItem: CGRect], nextValue: () -> [CatalogItem: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct SessionCatalogView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: WorkspaceTabRuntime
    let onEdit: (SSHProfile) -> Void
    let onNewProfile: () -> Void
    let onConnect: (SSHProfile, Bool) -> Void
    let isOnScreen: () -> Bool
    @FocusState private var searchFocused: Bool
    @State private var folderEditor: SessionFolderDraft?
    @State private var pendingFolderDeletion: SessionGroup?
    @State private var frames: [CatalogItem: CGRect] = [:]
    /// The frames frozen for the current drag, kept past the gesture's own state
    /// (which may already be reset when the drop is handled).
    @State private var dragFrames: [CatalogItem: CGRect] = [:]
    @GestureState private var press: CatalogPress?
    @State private var settledHover: CatalogHover?

    private static let space = "session-catalog"
    private static let reorderAnimation = Animation.spring(response: 0.28, dampingFraction: 0.82)
    /// Passing over a card does not shuffle the grid; only resting on it does.
    /// Without this, aiming a folder at another folder slid that folder away.
    private static let reorderDwell: Duration = .milliseconds(300)

    private var activePress: CatalogPress? {
        guard let press, press.isActive else { return nil }
        return press
    }

    /// A deleted folder falls back to the top level instead of an empty page.
    private var openFolder: SessionGroup? {
        runtime.openFolderID.flatMap { id in store.groups.first { $0.id == id } }
    }

    private var isSearching: Bool {
        !runtime.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = [GridItem(.adaptive(minimum: min(240, max(1, geometry.size.width - 32))), spacing: 12)]
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // One row: where you are, search, and what you can create here.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            heading
                            Spacer(minLength: 12)
                            searchField.frame(minWidth: 220, maxWidth: 340)
                            actions
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            heading
                            HStack(spacing: 10) { searchField; actions }
                        }
                    }
                    content(columns: columns)
                }
                .padding(geometry.size.width < 500 ? 16 : 20)
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(CatalogFrameKey.self) { frames = $0 }
                .overlay(alignment: .topLeading) { dragPreview }
                // Fill the page so a right click on empty space below the cards still lands here.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .snakeContextMenu { blankAreaMenu }
            }
        }
        .background(SnakeStyle.canvas)
        // A closed hand shows the card is held, even before it reaches a target.
        .task(id: pendingHover) {
            guard let pendingHover else { return }
            try? await Task.sleep(for: Self.reorderDwell)
            if !Task.isCancelled { settledHover = pendingHover }
        }
        .onChange(of: activePress != nil) { _, dragging in
            if dragging {
                settledHover = nil
                dragFrames = activePress?.frames ?? frames
                NSCursor.closedHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onAppear {
            guard !runtime.restoredLastFolder else { return }
            runtime.restoredLastFolder = true
            if runtime.openFolderID == nil { runtime.openFolderID = store.lastSessionFolderID }
        }
        .onChange(of: runtime.openFolderID) { _, folderID in
            store.lastSessionFolderID = folderID
        }
        .task(id: runtime.searchFocusRequest) {
            guard runtime.searchFocusRequest > 0 else { return }
            // Bonsplit keeps hidden tab content alive. Give the selected tab a
            // layout turn before asking AppKit to make its field first responder.
            await Task.yield()
            if !Task.isCancelled && isOnScreen() && runtime.takeSearchFocusRequest() {
                searchFocused = true
            }
        }
        .sheet(item: $folderEditor) { draft in
            SessionFolderEditorSheet(draft: draft) { folderEditor = nil }
                .environmentObject(store)
        }
        .confirmationDialog(
            pendingFolderDeletion.map { L10n.format("删除文件夹「%@」？", $0.name) } ?? "",
            isPresented: Binding(get: { pendingFolderDeletion != nil }, set: { if !$0 { pendingFolderDeletion = nil } }),
            presenting: pendingFolderDeletion
        ) { folder in
            Button("删除文件夹", role: .destructive) {
                if let open = runtime.openFolderID, SessionFolders.isWithin(open, folder.id, in: store.groups) {
                    runtime.openFolderID = folder.parentID
                }
                if runtime.selectedFolderID == folder.id { runtime.selectedFolderID = nil }
                store.deleteFolder(id: folder.id)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("其中的会话和子文件夹会移到上一层，不会被删除。")
        }
    }

    /// `‹ SSH 会话 › 父文件夹 › [icon] 名称 · 5 个会话 ✎ 🗑` on one line.
    @ViewBuilder
    private var heading: some View {
        HStack(spacing: 8) {
            if let folder = openFolder {
                breadcrumbs(to: folder)
                HStack(spacing: 7) {
                    SessionFolderIcon(image: ProfileIconStore.image(for: folder.id), size: 22)
                    Text(folder.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
                }
                .layoutPriority(1)
                Text(contentsSummary(of: folder.id))
                    .font(.system(size: 12)).foregroundStyle(SnakeStyle.muted)
                    .lineLimit(1)
                HStack(spacing: 2) {
                    Button { folderEditor = SessionFolderDraft(folder: folder) } label: { Image(systemName: "pencil") }
                        .help("编辑文件夹").accessibilityLabel("编辑文件夹")
                    Button { pendingFolderDeletion = folder } label: { Image(systemName: "trash") }
                        .help("删除文件夹").accessibilityLabel("删除文件夹")
                }
                .buttonStyle(SnakeIconButtonStyle())
            } else {
                Text("SSH 会话").font(.system(size: 17, weight: .bold)).lineLimit(1)
                Text(topLevelSummary)
                    .font(.system(size: 12)).foregroundStyle(SnakeStyle.muted)
                    .lineLimit(1)
                    .help("双击文件夹打开；按住卡片拖动可调整顺序，或把会话拖进文件夹。")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var topLevelSummary: String {
        let sessions = L10n.plural("%@ 个会话", count: store.profiles.count, store.profiles.count)
        guard !store.groups.isEmpty else { return sessions }
        return L10n.plural("%@ 个文件夹", count: store.groups.count, store.groups.count) + " · " + sessions
    }

    /// Every level above the open folder; each opens that level and accepts drops.
    private func breadcrumbs(to folder: SessionGroup) -> some View {
        let ancestors = SessionFolders.path(to: folder.parentID, in: store.groups)
        let levels: [(id: UUID?, title: String)] = [(nil, L10n.text("SSH 会话"))] + ancestors.map { ($0.id, $0.name) }
        return HStack(spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Button { runtime.openFolderID = level.id } label: {
                    HStack(spacing: 4) {
                        if index == 0 {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        }
                        Text(level.title).lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SnakeStyle.action)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(dropHighlight(.crumb(level.id)), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(frameReader(.crumb(level.id)))
                .help("打开这一层；把卡片拖到这里可移到这一层")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SnakeStyle.muted)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(openFolder == nil ? L10n.text("新建文件夹") : L10n.text("新建子文件夹"), systemImage: "folder.badge.plus") {
                folderEditor = SessionFolderDraft(parentID: openFolder?.id)
            }
            .buttonStyle(SnakeOutlineButtonStyle())
            newProfileButton
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Right click on empty space; cards keep their own menus.
    @ViewBuilder
    private var blankAreaMenu: some View {
        Button(openFolder == nil ? L10n.text("新建 SSH 会话") : L10n.text("在此文件夹新建 SSH 会话"),
               systemImage: "plus", action: onNewProfile)
        Button(openFolder == nil ? L10n.text("新建文件夹") : L10n.text("在此文件夹新建子文件夹"),
               systemImage: "folder.badge.plus") {
            folderEditor = SessionFolderDraft(parentID: openFolder?.id)
        }
        if let folder = openFolder {
            Section("当前文件夹") {
                Button("返回上一层", systemImage: "arrow.up") { runtime.openFolderID = folder.parentID }
                Button("编辑文件夹", systemImage: "pencil") { folderEditor = SessionFolderDraft(folder: folder) }
            }
        }
    }

    private var newProfileButton: some View {
        Button("新建会话", systemImage: "plus", action: onNewProfile)
            .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(SnakeStyle.muted)
            TextField(openFolder == nil ? L10n.text("搜索会话、IP、用户名或文件夹") : L10n.text("在此文件夹中搜索"),
                      text: $runtime.searchQuery)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("session-catalog-search")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(SnakeStyle.hairline, lineWidth: 1) }
        // Inside a folder the search field doubles as a wide "move up" target while
        // dragging. It is laid out before the drag starts, so its frame is in the
        // snapshot the drop is judged against.
        .background { if openFolder != nil { frameReader(.moveUp) } }
        .overlay { moveUpZone }
    }

    @ViewBuilder
    private var moveUpZone: some View {
        if activePress != nil, let folder = openFolder {
            let parentName = folder.parentID.flatMap { id in store.groups.first { $0.id == id }?.name }
                ?? L10n.text("SSH 会话")
            let targeted = dropIntent == .into(folder.parentID)
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.to.line")
                Text(L10n.format("拖到这里，移到上一层「%@」", parentName)).lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(SnakeStyle.action)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(targeted ? SnakeStyle.action.opacity(0.18) : SnakeStyle.raisedSurface, in: shape)
            .overlay { shape.stroke(SnakeStyle.action, style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: targeted ? [] : [6, 4])) }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func content(columns: [GridItem]) -> some View {
        if store.profiles.isEmpty && store.groups.isEmpty {
            emptyState(symbol: "server.rack", title: L10n.text("暂无 SSH 会话"),
                       detail: L10n.text("新建会话，保存连接信息后即可打开终端或 SFTP。"), showsNewButton: true)
        } else if isSearching {
            // Search spans the open folder and everything inside it (or everything at the top level).
            let results = sortedProfiles.filter { profile in
                (openFolder.map { SessionFolders.isWithin(profile.groupID, $0.id, in: store.groups) } ?? true)
                    && SessionFolders.matches(profile, query: runtime.searchQuery, folderName: store.folderName(for: profile))
            }
            if results.isEmpty {
                emptyState(symbol: "magnifyingglass", title: L10n.text("没有匹配的会话"),
                           detail: L10n.text("试试其他名称、地址、用户名或文件夹。"), showsNewButton: false)
            } else {
                section(L10n.text("搜索结果")) { profileGrid(results, columns: columns, showsFolder: true) }
            }
        } else {
            let folders = displayed(store.childFolders(of: openFolder?.id)) { CatalogItem.folder($0.id) }
            let sessions = displayed(profiles(in: openFolder?.id)) { CatalogItem.profile($0.id) }
            if folders.isEmpty && sessions.isEmpty {
                emptyState(symbol: "folder", title: L10n.text("文件夹是空的"),
                           detail: L10n.text("在这里新建会话或文件夹，或回到上一层把会话拖到这个文件夹上。"), showsNewButton: true)
            }
            if !folders.isEmpty {
                section(L10n.text("文件夹")) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(folders) { folder in
                            draggable(.folder(folder.id)) { folderCard(folder) }
                        }
                    }
                    .animation(Self.reorderAnimation, value: folders.map(\.id))
                }
            }
            if !sessions.isEmpty {
                section(L10n.text("会话")) { profileGrid(sessions, columns: columns, showsFolder: false) }
            }
        }
    }

    private func contentsSummary(of folderID: UUID) -> String {
        let sessions = L10n.plural("%@ 个会话", count: profiles(in: folderID).count, profiles(in: folderID).count)
        let subfolders = store.childFolders(of: folderID).count
        guard subfolders > 0 else { return sessions }
        return L10n.plural("%@ 个文件夹", count: subfolders, subfolders) + " · " + sessions
    }

    private func folderCard(_ folder: SessionGroup) -> some View {
        SessionFolderCard(
            folder: folder,
            summary: contentsSummary(of: folder.id),
            selected: runtime.selectedFolderID == folder.id,
            isDropTarget: dropIntent == .into(folder.id),
            onSelect: {
                runtime.selectedFolderID = folder.id
                runtime.selectedProfileID = nil
            },
            onOpen: { openFolder(folder.id) },
            onEdit: { folderEditor = SessionFolderDraft(folder: folder) },
            onDelete: { pendingFolderDeletion = folder }
        )
    }

    private func profileCard(_ profile: SSHProfile, showsFolder: Bool) -> some View {
        SessionProfileCard(
            profile: profile,
            folderName: showsFolder ? (store.folderName(for: profile) ?? L10n.text("未放入文件夹")) : nil,
            selected: runtime.selectedProfileID == profile.id,
            onSelect: {
                runtime.selectedProfileID = profile.id
                runtime.selectedFolderID = nil
            },
            onEdit: { onEdit(profile) },
            onConnect: { onConnect(profile, $0) }
        )
    }

    private func openFolder(_ id: UUID) {
        runtime.selectedFolderID = id
        runtime.openFolderID = id
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SnakeStyle.muted)
            content()
        }
    }

    private func profileGrid(_ profiles: [SSHProfile], columns: [GridItem], showsFolder: Bool) -> some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(profiles) { profile in
                draggable(.profile(profile.id)) { profileCard(profile, showsFolder: showsFolder) }
            }
        }
        .animation(Self.reorderAnimation, value: profiles.map(\.id))
    }

    private func emptyState(symbol: String, title: String, detail: String, showsNewButton: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28))
            Text(title).font(.headline)
            Text(detail).foregroundStyle(SnakeStyle.muted).multilineTextAlignment(.center)
            if showsNewButton { newProfileButton }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
    }

    private var sortedProfiles: [SSHProfile] {
        store.profiles.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            return $0.sortOrder < $1.sortOrder
        }
    }

    /// `nil` lists sessions outside every folder, including ones whose folder vanished.
    private func profiles(in folderID: UUID?) -> [SSHProfile] {
        sortedProfiles.filter { profile in
            guard let folderID else {
                return profile.groupID.map { id in !store.groups.contains { $0.id == id } } ?? true
            }
            return profile.groupID == folderID
        }
    }

    // MARK: - Dragging

    private func frameReader(_ item: CatalogItem) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: CatalogFrameKey.self, value: [item: proxy.frame(in: .named(Self.space))])
        }
    }

    /// Search results mix folders, so they have no order to drag within.
    private func draggable<Content: View>(_ item: CatalogItem, @ViewBuilder content: () -> Content) -> some View {
        content()
            .background(frameReader(item))
            // The lifted card's slot stays as a faint placeholder where it would land.
            .opacity(activePress?.item == item ? 0.25 : 1)
            .simultaneousGesture(cardDrag(item), including: isSearching ? .subviews : .all)
    }

    /// A plain drag rather than LongPressGesture + DragGesture: the long press
    /// failed whenever the hand drifted ~10pt while holding, which made picking
    /// a card up unreliable. `SessionFolders.dragActivates` decides when it lifts.
    private func cardDrag(_ item: CatalogItem) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .updating($press) { value, state, _ in
                var current = state ?? CatalogPress(item: item, started: value.time, frames: frames)
                current.translation = value.translation
                current.location = value.location
                if !current.isActive {
                    current.isActive = SessionFolders.dragActivates(
                        distance: hypot(value.translation.width, value.translation.height),
                        held: value.time.timeIntervalSince(current.started)
                    )
                }
                let hover = current.isActive ? rawIntent(for: current) : nil
                if hover != current.hoverIntent {
                    current.hoverIntent = hover
                    current.hoverSince = value.time
                }
                state = current
            }
            .onEnded { value in
                // A click (or a hold without travel) is not a drop, whatever the old frames say.
                let travelled = hypot(value.translation.width, value.translation.height)
                guard press?.isActive == true || travelled >= 6 else { return }
                // Recompute against the frames frozen when this press began.
                // Cards slid aside during the drag, so live frames no longer match what the user saw.
                var finished = CatalogPress(item: item, started: .distantPast, frames: press?.frames ?? dragFrames)
                finished.location = value.location
                finished.isActive = true
                // Dropping where the cards have not slid aside yet changes nothing, as it looks.
                guard let intent = rawIntent(for: finished) else { return }
                if case .reorder = intent, settledHover?.intent != intent { return }
                withAnimation(Self.reorderAnimation) { drop(item, intent: intent) }
            }
    }

    /// A reorder still waiting for the pointer to rest, keyed so a new target restarts the wait.
    private var pendingHover: CatalogHover? {
        guard let press = activePress, let intent = press.hoverIntent, case .reorder = intent else { return nil }
        return CatalogHover(intent: intent, since: press.hoverSince)
    }

    /// What a drop would do now: moving into a folder shows at once, reordering
    /// only after the pointer has rested (`reorderDwell`).
    private var dropIntent: CatalogDropIntent? {
        guard let press = activePress, let intent = press.hoverIntent else { return nil }
        if case .reorder = intent {
            return settledHover == CatalogHover(intent: intent, since: press.hoverSince) ? intent : nil
        }
        return intent
    }

    private func rawIntent(for press: CatalogPress) -> CatalogDropIntent? {
        // Half the grid spacing around each card, so the gaps between cards count too.
        guard let (target, frame) = press.frames.first(where: { item, frame in
            item != press.item && frame.insetBy(dx: -8, dy: -8).contains(press.location)
        }) else { return nil }
        switch (press.item, target) {
        case (.profile, .profile):
            return .reorder(onto: target)
        case (.profile(let id), .folder(let folderID)):
            return store.profiles.first { $0.id == id }?.groupID == folderID ? nil : .into(folderID)
        case (.folder(let dragged), .folder(let folderID)):
            // Most of a folder card (the middle 70%) moves the dragged folder inside
            // it; only the outer edges reorder, so aiming at a folder is easy.
            let middle = frame.insetBy(dx: frame.width * 0.15, dy: 0)
            if middle.contains(press.location), !SessionFolders.isWithin(folderID, dragged, in: store.groups) {
                return .into(folderID)
            }
            return .reorder(onto: target)
        case (.profile(let id), .crumb(let level)):
            return store.profiles.first { $0.id == id }?.groupID == level ? nil : .into(level)
        case (.folder(let id), .crumb(let level)):
            let parent = store.groups.first { $0.id == id }?.parentID
            return parent == level ? nil : .into(level)
        case (.profile, .moveUp), (.folder, .moveUp):
            // Only shown inside a folder: the dragged card leaves for the level above.
            guard let folder = openFolder else { return nil }
            return .into(folder.parentID)
        default:
            return nil
        }
    }

    /// While a card is held over a sibling, the list shows the order it would
    /// drop into, and the grid animates the others aside.
    private func displayed<Element>(_ elements: [Element], item: (Element) -> CatalogItem) -> [Element] {
        guard case .reorder(let target) = dropIntent, let press = activePress else { return elements }
        let ids = elements.map(item)
        guard ids.contains(press.item), ids.contains(target) else { return elements }
        let order = SessionFolders.moving(press.item, onto: target, in: ids)
        return order.compactMap { id in elements.first { item($0) == id } }
    }

    private func dropHighlight(_ item: CatalogItem) -> Color {
        if case .crumb(let level) = item, dropIntent == .into(level) {
            return SnakeStyle.action.opacity(0.16)
        }
        return .clear
    }

    private func drop(_ item: CatalogItem, intent: CatalogDropIntent) {
        switch (item, intent) {
        case let (.folder(id), .reorder(.folder(targetID))):
            let siblings = store.childFolders(of: store.groups.first { $0.id == id }?.parentID).map(\.id)
            store.reorderFolders(SessionFolders.moving(id, onto: targetID, in: siblings))
        case let (.profile(id), .reorder(.profile(targetID))):
            let siblings = profiles(in: store.profiles.first { $0.id == id }?.groupID).map(\.id)
            store.reorderProfiles(SessionFolders.moving(id, onto: targetID, in: siblings))
        case let (.profile(id), .into(folderID)):
            store.move(profileID: id, to: folderID)
        case let (.folder(id), .into(folderID)):
            store.moveFolder(id: id, to: folderID)
        default:
            break
        }
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let press = activePress, let frame = press.frames[press.item] {
            Group {
                switch press.item {
                case .folder(let id):
                    if let folder = store.groups.first(where: { $0.id == id }) { folderCard(folder) }
                case .profile(let id):
                    if let profile = store.profiles.first(where: { $0.id == id }) { profileCard(profile, showsFolder: false) }
                case .crumb, .moveUp:
                    EmptyView()
                }
            }
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(1.03)
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .offset(x: frame.minX + press.translation.width, y: frame.minY + press.translation.height)
            .allowsHitTesting(false)
        }
    }
}

private struct SessionFolderIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.43, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SnakeStyle.action)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

private struct SessionFolderCard: View {
    @EnvironmentObject private var store: ApplicationStore
    let folder: SessionGroup
    let summary: String
    let selected: Bool
    /// A dragged card would move into this folder if dropped now.
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 12) {
            SessionFolderIcon(image: ProfileIconStore.image(for: folder.id), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(summary)
                    .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SnakeStyle.muted)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: SessionCatalogMetrics.cardHeight)
        .background(isDropTarget ? SnakeStyle.action.opacity(0.14)
                    : (selected ? SnakeStyle.selectedRow.opacity(0.55) : SnakeStyle.raisedSurface), in: shape)
        .overlay {
            shape.stroke(isDropTarget || selected ? SnakeStyle.action : (hovering ? SnakeStyle.action.opacity(0.45) : SnakeStyle.hairline),
                         lineWidth: isDropTarget ? 2.5 : (selected ? 1.5 : 1))
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        // Select at once rather than after the double-click timeout, as session cards do.
        .onTapGesture(count: 2) {
            onSelect()
            onOpen()
        }
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .snakeContextMenu {
            Button("打开", systemImage: "folder", action: onOpen)
            Section("管理") {
                Button("编辑文件夹", systemImage: "pencil", action: onEdit)
                Menu {
                    destination(L10n.text("最外层"), parentID: nil)
                    let targets = store.folderPaths.filter { !SessionFolders.isWithin($0.folder.id, folder.id, in: store.groups) }
                    if !targets.isEmpty { Divider() }
                    ForEach(targets, id: \.folder.id) { target in
                        destination(target.path, parentID: target.folder.id)
                    }
                } label: {
                    Label("移到文件夹", systemImage: "arrowshape.turn.up.right")
                }
            }
            Divider()
            Button("删除文件夹", systemImage: "trash", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("打开"), onOpen)
    }
}

extension SessionFolderCard {
    @ViewBuilder
    fileprivate func destination(_ title: String, parentID: UUID?) -> some View {
        Button {
            store.moveFolder(id: folder.id, to: parentID)
        } label: {
            if folder.parentID == parentID { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(folder.parentID == parentID)
    }
}

/// `folderID == nil` creates a folder inside `parentID`; otherwise edits that one.
private struct SessionFolderDraft: Identifiable {
    let id = UUID()
    let folderID: UUID?
    let parentID: UUID?
    let name: String

    init(folder: SessionGroup) {
        folderID = folder.id
        parentID = folder.parentID
        name = folder.name
    }

    init(parentID: UUID?) {
        folderID = nil
        self.parentID = parentID
        name = ""
    }
}

private struct SessionFolderEditorSheet: View {
    @EnvironmentObject private var store: ApplicationStore
    let draft: SessionFolderDraft
    let onClose: () -> Void
    @State private var name: String
    @State private var iconData: Data?
    @State private var iconChanged = false
    @State private var cropSource: ProfileIconCropSource?
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(draft: SessionFolderDraft, onClose: @escaping () -> Void) {
        self.draft = draft
        self.onClose = onClose
        _name = State(initialValue: draft.name)
        _iconData = State(initialValue: draft.folderID.flatMap(ProfileIconStore.data(for:)))
    }

    private var validName: String? {
        SessionFolders.validatedName(name, among: store.groups, parentID: draft.parentID, excluding: draft.folderID)
    }

    private var isDuplicate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validName == nil
    }

    var body: some View {
        SnakeEditorSheet(
            context: L10n.text("SSH 会话"),
            title: draft.folderID == nil ? L10n.text("新建文件夹") : L10n.text("编辑文件夹"),
            width: 480,
            height: 400,
            onClose: onClose
        ) {
            EditorSection(L10n.text("名称"), footnote: isDuplicate ? L10n.text("已有同名文件夹。") : nil) {
                TextField(L10n.text("例如 生产服务器"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(save)
            }
            EditorSection(L10n.text("图标")) {
                HStack(spacing: 14) {
                    SessionFolderIcon(image: iconData.flatMap(NSImage.init(data:)), size: 56)
                    VStack(alignment: .leading, spacing: 8) {
                        Button("选择图片…", systemImage: "photo") { chooseImage() }
                            .buttonStyle(SnakeOutlineButtonStyle())
                        if iconData != nil {
                            Button("恢复默认图标") {
                                iconData = nil
                                iconChanged = true
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red) }
        } leading: {
            Button("取消", action: onClose).buttonStyle(SnakeOutlineButtonStyle())
        } trailing: {
            Button(draft.folderID == nil ? L10n.text("创建") : L10n.text("保存"), action: save)
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
                .disabled(validName == nil)
        }
        .onAppear { focused = true }
        .sheet(item: $cropSource) { source in
            ProfileIconCropView(image: source.image) { data in
                iconData = data
                iconChanged = true
                cropSource = nil
            } onCancel: {
                cropSource = nil
            }
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = L10n.text("选择照片")
        panel.begin { response in
            guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
            Task { @MainActor in cropSource = ProfileIconCropSource(image: image) }
        }
    }

    private func save() {
        guard validName != nil else { return }
        let folderID: UUID?
        if let existing = draft.folderID {
            folderID = store.renameFolder(id: existing, to: name) ? existing : nil
        } else {
            folderID = store.createFolder(named: name, in: draft.parentID)?.id
        }
        guard let folderID else { return }
        if iconChanged {
            do {
                try store.setFolderIcon(iconData, for: folderID)
            } catch {
                errorMessage = L10n.format("文件夹已保存，但图标未能保存：%@", error.localizedDescription)
                return
            }
        }
        onClose()
    }
}

/// Shared by folder and session cards so both grids line up.
private enum SessionCatalogMetrics {
    static let cardHeight: CGFloat = 58
}

private struct SessionProfileCard: View {
    @EnvironmentObject private var store: ApplicationStore
    let profile: SSHProfile
    /// Shown only where cards from different folders mix, i.e. search results.
    let folderName: String?
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onConnect: (Bool) -> Void
    @State private var confirmsDeletion = false
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 12) {
            ProfileIconView(profile: profile, size: 34, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(profile.connectionLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SnakeStyle.muted).lineLimit(1).truncationMode(.middle)
                if let folderName {
                    Label(folderName, systemImage: "folder")
                        .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: SessionCatalogMetrics.cardHeight)
        .background(selected ? SnakeStyle.selectedRow.opacity(0.55) : SnakeStyle.raisedSurface, in: shape)
        .overlay {
            shape.stroke(selected ? SnakeStyle.action : (hovering ? SnakeStyle.action.opacity(0.45) : SnakeStyle.hairline),
                         lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(shape)
        .onHover { hovering = $0 }
        // Double-click opens a terminal; SFTP lives in the context menu. Selection must
        // not wait for the system double-click timeout, so a single tap selects at once.
        .onTapGesture(count: 2) {
            onSelect()
            onConnect(false)
        }
        .simultaneousGesture(TapGesture().onEnded {
            onSelect()
        })
        .snakeContextMenu {
            Button("打开终端", systemImage: "terminal") { onConnect(false) }
            Button("打开 SFTP", systemImage: "folder") { onConnect(true) }
            Section("管理") {
                Button("编辑会话", systemImage: "pencil", action: onEdit)
                Button("复制 SSH 命令", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TerminalContextMenu.sshCommand(for: profile), forType: .string)
                }
                Menu {
                    folderChoice(L10n.text("不放入文件夹"), folderID: nil)
                    if !store.groups.isEmpty { Divider() }
                    ForEach(store.folderPaths, id: \.folder.id) { target in
                        folderChoice(target.path, folderID: target.folder.id)
                    }
                } label: {
                    Label("移到文件夹", systemImage: "arrowshape.turn.up.right")
                }
            }
            Divider()
            Button("删除会话", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
        }
        .alert("删除 SSH 会话？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { store.delete(profile: profile) }
        } message: {
            Text("将关闭相关终端和 SFTP 连接、禁用关联映射，并删除该会话保存的凭据。同时清理该会话已下载的远程文件副本，仅限 Snake 自己缓存的副本，不会改动目录中的其他内容。")
        }
    }
}

extension SessionProfileCard {
    @ViewBuilder
    fileprivate func folderChoice(_ title: String, folderID: UUID?) -> some View {
        let current = profile.groupID.flatMap { id in store.groups.contains { $0.id == id } ? id : nil }
        Button {
            store.move(profileID: profile.id, to: folderID)
        } label: {
            if current == folderID { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .disabled(current == folderID)
    }
}

private struct ProfileIconView: View {
    let profile: SSHProfile
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if profile.usesCustomIcon, let image = ProfileIconStore.image(for: profile.id) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Image(systemName: profile.usesCustomIcon ? "server.rack" : profile.symbolName)
                    .font(.system(size: size * 0.47, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SnakeStyle.iconTint(for: profile))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(profile.usesCustomIcon ? 0.24 : 0), lineWidth: 0.75)
        }
    }
}

private struct WorkspaceView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var windowState: WorkspaceWindowState

    var body: some View {
        BonsplitView(controller: windowState.bonsplit) { tab, paneID in
            if let runtime = windowState.tabs[tab.id] {
                WorkspaceTabContent(runtime: runtime, windowState: windowState, tabID: tab.id, paneID: paneID)
                    .environmentObject(store)
            }
        } emptyPane: { paneID in
            VStack(spacing: 14) {
                Image(systemName: "square.grid.2x2").font(.system(size: 28))
                Text("打开会话开始工作").font(.headline)
                Button("打开 SSH 会话") {
                    windowState.openManager(.sessions, to: paneID)
                }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SnakeStyle.canvas)
        }
        .background(SnakeStyle.canvas)
    }
}

private struct WorkspaceTabContent: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: WorkspaceTabRuntime
    @ObservedObject var windowState: WorkspaceWindowState
    let tabID: TabID
    let paneID: PaneID
    @State private var creatingProfile = false
    @State private var editingProfile: SSHProfile?
    @State private var creatingMapping = false
    @State private var editingMapping: MountMapping?
    @State private var connectionError: String?

    var body: some View {
        Group {
            switch runtime.kind {
            case .sessions:
                SessionCatalogView(runtime: runtime, onEdit: { editingProfile = $0 }, onNewProfile: { creatingProfile = true }, onConnect: { profile, asSFTP in
                    guard runtime.kind == .sessions else { return }
                    if !windowState.connectChooser(tabID: tabID, profileID: profile.id, asSFTP: asSFTP, store: store) {
                        connectionError = L10n.text("该会话已不可用，请刷新会话列表后重试。")
                    }
                }, isOnScreen: {
                    windowState.tabs[tabID] === runtime && windowState.bonsplit.selectedTab(inPane: paneID)?.id == tabID
                })
            case .mounts:
                MountWorkspaceView(runtime: runtime, onNewMapping: { creatingMapping = true }, onEditMapping: { editingMapping = $0 })
            case .mcp:
                McpSettingsPane(mcp: store.mcp)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SnakeStyle.canvas)
            case .passwords:
                PasswordManagerPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .terminal, .sftp:
                FinderUploadSurface(
                    content: connectionContent
                        .environmentObject(store)
                        .environment(\.locale, store.appLanguage.locale),
                    runtimeID: runtime.id,
                    isActive: {
                        windowState.tabs[tabID] === runtime && windowState.bonsplit.selectedTab(inPane: paneID)?.id == tabID
                    },
                    target: { runtime.finderUploadTarget },
                    perform: { urls, target, window in
                        windowState.bonsplit.focusPane(paneID)
                        runtime.uploadFromFinder(urls: urls, target: target, window: window, store: store)
                    },
                    identity: "\(runtime.kind) \(runtime.profile?.name ?? "-") runtime=\(runtime.id.rawValue.uuidString.prefix(8))"
                )
            }
        }
        // Keep each tab's content on its own SwiftUI identity: Bonsplit renders every
        // tab at once (`keepAllAlive`), and a shared identity could let one tab's view
        // carry another tab's drop closures.
        .id(tabID)
        .sheet(isPresented: $creatingProfile) {
            SessionEditorView(profile: nil, defaultFolderID: runtime.openFolderID).environmentObject(store)
        }
        .sheet(item: $editingProfile) { SessionEditorView(profile: $0).environmentObject(store) }
        .sheet(isPresented: $creatingMapping) { MappingEditorView(mapping: nil).environmentObject(store) }
        .sheet(item: $editingMapping) { MappingEditorView(mapping: $0).environmentObject(store) }
        .alert("无法打开会话", isPresented: Binding(get: { connectionError != nil }, set: { if !$0 { connectionError = nil } })) {
            Button("确定") { connectionError = nil }
        } message: { Text(connectionError ?? "") }
    }

    @ViewBuilder
    private var connectionContent: some View {
        if let terminal = runtime.terminal { TerminalTabView(runtime: terminal) }
        else if let sftp = runtime.sftp {
            SFTPBrowserView(runtime: sftp, isOnScreen: {
                windowState.tabs[tabID] === runtime && windowState.bonsplit.selectedTab(inPane: paneID)?.id == tabID
            })
        }
    }
}

private struct ConnectionBelt: View {
    @EnvironmentObject private var store: ApplicationStore
    let profile: SSHProfile
    let state: ConnectionState
    let securityInfo: CoreConnectionSecurity?
    let currentPath: String?
    @ObservedObject var uploader: LocalUploadCoordinator

    var dark = true
    @State private var showingSecurityDetails = false
    @State private var beltWidth: CGFloat = 800

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            if beltWidth >= 360 {
                Text(state == .idle ? L10n.text("待连接") : state.label)
                    .fontWeight(.semibold)
            }
            Rectangle().fill((dark ? Color.white : Color.primary).opacity(0.16)).frame(width: 1, height: 13)
            Text(profile.connectionLabel)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            UploadStatusEntry(uploader: uploader, contextName: L10n.text("终端"), showsLabel: false)
                .layoutPriority(2)
            if beltWidth >= 440, let currentPath {
                Rectangle().fill((dark ? Color.white : Color.primary).opacity(0.16)).frame(width: 1, height: 13)
                Text(currentPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(dark ? SnakeStyle.terminalText.opacity(0.66) : SnakeStyle.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button {
                showingSecurityDetails.toggle()
            } label: {
                Image(systemName: securityInfo == nil ? "lock" : "lock.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(securityInfo == nil ? SnakeStyle.muted : SnakeStyle.secure)
            .disabled(securityInfo == nil)
            .help(securityInfo == nil ? L10n.text("连接后可查看安全详情") : L10n.text("查看连接安全详情"))
            .popover(isPresented: $showingSecurityDetails, arrowEdge: .bottom) {
                if let securityInfo {
                    ConnectionSecurityDetails(security: securityInfo)
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(dark ? SnakeStyle.terminalText.opacity(0.9) : SnakeStyle.ink)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(dark ? SnakeStyle.terminalBelt : SnakeStyle.chromeFrost)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { beltWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in beltWidth = width }
            }
        }
    }

    private var stateColor: Color {
        switch state {
        case .connected: SnakeStyle.secure
        case .connecting: .orange
        case .failed: .red
        case .disconnected, .idle: .secondary
        }
    }
}

private struct ConnectionSecurityDetails: View {
    let security: CoreConnectionSecurity

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SnakeStyle.secure)
                VStack(alignment: .leading, spacing: 1) {
                    Text("连接安全详情")
                        .font(.system(size: 13, weight: .semibold))
                    Text("本次 SSH 握手实际协商结果")
                        .font(.system(size: 10))
                        .foregroundStyle(SnakeStyle.muted)
                }
            }
            .padding(.bottom, 12)

            securityRow(L10n.text("主机密钥"), security.hostKeyAlgorithm)
            VStack(alignment: .leading, spacing: 4) {
                Text("SHA256 指纹")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SnakeStyle.muted)
                Text(security.hostKeyFingerprint)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)

            Divider()
            securityRow(L10n.text("密钥交换"), security.keyExchangeAlgorithm)
            securityRow(L10n.text("发送加密"), security.clientToServerCipher)
            securityRow(L10n.text("接收加密"), security.serverToClientCipher)
            securityRow(L10n.text("发送完整性"), integrityLabel(security.clientToServerMac, cipher: security.clientToServerCipher))
            securityRow(L10n.text("接收完整性"), integrityLabel(security.serverToClientMac, cipher: security.serverToClientCipher))
        }
        .padding(14)
        .frame(width: 380)
        .background(SnakeStyle.raisedSurface)
    }

    private func securityRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SnakeStyle.muted)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private func integrityLabel(_ mac: String?, cipher: String) -> String {
        if let mac, !mac.isEmpty { return mac }
        let normalized = cipher.lowercased()
        if normalized.contains("gcm") || normalized.contains("poly1305") {
            return L10n.text("由加密算法内置")
        }
        return L10n.text("服务器未报告")
    }
}

private struct TerminalTabView: View {
    @ObservedObject var runtime: TerminalRuntime
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.colorScheme) private var colorScheme

    /// The card stays after a failed attempt (unless a host key prompt is up).
    private var showsConnectionCard: Bool {
        switch runtime.state {
        case .connecting: true
        case .connected: runtime.awaitingFirstOutput
        case .failed: runtime.pendingHostKey == nil && runtime.errorMessage != nil
        default: false
        }
    }


    var body: some View {
        VStack(spacing: 0) {
            ConnectionBelt(
                profile: runtime.profile,
                state: runtime.state,
                securityInfo: runtime.securityInfo,
                currentPath: runtime.currentRemoteDirectory,
                uploader: runtime.uploader,

                dark: colorScheme == .dark
            )
            if let error = runtime.uploader.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if runtime.launchRequested {
                if runtime.state == .disconnected, let error = runtime.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).lineLimit(2)
                        Spacer()
                        Button("重试") { runtime.retryConnection() }
                            .buttonStyle(SnakeOutlineButtonStyle())
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(terminalForeground.opacity(0.86))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 38)
                    .background(Color.orange.opacity(0.14))
                }
                TerminalHost(
                    runtime: runtime,
                    theme: terminalTheme,
                    fontName: store.terminalFontName,
                    fontSize: store.terminalFontSize,
                    usesMetal: store.terminalMetalRenderingEnabled,
                    store: store
                )
                    // Keep text off the window edges; the inset uses the theme background.
                    .padding(.leading, 12)
                    .padding(.trailing, 4)
                    .padding(.vertical, 8)
                    .background(terminalBackground)
                    .background(FinderUploadArea())
                    .overlay {
                        if showsConnectionCard {
                            ConnectingAnimation(
                                title: runtime.profile.name,
                                detail: runtime.profile.connectionLabel,
                                status: runtime.connectionStatusText,
                                foreground: terminalForeground,
                                surface: terminalForeground.opacity(0.07),
                                backdrop: terminalBackground,
                                failure: runtime.state == .failed ? runtime.errorMessage : nil,
                                onCancel: runtime.state == .connecting ? { runtime.cancelConnecting() } : nil,
                                onRetry: { runtime.retryConnection() },
                                onShowLog: { runtime.showsLog = true }
                            )
                            .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: showsConnectionCard)
                    .sheet(isPresented: $runtime.showsLog) {
                        ConnectionLogSheet(log: runtime.log, title: runtime.profile.name, onClose: { runtime.showsLog = false })
                    }
            } else {
                TerminalPreview(runtime: runtime, theme: terminalTheme)
            }
        }
        .background {
            EmptyView().alert("远程文件已存在", isPresented: Binding(
                get: { runtime.uploader.pendingConflict != nil },
                set: { if !$0 { runtime.uploader.resolveConflict(.cancel) } }
            )) {
                Button("取消上传", role: .cancel) { runtime.uploader.resolveConflict(.cancel) }
                Button("跳过") { runtime.uploader.resolveConflict(.skip) }
                Button("安全覆盖", role: .destructive) { runtime.uploader.resolveConflict(.overwrite) }
            } message: {
                Text(L10n.format("%@ 已存在。覆盖会在上传完整后替换原文件。", runtime.uploader.pendingConflict?.remotePath ?? ""))
            }
        }

        .alert(runtime.pendingHostKey?.title ?? L10n.text("确认主机密钥"), isPresented: Binding(
            get: { runtime.pendingHostKey != nil },
            set: { if !$0, runtime.pendingHostKey != nil { runtime.rejectPendingHostKey() } }
        )) {
            Button("取消", role: .cancel) { runtime.rejectPendingHostKey() }
            Button(runtime.pendingHostKey?.acceptTitle ?? L10n.text("信任并连接")) { runtime.acceptPendingHostKey() }
        } message: {
            if let key = runtime.pendingHostKey {
                Text(key.message)
            }
        }
    }

    private var terminalTheme: TerminalTheme {
        store.terminalTheme(isDark: colorScheme == .dark)
    }
    private var terminalForeground: Color { Color(nsColor: TerminalTheme.nsColor(terminalTheme.foregroundHex)) }
    private var terminalBackground: Color { Color(nsColor: TerminalTheme.nsColor(terminalTheme.backgroundHex)) }

}

private struct TerminalPreview: View {
    @ObservedObject var runtime: TerminalRuntime
    let theme: TerminalTheme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(foreground.opacity(0.46))
            Text(runtime.profile.connectionLabel)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(foreground.opacity(0.72))
            Text("尚未建立 SSH 连接")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.48))
            Button("开始连接") { runtime.requestConnection() }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: TerminalTheme.nsColor(theme.backgroundHex)))
    }

    private var foreground: Color { Color(nsColor: TerminalTheme.nsColor(theme.foregroundHex)) }
}

private struct SFTPBrowserView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: SFTPRuntime
    /// Whether this tab is the one on screen in its pane; Finder drops are refused
    /// otherwise, because every tab's content stays alive in the hierarchy.
    var isOnScreen: () -> Bool = { true }

    /// The card stays after a failed connection (unless a host key prompt is up).
    private var showsConnectionCard: Bool {
        switch runtime.connectionState {
        case .connecting: true
        case .failed: runtime.pendingHostKey == nil && runtime.errorMessage != nil
        default: false
        }
    }
    @State private var creationKind: RemoteItemCreationKind?
    @State private var creationDestination: SFTPDirectoryDestination?
    @State private var newItemName = ""
    @State private var pathDraft = "/"
    @State private var searchQuery = ""
    @State private var isSearchPresented = false
    @State private var navigationNotice: String?
    @State private var navigationNoticeID = UUID()
    @State private var showsLog = false
    @FocusState private var isEditingPath: Bool
    @FocusState private var isEditingSearch: Bool

    var body: some View {
        VStack(spacing: 0) {
            navigationBar

            if isSearchPresented { searchBar }

            if runtime.connectionState != .connecting, let loadingPath = runtime.loadingPath {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.format("正在打开 %@", loadingPath))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(SnakeStyle.action.opacity(0.07))
            } else if let navigationNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(SnakeStyle.action)
                    Text(navigationNotice)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(SnakeStyle.action.opacity(0.07))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let notice = runtime.shortcutNotice {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(SnakeStyle.action)
                    Text(notice)
                    Spacer()
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(SnakeStyle.action.opacity(0.07))
            } else if let error = runtime.deletionError
                        ?? (runtime.connectionState == .failed ? nil : runtime.errorMessage)
                        ?? runtime.uploader.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(2).help(error)
                    Spacer()
                    Button(runtime.deletionError == nil ? L10n.text("重试") : L10n.text("知道了")) {
                        if runtime.deletionError != nil { runtime.dismissDeletionError() }
                        else { runtime.retryLastOperation() }
                    }
                        .buttonStyle(SnakeOutlineButtonStyle())
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .background(Color.orange.opacity(0.08))
            }

            SFTPFileTable(
                runtime: runtime,
                searchQuery: searchQuery,
                isOnScreen: isOnScreen,
                onFocusFiles: {
                    isEditingPath = false
                    isEditingSearch = false
                },
                onOpen: open,
                onCreateFile: { beginCreation(.file) },
                onCreateDirectory: { beginCreation(.directory) },
                onUploadFiles: { chooseFiles(allowsDirectories: false) },
                onUploadDirectory: { chooseFiles(allowsDirectories: true) }
            )
            .overlay {
                if showsConnectionCard {
                    ConnectingAnimation(
                        title: runtime.profile.name,
                        detail: runtime.profile.connectionLabel,
                        status: L10n.text("正在建立安全 SFTP 连接…"),
                        failure: runtime.connectionState == .failed ? runtime.errorMessage : nil,
                        onCancel: { runtime.cancelConnecting() },
                        onRetry: { runtime.retryLastOperation() },
                        onShowLog: { showsLog = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(SnakeStyle.canvas.opacity(0.85))
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: showsConnectionCard)
            .sheet(isPresented: $showsLog) {
                ConnectionLogSheet(log: runtime.log, title: runtime.profile.name, onClose: { showsLog = false })
            }
        }
        .background(uploadConflictAlert)
        .sheet(item: Binding(get: { runtime.uploader.pendingDownloadConflict }, set: { if $0 == nil { runtime.uploader.resolveDownloadConflict(.cancel) } })) { conflict in
            DownloadConflictView(uploader: runtime.uploader, conflict: conflict)
        }
        .task { runtime.connectIfNeeded() }
        .onAppear { pathDraft = runtime.currentPath }
        .onChange(of: runtime.currentPath) { _, newPath in
            pathDraft = newPath
            endSearch()
        }
        .onChange(of: isEditingPath) { _, editing in
            if !editing { pathDraft = runtime.currentPath }
        }
        .onChange(of: searchQuery) { _, _ in
            runtime.fileSelection = SFTPSelection()
        }
        .onChange(of: runtime.connectionState) { _, state in
            if state != .connected { endSearch() }
        }
        .onChange(of: runtime.searchCommandRequest) { _, _ in beginSearch() }
        .alert(creationKind?.title ?? L10n.text("新建远程项目"), isPresented: Binding(
            get: { creationKind != nil },
            set: { if !$0 { creationKind = nil } }
        )) {
            TextField(creationKind?.placeholder ?? L10n.text("名称"), text: $newItemName)
            Button("取消", role: .cancel) {
                creationKind = nil
                newItemName = ""
            }
            Button("创建") {
                guard let destination = creationDestination else { return }
                if creationKind == .directory {
                    runtime.createDirectory(named: newItemName, in: destination.path)
                } else {
                    runtime.createFile(named: newItemName, in: destination.path)
                }
                creationKind = nil
                newItemName = ""
            }
        } message: {
            Text(L10n.format("将在 %@ 中创建。", creationDestination?.path ?? ""))
        }
        .alert(runtime.pendingHostKey?.title ?? L10n.text("确认主机密钥"), isPresented: Binding(
            get: { runtime.pendingHostKey != nil },
            set: { if !$0, runtime.pendingHostKey != nil { runtime.rejectPendingHostKey() } }
        )) {
            Button("取消", role: .cancel) { runtime.rejectPendingHostKey() }
            Button(runtime.pendingHostKey?.acceptTitle ?? L10n.text("信任并连接")) { runtime.acceptPendingHostKey() }
        } message: {
            if let key = runtime.pendingHostKey { Text(key.message) }
        }
    }

    private var navigationBar: some View {
        HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                    .help(runtime.connectionState.label)
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SFTPNavigationButtonStyle(isAvailable: runtime.canGoBack))
                    .help(runtime.canGoBack ? L10n.text("后退") : L10n.text("没有可回退的目录"))
                    .accessibilityLabel("后退")
                    .accessibilityHint(runtime.canGoBack ? L10n.text("返回上一个访问过的目录") : L10n.text("没有可回退的目录"))
                Button { goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(SFTPNavigationButtonStyle(isAvailable: runtime.canGoForward))
                    .help(runtime.canGoForward ? L10n.text("前进") : L10n.text("没有可前进的目录"))
                    .accessibilityLabel("前进")
                    .accessibilityHint(runtime.canGoForward ? L10n.text("前往下一个访问过的目录") : L10n.text("没有可前进的目录"))
                Button { navigateUp() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(SFTPNavigationButtonStyle(isAvailable: runtime.currentPath != "/"))
                    .help(runtime.currentPath == "/" ? L10n.text("已经位于顶级目录") : L10n.text("返回上一级"))
                    .accessibilityLabel("返回上一级")
                    .accessibilityHint(runtime.currentPath == "/" ? L10n.text("已经位于顶级目录") : L10n.text("打开父目录"))
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SnakeStyle.muted)
                    TextField("输入远程地址", text: $pathDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($isEditingPath)
                        .onSubmit { submitPath() }
                    if isEditingPath && pathDraft != runtime.currentPath {
                        Button { pathDraft = runtime.currentPath } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(SnakeStyle.muted)
                        .help("恢复当前地址")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isEditingPath ? SnakeStyle.action.opacity(0.72) : SnakeStyle.hairline, lineWidth: 1)
                }
                Button { runtime.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SnakeIconButtonStyle())
                    .help("刷新")
                    .disabled(runtime.connectionState == .connecting)
                Button { toggleSearch() } label: {
                    Image(systemName: searchQuery.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill")
                }
                    .buttonStyle(SnakeIconButtonStyle())
                    .foregroundStyle(searchQuery.isEmpty ? SnakeStyle.ink : SnakeStyle.action)
                    .help(isSearchPresented ? L10n.text("关闭检索") : L10n.text("检索当前目录"))
                    .accessibilityLabel(isSearchPresented ? L10n.text("关闭当前目录检索") : L10n.text("检索当前目录"))
                    .disabled(runtime.connectionState != .connected || runtime.loadingPath != nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(SnakeStyle.chromeFrost)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SnakeStyle.muted)
            TextField("检索当前目录", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isEditingSearch)
            Text(searchResultLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(SnakeStyle.muted)
                .fixedSize()
            if !searchQuery.isEmpty {
                Button { clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(SnakeStyle.muted)
                    .help("清除检索")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 32)
        .background(SnakeStyle.raisedSurface)
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onExitCommand { endSearch() }
    }

    private var uploadConflictAlert: some View {
        EmptyView()
            .alert("远程文件已存在", isPresented: Binding(
                get: { runtime.pendingUploadConflict != nil },
                set: { if !$0, runtime.pendingUploadConflict != nil { runtime.resolveUploadConflict(.cancel) } }
            )) {
                Button("取消上传", role: .cancel) { runtime.resolveUploadConflict(.cancel) }
                Button("跳过") { runtime.resolveUploadConflict(.skip) }
                Button("安全覆盖", role: .destructive) { runtime.resolveUploadConflict(.overwrite) }
            } message: {
                if let conflict = runtime.pendingUploadConflict {
                    Text(L10n.format("%@ 已存在。安全覆盖会先完成隐藏暂存文件，再通过 mv 替换原文件；传输中断不会损坏现有文件。", conflict.remotePath))
                }
            }
    }

    private var connectionColor: Color {
        switch runtime.connectionState {
        case .connected: SnakeStyle.secure
        case .connecting: .orange
        case .failed: .red
        case .disconnected, .idle: SnakeStyle.muted
        }
    }

    private func beginCreation(_ kind: RemoteItemCreationKind) {
        guard let destination = runtime.directoryActionDestination else { return }
        creationDestination = destination
        newItemName = ""
        creationKind = kind
    }

    private func submitPath() {
        runtime.navigate(to: pathDraft)
        isEditingPath = false
    }

    private var searchResultLabel: String {
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.plural("%@ 项", count: runtime.entries.count, runtime.entries.count)
        }
        return "\(SFTPEntrySearch.results(in: runtime.entries, query: searchQuery).count) / \(runtime.entries.count)"
    }

    private func toggleSearch() {
        if isSearchPresented {
            endSearch()
        } else {
            beginSearch()
        }
    }

    private func beginSearch() {
        guard runtime.connectionState == .connected, runtime.loadingPath == nil else { return }
        withAnimation(.easeOut(duration: 0.12)) { isSearchPresented = true }
        isEditingPath = false
        Task { @MainActor in isEditingSearch = true }
    }

    private func clearSearch() {
        searchQuery = ""
        isEditingSearch = true
    }

    private func endSearch() {
        isEditingSearch = false
        searchQuery = ""
        withAnimation(.easeIn(duration: 0.1)) { isSearchPresented = false }
    }

    private enum RemoteItemCreationKind {
        case file
        case directory

        var title: String { self == .directory ? L10n.text("新建远程文件夹") : L10n.text("新建远程文件") }
        var placeholder: String { self == .directory ? L10n.text("文件夹名称") : L10n.text("文件名称") }
    }

private struct SFTPFileTable: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: SFTPRuntime
    let searchQuery: String
    /// Whether the owning tab is the one on screen; a hidden table must not take drops.
    let isOnScreen: () -> Bool
    let onFocusFiles: () -> Void
    let onOpen: (RemoteFile) -> Void
    let onCreateFile: () -> Void
    let onCreateDirectory: () -> Void
    let onUploadFiles: () -> Void
    let onUploadDirectory: () -> Void
    @State private var receivesRemoteFile = false
    @State private var receivesFinderFiles = false
    @State private var renamingFile: RemoteFile?
    @State private var renameText = ""
    @State private var permissionsFile: RemoteFile?
    @State private var deletingFiles: [RemoteFile] = []
    @FocusState private var filesFocused: Bool

    private var visibleEntries: [RemoteFile] {
        SFTPEntrySearch.results(in: runtime.entries, query: searchQuery)
    }

    private var visibleEntryIDs: [UUID] { visibleEntries.map(\.id) }

    private var isFiltering: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text("名称").frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                    Text("大小").frame(width: 92, alignment: .leading)
                    Text("修改日期").frame(width: 125, alignment: .leading)
                    Text("权限").frame(width: 108, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("大小").frame(width: 70, alignment: .leading)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SnakeStyle.muted)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Color.primary.opacity(0.035))

            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleEntries) { file in
                            ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                HStack(spacing: 9) {
                                    Image(systemName: fileIcon(file))
                                        .foregroundStyle(file.isSymbolicLink ? SnakeStyle.secure : (file.isDirectory ? SnakeStyle.action.opacity(0.72) : SnakeStyle.muted))
                                        .frame(width: 17)
                                    Text(file.name).font(.system(size: 13, weight: file.isDirectory ? .semibold : .regular))
                                    if let target = file.linkTarget {
                                        Text("→ \(target)")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(SnakeStyle.muted)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                                Text(file.isSymbolicLink ? L10n.text("链接") : (file.isDirectory ? "—" : L10n.byteCount(file.size)))
                                    .frame(width: 92, alignment: .leading)
                                Text(file.modifiedAt, format: .dateTime.month().day().hour().minute())
                                    .frame(width: 125, alignment: .leading)
                                Text(file.permissions.isEmpty ? "—" : file.permissions)
                                    .frame(width: 108, alignment: .leading)
                            }
                            HStack(spacing: 8) {
                                HStack(spacing: 7) {
                                    Image(systemName: fileIcon(file))
                                        .foregroundStyle(file.isSymbolicLink ? SnakeStyle.secure : (file.isDirectory ? SnakeStyle.action.opacity(0.72) : SnakeStyle.muted))
                                    Text(file.name).font(.system(size: 12, weight: file.isDirectory ? .semibold : .regular)).lineLimit(1)
                                    if file.isSymbolicLink {
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.system(size: 9))
                                            .foregroundStyle(SnakeStyle.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(file.isSymbolicLink ? L10n.text("链接") : (file.isDirectory ? "—" : L10n.byteCount(file.size)))
                                    .frame(width: 70, alignment: .trailing)
                            }
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SnakeStyle.ink)
                            .padding(.horizontal, 16)
                            .frame(height: 31)
                            .background(runtime.fileSelection.ids.contains(file.id) ? SnakeStyle.selectedRow.opacity(0.8) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                focusFileList()
                                runtime.fileSelection.click(file.id, order: visibleEntryIDs)
                                onOpen(file)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                    focusFileList()
                                    let flags = NSEvent.modifierFlags
                                    runtime.fileSelection.click(file.id, order: visibleEntryIDs, command: flags.contains(.command), shift: flags.contains(.shift))
                            })
                            .onDrag { remoteFileProvider(for: file) }
                            .snakeContextMenu {
                                Button(file.isDirectory ? L10n.text("打开文件夹") : L10n.text("打开"), systemImage: file.isDirectory ? "folder" : "arrow.up.forward.app") {
                                    onOpen(file)
                                }
                                Button("下载", systemImage: "square.and.arrow.down") {
                                    runtime.fileSelection.contextClick(file.id, order: visibleEntryIDs)
                                    chooseDownloadDirectory()
                                }
                                .disabled(runtime.directoryActionDestination == nil)
                                if file.isDirectory {
                                    Section("新建与上传") { creationAndUploadMenu }
                                }
                                Section("管理") {
                                    Button("重命名", systemImage: "pencil") {
                                        renamingFile = file
                                        renameText = file.name
                                    }
                                    Button("修改权限", systemImage: "lock.shield") {
                                        permissionsFile = file
                                    }
                                    Button("复制路径", systemImage: "doc.on.doc") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(file.path, forType: .string)
                                    }
                                }
                                Divider()
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    focusFileList()
                                    runtime.fileSelection.contextClick(file.id, order: visibleEntryIDs)
                                    requestDeletion()
                                }
                                .disabled(runtime.isDeleting || runtime.loadingPath != nil)
                            }
                            Divider().opacity(0.38)
                        }
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: max(1, geometry.size.height - CGFloat(visibleEntries.count * 32)))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                focusFileList()
                                runtime.fileSelection = SFTPSelection()
                            }
                            .snakeContextMenu { emptyAreaContextMenu }
                    }
                }
                if isFiltering && visibleEntries.isEmpty && runtime.loadingPath == nil {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(SnakeStyle.muted)
                        Text("当前目录没有匹配项目")
                            .font(.system(size: 13, weight: .semibold))
                        Text("尝试缩短关键词，或清除检索。")
                            .font(.system(size: 11))
                            .foregroundStyle(SnakeStyle.muted)
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if receivesFinderFiles {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SnakeStyle.action.opacity(0.10))
                        .overlay {
                            VStack(spacing: 5) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 25))
                                Text(runtime.finderUploadTarget.title).font(.system(size: 13, weight: .semibold))
                                Text("文件夹将保留目录结构").font(.system(size: 12))
                            }
                            .padding()
                        }
                        .padding(12)
                        .allowsHitTesting(false)
                } else if receivesRemoteFile {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SnakeStyle.secure.opacity(0.10))
                        .overlay {
                            VStack(spacing: 5) {
                                Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 25)).foregroundStyle(SnakeStyle.secure)
                                Text(L10n.format("复制到 %@：%@", runtime.profile.name, runtime.currentPath))
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .padding(12)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer(minLength: 8)
                UploadStatusEntry(uploader: runtime.uploader, contextName: "SFTP", showsLabel: false)
                    .layoutPriority(1)
                let itemCount = visibleEntries.count
                let total = visibleEntries.reduce(Int64(0)) { $0 + $1.size }
                ViewThatFits(in: .horizontal) {
                    Text(isFiltering
                         ? L10n.plural("显示 %@ / %@ 个项目 · %@", count: runtime.entries.count, itemCount, runtime.entries.count, L10n.byteCount(total))
                         : L10n.plural("%@ 个项目 · %@", count: itemCount, itemCount, L10n.byteCount(total)))
                    Text(isFiltering
                         ? L10n.plural("显示 %@ / %@ 个项目", count: runtime.entries.count, itemCount, runtime.entries.count)
                         : L10n.plural("%@ 个项目", count: itemCount, itemCount))
                }
                    .font(.system(size: 11))
                    .foregroundStyle(SnakeStyle.muted)
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .background(SnakeStyle.canvas)
        .modifier(SFTPFinderDropModifier(
            runtime: runtime,
            isOnScreen: isOnScreen,
            receivesRemoteFile: $receivesRemoteFile,
            receivesFinderFiles: $receivesFinderFiles,
            perform: loadRemoteFilePayloads
        ))
        .background(FinderUploadArea())
        .alert("重命名", isPresented: Binding(
            get: { renamingFile != nil },
            set: { if !$0 { renamingFile = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("取消", role: .cancel) { renamingFile = nil }
            Button("保存") {
                if let file = renamingFile { runtime.rename(file, to: renameText) }
                renamingFile = nil
            }
        }
        .sheet(item: $permissionsFile) { file in
            RemotePermissionEditor(file: file) { mode, recursively in
                runtime.setPermissions(file, mode: mode, recursively: recursively)
                permissionsFile = nil
            } onCancel: {
                permissionsFile = nil
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($filesFocused)
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { key in
            guard key.modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
                  filesFocused, deletingFiles.isEmpty, renamingFile == nil, permissionsFile == nil else { return .ignored }
            requestDeletion()
            return .handled
        }
        .onChange(of: runtime.deleteCommandRequest) { _, _ in
            guard deletingFiles.isEmpty, renamingFile == nil, permissionsFile == nil else { return }
            requestDeletion()
        }
        .onChange(of: runtime.uploadFileCommandRequest) { _, _ in
            guard runtime.canUploadFileWithShortcut else { return }
            onUploadFiles()
        }
        .alert(L10n.plural("删除 %@ 个远程项目？", count: deletingFiles.count, deletingFiles.count), isPresented: Binding(
            get: { !deletingFiles.isEmpty },
            set: { if !$0 { deletingFiles = [] } }
        ), presenting: deletingFiles) { confirmedFiles in
            Button("取消", role: .cancel) { deletingFiles = [] }
            Button("删除", role: .destructive) {
                deletingFiles = []
                runtime.delete(files: confirmedFiles)
            }
        } message: { confirmedFiles in
            Text(deleteConfirmationMessage(for: confirmedFiles))
        }

    }

    private func chooseDownloadDirectory() {
        guard runtime.directoryActionDestination != nil else { return }
        let files = runtime.entries.filter { runtime.fileSelection.ids.contains($0.id) }
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("下载到此处")
        panel.message = L10n.plural("选择本地保存目录，将下载 %@ 个选中项目（包含文件夹内的内容）。", count: files.count, files.count)
        panel.begin { response in
            guard response == .OK, let root = panel.url else { return }
            Task { @MainActor in runtime.uploader.download(files: files, to: root, store: store) }
        }
    }

    private func fileIcon(_ file: RemoteFile) -> String {
        if file.isSymbolicLink { return "link" }
        return file.isDirectory ? "folder" : "doc"
    }

    private func deleteConfirmationMessage(for files: [RemoteFile]) -> String {
        let names = files.prefix(8).map(\.name).joined(separator: "\n")
        let more = files.count > 8 ? L10n.plural("\n…另有 %@ 项", count: files.count - 8, files.count - 8) : ""
        return names + more + L10n.text("\n\n永久删除选中项目；文件夹通过 rm -rf 删除全部内容，软链接只删除链接本身。不会移入废纸篓，无法撤销。")
    }

    private func focusFileList() {
        onFocusFiles()
        filesFocused = true
    }

    private func requestDeletion() {
        guard !runtime.isDeleting, runtime.loadingPath == nil, runtime.connectionState == .connected else { return }
        deletingFiles = runtime.entries.filter { runtime.fileSelection.ids.contains($0.id) }
    }

    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        creationAndUploadMenu
        Section("当前目录") {
            Button("刷新", systemImage: "arrow.clockwise") { runtime.refresh() }
                .disabled(runtime.connectionState == .connecting)
            Button("复制路径", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(runtime.currentPath, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var creationAndUploadMenu: some View {
        Button("新建文件", systemImage: "doc.badge.plus") { onCreateFile() }
            .disabled(runtime.directoryActionDestination == nil)
        Button("新建文件夹", systemImage: "folder.badge.plus") { onCreateDirectory() }
            .disabled(runtime.directoryActionDestination == nil)
        Button("上传文件", systemImage: "square.and.arrow.up") { onUploadFiles() }
            .disabled(runtime.directoryActionDestination == nil)
        Button("上传文件夹", systemImage: "square.and.arrow.up.on.square") { onUploadDirectory() }
            .disabled(runtime.directoryActionDestination == nil)
    }

    private func remoteFileProvider(for file: RemoteFile) -> NSItemProvider {
        let payload = RemoteFileTransferPayload(
            sourceRuntimeID: runtime.id.rawValue,
            sourceProfileID: runtime.profile.id,
            sourcePath: file.path,
            fileName: file.name,
            fileSize: file.size,
            isDirectory: file.isDirectory,
            isSymbolicLink: file.isSymbolicLink,
            linkTarget: file.linkTarget
        )
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.snakeRemoteFile.identifier, visibility: .all) { completion in
            completion(try? JSONEncoder().encode(payload), nil)
            return nil
        }
        return provider
    }

    private func loadRemoteFilePayloads(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.snakeRemoteFile.identifier) { data, _ in
                guard let data, let payload = try? JSONDecoder().decode(RemoteFileTransferPayload.self, from: data) else { return }
                Task { @MainActor in
                    guard payload.sourceRuntimeID != runtime.id.rawValue,
                          let source = SFTPRuntime.runtime(id: payload.sourceRuntimeID) else { return }
                    let file = RemoteFile(
                        name: payload.fileName,
                        path: payload.sourcePath,
                        isDirectory: payload.isDirectory,
                        isSymbolicLink: payload.isSymbolicLink,
                        linkTarget: payload.linkTarget,
                        size: payload.fileSize
                    )
                    runtime.copy(file: file, from: source, store: store)
                }
            }
        }
    }
}

    private func navigateUp() {
        isEditingPath = false
        guard runtime.currentPath != "/" else {
            showNavigationNotice(L10n.text("已经位于顶级目录"))
            return
        }
        let parent = (runtime.currentPath as NSString).deletingLastPathComponent
        runtime.refresh(path: parent.isEmpty ? "/" : parent)
    }

    private func goBack() {
        isEditingPath = false
        guard runtime.canGoBack else {
            showNavigationNotice(L10n.text("没有可回退的目录"))
            return
        }
        runtime.goBack()
    }

    private func goForward() {
        isEditingPath = false
        guard runtime.canGoForward else {
            showNavigationNotice(L10n.text("没有可前进的目录"))
            return
        }
        runtime.goForward()
    }

    private func showNavigationNotice(_ message: String) {
        let noticeID = UUID()
        navigationNoticeID = noticeID
        withAnimation(.easeOut(duration: 0.12)) {
            navigationNotice = message
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.8))
            guard navigationNoticeID == noticeID else { return }
            withAnimation(.easeIn(duration: 0.12)) {
                navigationNotice = nil
            }
        }
    }

    private func open(_ file: RemoteFile) {
        isEditingPath = false
        runtime.open(file, cache: store.remoteOpenCacheConfiguration)
    }

    private func chooseFiles(allowsDirectories: Bool) {
        guard let destination = runtime.directoryActionDestination else { return }
        let panel = NSOpenPanel()
        panel.message = L10n.format("上传到远程目录：%@", destination.path)
        panel.canChooseFiles = !allowsDirectories
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.text("上传")
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                runtime.upload(urls: panel.urls, to: destination.path, store: store)
            }
        }
    }

}


/// Own the sheet next to its button and observe uploads directly, independent
/// of terminal layout, path length and native terminal text focus.
private struct UploadStatusEntry: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var uploader: LocalUploadCoordinator
    let contextName: String
    let showsLabel: Bool
    @State private var showsHistory = false

    var body: some View {
        Group {
            if uploader.hasUploadActivity {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    UploadMiniStatus(uploader: uploader, date: context.date,
                                     showsLabel: showsLabel, onOpen: { showsHistory = true })
                }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(L10n.format("查看当前%@传输记录", contextName))
                .help(L10n.format("查看当前%@传输记录 · %@", contextName, uploader.transferSummary))
            }
        }
        .sheet(isPresented: $showsHistory) {
            UploadHistoryView(uploader: uploader, contextDescription: L10n.format("当前%@标签的文件传输记录", contextName))
                .environmentObject(store)
        }
    }
}

private struct UploadMiniStatus: View {
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var uploader: LocalUploadCoordinator
    let date: Date
    let showsLabel: Bool
    let onOpen: () -> Void

    private var activeRecord: SFTPUploadRecord? {
        uploader.records.first { [.scanning, .queued, .running, .paused].contains($0.state) }
    }
    private var isBusy: Bool { uploader.isPreparing || activeRecord != nil }
    private var success: Bool { uploader.activity.showsSuccess(at: date) }
    private var color: Color {
        if let record = activeRecord, record.state == .paused { return .orange }
        if isBusy { return SnakeStyle.action }
        if uploader.hasUnverifiedTransfers && uploader.activity.result != .failed { return .orange }
        switch uploader.activity.result {
        case .failed: return .red
        case .cancelled, .skipped: return SnakeStyle.muted
        default: return SnakeStyle.secure
        }
    }
    private var icon: String {
        if isBusy {
            if activeRecord?.verification.isChecking == true { return "checkmark.shield" }
            return activeRecord?.state == .paused ? "pause.circle.fill" : (activeRecord?.isDownload == true ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
        }
        if uploader.hasUnverifiedTransfers && uploader.activity.result != .failed { return "exclamationmark.shield" }
        switch uploader.activity.result {
        case .succeeded: return success ? "checkmark.circle.fill" : "clock.arrow.circlepath"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        default: return "clock.arrow.circlepath"
        }
    }
    private var progress: Double? {
        if success { return 1 }
        guard let record = activeRecord else { return nil }
        return min(1, max(0, store.transferJob(id: record.jobID)?.progress ?? 0))
    }
    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, isActive: isBusy && activeRecord?.state != .paused && !reduceMotion)
                if activeRecord?.verification.isChecking == true {
                    Text("正在校验…").font(.system(size: 11))
                } else if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                        .tint(color).frame(width: 72)
                        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 32, alignment: .trailing)
                } else if isBusy {
                    Text(uploader.pendingConflict == nil && uploader.pendingDownloadConflict == nil ? L10n.text("准备传输…") : L10n.text("等待确认"))
                        .font(.system(size: 11))
                }
                if success && showsLabel { Text("已完成").font(.system(size: 11, weight: .medium)) }
                else if showsLabel && !isBusy { Text("传输记录").font(.system(size: 11)) }
            }
            .foregroundStyle(color)
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct UploadHistoryView: View {
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var uploader: LocalUploadCoordinator
    let contextDescription: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.up.arrow.down.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(SnakeStyle.action)
                VStack(alignment: .leading, spacing: 2) {
                    Text("传输记录")
                        .font(.system(size: 18, weight: .semibold))
                    Text(contextDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                    Text(uploader.transferSummary)
                        .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            Divider()

            if let message = uploader.errorMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.red)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 6)
            }

            if uploader.records.isEmpty {
                ContentUnavailableView(
                    uploader.isPreparing ? L10n.text("正在准备传输") : L10n.text("没有文件级记录"),
                    systemImage: "arrow.up.doc",
                    description: Text(uploader.errorMessage ?? (uploader.isPreparing ? L10n.text("正在扫描文件或等待确认。") : L10n.text("本次结果见上方摘要。")))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 12) {
                    Text("文件").frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
                    Text("大小").frame(width: 82, alignment: .leading)
                    Text("开始时间").frame(width: 126, alignment: .leading)
                    Text("耗时").frame(width: 70, alignment: .leading)
                    Text("状态").frame(width: 72, alignment: .leading)
                    Color.clear.frame(width: 62)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SnakeStyle.muted)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(Color.primary.opacity(0.035))

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(uploader.records) { record in
                                UploadHistoryRow(uploader: uploader, record: record, date: context.date)
                                    .environmentObject(store)
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("关闭当前标签后记录会自动清空")
                    .font(.system(size: 10))
                    .foregroundStyle(SnakeStyle.muted)
                Spacer()
                Button("清除记录") { uploader.clearFinishedRecords() }
                    .disabled(uploader.isPreparing && !uploader.records.contains {
                        [.succeeded, .failed, .cancelled, .interrupted].contains($0.state)
                    })
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
        }
        .frame(width: 760, height: 460)
        .background(SnakeStyle.canvas)
    }
}

private struct UploadHistoryRow: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var uploader: LocalUploadCoordinator
    let record: SFTPUploadRecord
    let date: Date

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: stateIcon)
                    .foregroundStyle(stateColor)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(record.isDownload ? "↓" : "↑") \(record.fileName)")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(record.relaySource.map { "\($0) · \(record.remotePath)" } ?? record.remotePath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SnakeStyle.muted)
                        .lineLimit(1)
                    Text(record.localURL.path)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(SnakeStyle.muted).lineLimit(1)
                    Text(record.verification.label)
                        .font(.system(size: 10)).foregroundStyle(record.verification.isWarning ? Color.orange : stateColor).lineLimit(1)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            Text(L10n.byteCount(record.fileSize))
                .frame(width: 82, alignment: .leading)
            Text(record.startedAt, format: .dateTime.month().day().hour().minute().second())
                .frame(width: 126, alignment: .leading)
            Text(durationText)
                .frame(width: 70, alignment: .leading)
            Text(record.state == .running && record.verification.isChecking ? L10n.text("正在校验") : record.state.label)
                .foregroundStyle(stateColor)
                .frame(width: 72, alignment: .leading)
                .overlay(alignment: .bottomLeading) {
                    if record.state == .running && !record.verification.isChecking {
                        Text("\(Int((store.transferJob(id: record.jobID)?.progress ?? 0) * 100))%")
                            .font(.system(size: 9, design: .monospaced)).offset(y: 14)
                    }
                }
            controls.frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 16)
        .frame(height: 78)
        .help([record.remotePath, record.localURL.path, record.verification.label, store.transferJob(id: record.jobID)?.errorMessage ?? ""].joined(separator: "\n"))
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch record.state {
            case .running:
                controlButton("pause.fill", L10n.text("暂停")) { uploader.pause(jobID: record.jobID, store: store) }
                controlButton("xmark", L10n.text("取消")) { uploader.cancel(jobID: record.jobID, store: store) }
            case .paused:
                controlButton("play.fill", L10n.text("继续")) { uploader.resume(jobID: record.jobID, store: store) }
                controlButton("xmark", L10n.text("取消")) { uploader.cancel(jobID: record.jobID, store: store) }
            case .queued, .scanning:
                controlButton("xmark", L10n.text("取消")) { uploader.cancel(jobID: record.jobID, store: store) }
            case .failed, .interrupted, .cancelled:
                // Relay files are deleted when the copy ends; drag again instead.
                if !record.isRelay {
                    controlButton("arrow.clockwise", L10n.text("重试")) { uploader.retry(jobID: record.jobID, store: store) }
                }
            case .succeeded:
                EmptyView()
            }
        }
    }

    private func controlButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 22) }
            .buttonStyle(.borderless)
            .help(help)
    }

    private var durationText: String {
        let seconds = Int(record.duration(at: date).rounded(.down))
        if seconds < 60 { return L10n.plural("%@ 秒", count: seconds, seconds) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var stateIcon: String {
        if record.state == .succeeded && record.verification.isWarning { return "exclamationmark.shield" }
        switch record.state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled, .interrupted: return "xmark.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return record.verification.isChecking ? "checkmark.shield" : (record.isDownload ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
        }
    }

    private var stateColor: Color {
        if record.state == .succeeded && record.verification.isWarning { return .orange }
        switch record.state {
        case .succeeded: return SnakeStyle.secure
        case .failed: return .red
        case .paused: return .orange
        case .cancelled, .interrupted: return SnakeStyle.muted
        default: return SnakeStyle.action
        }
    }
}

private struct DownloadConflictView: View {
    @ObservedObject var uploader: LocalUploadCoordinator
    let conflict: DownloadConflictPrompt
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本地文件已存在").font(.headline)
            Text(conflict.path).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Text("覆盖前会先下载到临时文件并完成校验流程；校验工具不可用时会标记未校验。原文件不会提前被清空。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("应用到当前批次", isOn: $uploader.applyDownloadConflictToBatch)
            HStack {
                Button("取消下载", role: .cancel) { uploader.resolveDownloadConflict(.cancel) }
                Spacer()
                Button("跳过") { uploader.resolveDownloadConflict(.skip) }
                Button("覆盖", role: .destructive) { uploader.resolveDownloadConflict(.overwrite) }
            }
        }.padding(22).frame(width: 440)
    }
}

private struct RemotePermissionEditor: View {
    let file: RemoteFile
    let onApply: (UInt32, Bool) -> Void
    let onCancel: () -> Void
    @State private var selection: RemotePermissionSelection
    @State private var appliesRecursively = false

    init(file: RemoteFile, onApply: @escaping (UInt32, Bool) -> Void, onCancel: @escaping () -> Void) {
        self.file = file
        self.onApply = onApply
        self.onCancel = onCancel
        _selection = State(initialValue: RemotePermissionSelection(modeText: file.permissions, isDirectory: file.isDirectory))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: file.isSymbolicLink ? "link" : (file.isDirectory ? "folder.fill" : "doc.fill"))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(file.isDirectory ? SnakeStyle.action : SnakeStyle.muted)
                    .frame(width: 38, height: 38)
                    .background(SnakeStyle.action.opacity(file.isDirectory ? 0.10 : 0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("修改远程权限")
                        .font(.system(size: 17, weight: .semibold))
                    Text(file.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(SnakeStyle.muted)
                        .lineLimit(1)
                }
                Spacer()
                Text(selection.display)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SnakeStyle.action)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(SnakeStyle.action.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .padding(20)

            Divider()

            VStack(spacing: 0) {
                permissionHeader
                Divider()
                permissionRow(L10n.text("用户"), read: .ownerRead, write: .ownerWrite, execute: .ownerExecute)
                Divider()
                permissionRow(L10n.text("用户组"), read: .groupRead, write: .groupWrite, execute: .groupExecute)
                Divider()
                permissionRow(L10n.text("其他"), read: .otherRead, write: .otherWrite, execute: .otherExecute)
            }
            .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(SnakeStyle.hairline, lineWidth: 1)
            }
            .padding(20)

            if file.isDirectory && !file.isSymbolicLink {
                Divider()
                Toggle(isOn: $appliesRecursively) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("同时修改文件夹内所有项目")
                            .font(.system(size: 13, weight: .medium))
                        Text("递归应用到现有子文件和子文件夹；遇到软连接时不会跟随到链接目标。")
                            .font(.system(size: 11))
                            .foregroundStyle(SnakeStyle.muted)
                    }
                }
                .toggleStyle(.switch)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            HStack {
                Text(permissionScopeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(SnakeStyle.muted)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(SnakeOutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("应用权限") { onApply(selection.mode, appliesRecursively) }
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 62)
            .background(SnakeStyle.canvas)
        }
        .frame(width: 500)
        .background(SnakeStyle.canvas)
    }

    private var permissionScopeDescription: String {
        if file.isSymbolicLink { return L10n.text("权限会应用到软连接指向的目标。") }
        if appliesRecursively { return L10n.text("权限会递归应用，耗时取决于目录内容数量。") }
        return L10n.text("权限只会应用到当前远程项目。")
    }

    private var permissionHeader: some View {
        HStack(spacing: 0) {
            Text("对象")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("可读").frame(width: 88)
            Text("可写").frame(width: 88)
            Text("执行").frame(width: 88)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(SnakeStyle.muted)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    private func permissionRow(
        _ title: String,
        read: RemotePermissionBit,
        write: RemotePermissionBit,
        execute: RemotePermissionBit
    ) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            permissionToggle(read).frame(width: 88)
            permissionToggle(write).frame(width: 88)
            permissionToggle(execute).frame(width: 88)
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func permissionToggle(_ bit: RemotePermissionBit) -> some View {
        Toggle("", isOn: Binding(
            get: { selection.contains(bit) },
            set: { selection.set(bit, enabled: $0) }
        ))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .accessibilityLabel(accessibilityLabel(for: bit))
    }

    private func accessibilityLabel(for bit: RemotePermissionBit) -> String {
        switch bit {
        case .ownerRead: L10n.text("用户可读")
        case .ownerWrite: L10n.text("用户可写")
        case .ownerExecute: L10n.text("用户可执行")
        case .groupRead: L10n.text("用户组可读")
        case .groupWrite: L10n.text("用户组可写")
        case .groupExecute: L10n.text("用户组可执行")
        case .otherRead: L10n.text("其他用户可读")
        case .otherWrite: L10n.text("其他用户可写")
        case .otherExecute: L10n.text("其他用户可执行")
        }
    }
}

private struct MountWorkspaceView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: WorkspaceTabRuntime
    let onNewMapping: () -> Void
    let onEditMapping: (MountMapping) -> Void
    @State private var dependencyStatus = MountDependencyStatus.detect()
    @State private var tunnelEditor: TunnelEditorDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Same header language as the session page: one row, what and how many on
                // the left, status and actions on the right.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { heading; Spacer(minLength: 12); actions }
                    VStack(alignment: .leading, spacing: 10) { heading; actions }
                }
                switch runtime.mountSection {
                case .mappings:
                    if !dependencyStatus.isReady { dependencyWarning }
                    mappingTable
                    Text("双击一行编辑映射，可查看完整的访问路径。")
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                case .tunnels:
                    TunnelTable(
                        tunnels: store.tunnels,
                        runtime: runtime,
                        onNew: { tunnelEditor = TunnelEditorDraft() },
                        onEdit: { tunnelEditor = TunnelEditorDraft(tunnel: $0) }
                    )
                    Text("本地端口只监听 127.0.0.1，只有这台 Mac 能访问。SSH 断开后隧道停在「已断开」，需要手动重连。")
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SnakeStyle.canvas)
        .sheet(item: $tunnelEditor) { draft in
            TunnelEditorSheet(tunnels: store.tunnels, tunnel: draft.tunnel, onClose: { tunnelEditor = nil })
                .environmentObject(store)
                .environment(\.locale, store.appLanguage.locale)
        }
        .alert(runtime.mountSection == .mappings ? L10n.text("磁盘映射操作未完成") : L10n.text("隧道操作未完成"), isPresented: Binding(
            get: { store.mountActionError != nil },
            set: { if !$0 { store.mountActionError = nil } }
        )) {
            Button("确定") { store.mountActionError = nil }
        } message: { Text(store.mountActionError ?? "") }
    }

    /// Only shown when something is missing; a ready environment is a small pill in the header.
    private var dependencyWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("挂载环境需要配置").font(.system(size: 12, weight: .semibold))
                Text("请安装 macFUSE 与 SSHFS 后重新检测").font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
            }
            Spacer()
            Button("重新检测", systemImage: "arrow.clockwise") { refresh() }
                .buttonStyle(SnakeOutlineButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func refresh() {
        dependencyStatus = .detect()
        store.refreshMountStates()
    }

    private var mappingTable: some View {
        ResourceListCard {
            if store.mountMappings.isEmpty {
                Text("暂无磁盘映射，点击“新增映射”配置远程目录。")
                    .font(.system(size: 13))
                    .foregroundStyle(SnakeStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            ForEach(store.mountMappings) { mapping in
                MappingTableRow(
                    mapping: mapping,
                    isSelected: runtime.selectedMappingID == mapping.id,
                    action: { runtime.selectedMappingID = mapping.id },
                    onEdit: { onEditMapping(mapping) }
                )
                if mapping.id != store.mountMappings.last?.id { Divider().opacity(0.6) }
            }
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Picker("", selection: $runtime.mountSection) {
                Text("磁盘映射").tag(MountWorkspaceSection.mappings)
                Text("SSH 隧道").tag(MountWorkspaceSection.tunnels)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text(summary)
                .font(.system(size: 12))
                .foregroundStyle(SnakeStyle.muted)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var summary: String {
        switch runtime.mountSection {
        case .mappings:
            let mounted = store.mountMappings.filter { $0.state == .mounted || $0.state == .external }.count
            return L10n.format("%@ 个映射 · %@ 个已挂载", store.mountMappings.count, mounted)
        case .tunnels:
            let running = store.tunnels.tunnels.filter { if case .running = store.tunnels.state(of: $0.id) { true } else { false } }.count
            return L10n.format("%@ 条隧道 · %@ 条已连接", store.tunnels.tunnels.count, running)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch runtime.mountSection {
        case .mappings:
            HStack(spacing: 8) {
                if dependencyStatus.isReady {
                    StatusPill(text: L10n.text("macFUSE 与 SSHFS 可用"), color: SnakeStyle.secure)
                }
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(SnakeIconButtonStyle(minSize: CGSize(width: 30, height: 30)))
                    .help("刷新挂载状态").accessibilityLabel("刷新挂载状态")
                Button("新增映射", systemImage: "plus", action: onNewMapping)
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
            .fixedSize(horizontal: true, vertical: false)
        case .tunnels:
            Button("新增隧道", systemImage: "plus") { tunnelEditor = TunnelEditorDraft() }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .fixedSize()
        }
    }
}

private struct MappingTableRow: View {
    @EnvironmentObject private var store: ApplicationStore
    let mapping: MountMapping
    let isSelected: Bool
    let action: () -> Void
    let onEdit: () -> Void
    @State private var confirmingDeletion = false
    @State private var checkingDeletion = false
    @State private var deletionRequiresUnmount = false

    private var isMounted: Bool { mapping.state == .mounted || mapping.state == .external }

    var body: some View {
        ResourceRow(
            symbol: "externaldrive",
            tint: mapping.state.indicatorColor == .secondary ? SnakeStyle.action : mapping.state.indicatorColor,
            subtitle: "\(profileName) · \(mapping.remotePath)  →  \(mapping.userAccessPath)",
            status: mapping.state.label,
            statusColor: mapping.state.indicatorColor,
            automaticLabel: mapping.autoMount ? L10n.text("自动挂载") : nil,
            automaticHelp: L10n.text("启动 Snake 时自动挂载这个目录"),
            problem: mapping.state == .failed ? mapping.lastError : nil,
            isSelected: isSelected
        ) {
            Text(mapping.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.tail).help(mapping.name)
        } actions: {
            Button(isMounted ? L10n.text("打开") : (mapping.state == .mounting ? L10n.text("正在挂载") : L10n.text("挂载"))) {
                if isMounted { store.reveal(mappingID: mapping.id) } else { store.mount(mappingID: mapping.id) }
            }
            .buttonStyle(SnakeOutlineButtonStyle(emphasized: !isMounted))
            .frame(width: 88)
            .disabled(mapping.state == .mounting || mapping.state == .unavailable)
            // Always present, dimmed when nothing is mounted, so every row lines up.
            Button { store.unmount(mappingID: mapping.id) } label: { Image(systemName: "eject") }
                .buttonStyle(SnakeIconButtonStyle())
                .help("安全卸载").accessibilityLabel("安全卸载")
                .disabled(!isMounted)
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(SnakeIconButtonStyle())
                .help("编辑映射").accessibilityLabel("编辑映射")
                .disabled(mapping.state == .mounting)
            Button { requestDeletion() } label: { Image(systemName: "trash") }
                .buttonStyle(SnakeIconButtonStyle())
                .help("删除映射").accessibilityLabel("删除映射")
                .disabled(checkingDeletion)
        }
        // A plain single tap would wait out the double-click interval before
        // firing; the simultaneous tap highlights the row on the first click.
        .onTapGesture(count: 2, perform: onEdit)
        .simultaneousGesture(TapGesture().onEnded(action))
        .snakeContextMenu {
            if isMounted {
                Button("在 Finder 中打开", systemImage: "folder") { store.reveal(mappingID: mapping.id) }
                Button("安全卸载", systemImage: "eject") { store.unmount(mappingID: mapping.id) }
            } else {
                Button("挂载", systemImage: "externaldrive.badge.plus") { store.mount(mappingID: mapping.id) }
                    .disabled(mapping.state == .mounting || mapping.state == .unavailable)
            }
            Section("管理") {
                Button("编辑映射", systemImage: "pencil", action: onEdit)
                    .disabled(mapping.state == .mounting)
                Toggle(isOn: Binding(get: { mapping.autoMount }, set: { store.setAutoMount($0, for: mapping.id) })) {
                    Label("启动 Snake 时自动挂载", systemImage: "bolt")
                }
            }
            Divider()
            Button("删除映射", systemImage: "trash", role: .destructive) { requestDeletion() }
                .disabled(checkingDeletion)
        }
        .alert(deletionRequiresUnmount
               ? L10n.format("“%@”仍处于挂载状态", mapping.name)
               : L10n.format("是否删除“%@”？", mapping.name), isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) {}
            Button(deletionRequiresUnmount ? L10n.text("安全卸载并删除") : L10n.text("删除映射"), role: .destructive) {
                store.deleteMapping(mappingID: mapping.id)
            }
        } message: {
            if deletionRequiresUnmount {
                Text(L10n.text("此目录正在使用挂载连接，删除前需要安全卸载。若目录被占用或卸载失败，会保留映射。")
                     + L10n.format("\n\n远程目录：%@\n本地目录：%@\n\n远程文件和本地文件夹会保留。", mapping.remotePath, mapping.userAccessPath))
            }
        }
    }

    private func requestDeletion() {
        guard !checkingDeletion else { return }
        guard mapping.state != .mounting else {
            store.mountActionError = L10n.format("“%@”正在执行挂载或卸载操作，请等待操作完成后再删除。", mapping.name)
            return
        }
        checkingDeletion = true
        Task { @MainActor in
            defer { checkingDeletion = false }
            do {
                let mounted = try await Task.detached(priority: .utility) { try MountOperations.checkedMountedPaths() }.value
                guard let current = store.mountMappings.first(where: { $0.id == mapping.id }) else { return }
                guard current.state != .mounting else {
                    store.mountActionError = L10n.format("“%@”正在执行挂载或卸载操作，请稍后再删除。", current.name)
                    return
                }
                deletionRequiresUnmount = mounted.contains(current.managedMountPath)
                confirmingDeletion = true
            } catch {
                store.mountActionError = L10n.format("无法确认目录的挂载状态，暂不能删除：%@", error.localizedDescription)
            }
        }
    }

    private var profileName: String {
        store.profiles.first(where: { $0.id == mapping.profileID })?.name ?? L10n.text("未绑定 SSH 会话")
    }
}

private extension MountState {
    var indicatorColor: Color {
        switch self {
        case .mounted, .external: SnakeStyle.secure
        case .failed, .unavailable: .red
        case .mounting: .orange
        case .idle: .secondary
        }
    }
}

private struct SessionEditorView: View {
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.dismiss) private var dismiss
    private let originalProfile: SSHProfile?
    private let profileID: UUID
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var authMethod: AuthMethod
    @StateObject private var credential = CredentialRevealController.sharingGrace()
    @State private var folderID: UUID?
    @State private var symbolName: String
    @State private var customIconData: Data?
    @State private var cropSource: ProfileIconCropSource?
    @State private var privateKeyBookmark: Data?
    @State private var privateKeyPath: String?
    @State private var privateKeyUnavailable = false
    @State private var selectedSavedPasswordID: UUID?
    @State private var selectedFromLibraryThisEdit = false
    /// A key picked from 密钥管理 in this edit; its passphrase is copied on save.
    @State private var pickedKeyID: UUID?
    @State private var errorMessage: String?
    @State private var showsIconPicker = false
    @StateObject private var connectionTest = SessionConnectionTestController()

    init(profile: SSHProfile?, defaultFolderID: UUID? = nil) {
        originalProfile = profile
        profileID = profile?.id ?? UUID()
        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.host ?? "")
        _port = State(initialValue: String(profile?.port ?? 22))
        _username = State(initialValue: profile?.username ?? "")
        _authMethod = State(initialValue: profile?.authMethod ?? .password)
        _folderID = State(initialValue: profile == nil ? defaultFolderID : profile?.groupID)
        _symbolName = State(initialValue: profile?.symbolName ?? "server.rack")
        _customIconData = State(initialValue: profile?.usesCustomIcon == true ? ProfileIconStore.data(for: profile?.id ?? UUID()) : nil)
        _privateKeyBookmark = State(initialValue: profile?.privateKeyBookmark)
        _selectedSavedPasswordID = State(initialValue: profile?.savedPasswordID)
    }

    /// Numeric dates read the same in every interface language.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        // Sized to its content rather than a fixed frame, so short forms leave no empty band.
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SSH 会话").font(.system(size: 11, weight: .semibold)).foregroundStyle(SnakeStyle.muted)
                    Text(originalProfile == nil ? L10n.text("新增会话") : L10n.text("编辑会话"))
                        .font(.system(size: 18, weight: .bold))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(SnakeIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help("关闭").accessibilityLabel("关闭")
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                editorFields
                SessionConnectionTestFeedback(state: connectionTest.state)
            }
            .padding(20)

            if let timestamps = store.profileTimestamps[profileID] {
                Divider()
                HStack(spacing: 20) {
                    Label(L10n.format("创建 %@", Self.timestampFormatter.string(from: timestamps.createdAt)), systemImage: "calendar.badge.plus")
                    Label(L10n.format("最近更新 %@", Self.timestampFormatter.string(from: timestamps.updatedAt)), systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SnakeStyle.muted)
                .textSelection(.enabled)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .help("只有修改会话内容或密码才更新；调整顺序不算修改")
            }

            Divider()
            HStack {
                Button(connectionTest.isTesting ? L10n.text("正在测试…") : L10n.text("测试连接")) {
                    connectionTest.start(host: host, port: port)
                }
                .buttonStyle(SnakeOutlineButtonStyle())
                .disabled(connectionTest.isTesting)
                .help("检测目标的 SSH 握手，不验证账号密码")
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(SnakeOutlineButtonStyle())
                Button("保存会话") { save() }.buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
            .padding(.horizontal, 20)
            .frame(height: 54)
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .background(SnakeStyle.canvas)
        .onChange(of: authMethod) { _, _ in
            credential.reset()
            selectedSavedPasswordID = nil
            selectedFromLibraryThisEdit = false
        }
        .onChange(of: username) { _, value in
            if let id = selectedSavedPasswordID,
               let linked = store.savedPasswords.first(where: { $0.id == id }),
               value != linked.username {
                selectedSavedPasswordID = nil
                selectedFromLibraryThisEdit = false
            }
        }
        .onChange(of: privateKeyBookmark) { _, _ in resolvePrivateKeyPath() }
        .onAppear { resolvePrivateKeyPath() }
        .onChange(of: host) { _, _ in connectionTest.reset() }
        .onChange(of: port) { _, _ in connectionTest.reset() }
        .onDisappear {
            credential.reset()
            connectionTest.reset()
        }
        .sheet(item: $cropSource) { source in
            ProfileIconCropView(image: source.image) { data in
                customIconData = data
                symbolName = SSHProfile.customIconSymbolName
                cropSource = nil
            } onCancel: {
                cropSource = nil
            }
        }
    }

    /// The avatar doubles as the icon chooser, so the form needs no icon column.
    private var iconButton: some View {
        Button { showsIconPicker = true } label: {
            editorIconPreview
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, SnakeStyle.ink.opacity(0.7))
                        .offset(x: 4, y: 4)
                }
        }
        .buttonStyle(.plain)
        .help("更换会话图标")
        .accessibilityLabel("会话图标")
        .popover(isPresented: $showsIconPicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("会话图标").font(.system(size: 12, weight: .semibold))
                HStack(spacing: 8) {
                    ForEach(["server.rack", "terminal", "cylinder", "cloud"], id: \.self) { symbol in
                        Button {
                            symbolName = symbol
                            customIconData = nil
                            showsIconPicker = false
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(symbolName == symbol ? SnakeStyle.action : SnakeStyle.muted)
                                .frame(width: 36, height: 32)
                                .background(symbolName == symbol ? SnakeStyle.selectedRow : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).stroke(SnakeStyle.hairline, lineWidth: 1) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("会话图标 " + symbol)
                    }
                }
                Button {
                    showsIconPicker = false
                    selectProfileImage()
                } label: {
                    Label(customIconData == nil ? L10n.text("选择照片…") : L10n.text("重新选择照片…"), systemImage: "photo.badge.plus")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: symbolName == SSHProfile.customIconSymbolName))
                Text("选择后可裁剪为会话头像")
                    .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
            }
            .padding(14)
        }
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 12) {
                iconButton
                compactField(label: L10n.text("会话名称"), text: $name)
                folderPicker
            }
            HStack(alignment: .top, spacing: 12) {
                compactField(label: L10n.text("IP 或主机名"), text: $host, monospaced: true)
                compactField(label: L10n.text("端口"), text: $port, monospaced: true)
                    .frame(width: 96)
            }
            HStack(alignment: .top, spacing: 12) {
                compactField(label: L10n.text("用户名"), text: $username, monospaced: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("密码类型").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
                    Picker("密码类型", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in Text(method.label).tag(method) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(height: 32)
                }
                .frame(maxWidth: .infinity)
            }
            // Same rows for both types so switching never changes the sheet's height:
            // where the secret comes from on the left, the secret itself on the right.
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if authMethod == .privateKey { keyPicker } else { savedPasswordPicker }
                }
                .frame(maxWidth: .infinity)
                CredentialInputView(account: savedCredentialAccount, isPassphrase: authMethod == .privateKey, reveal: credential)
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 5) {
                credentialDetail
                    .frame(height: 16, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").foregroundStyle(SnakeStyle.secure)
                    Text(authMethod == .password
                         ? L10n.text("加密保存 · 查看需身份验证；隐藏后保留编辑草稿。")
                         : L10n.text("私钥仅保存访问书签；口令加密保存，查看需身份验证。"))
                }
                .frame(height: 16, alignment: .leading)
                .foregroundStyle(SnakeStyle.muted)
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Library keys first; a file picked from disk shows by name.
    private var keyPicker: some View {
        let libraryKey = store.sshKey(forBookmark: privateKeyBookmark)
        return VStack(alignment: .leading, spacing: 6) {
            Text("密钥").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            HStack(spacing: 8) {
                Picker("密钥", selection: Binding<String>(
                    get: {
                        if let libraryKey { return libraryKey.id.uuidString }
                        return privateKeyBookmark == nil ? "" : "file"
                    },
                    set: { value in
                        if value == "choose" {
                            selectPrivateKey()
                        } else if let id = UUID(uuidString: value), let key = store.sshKeys.first(where: { $0.id == id }) {
                            pickLibraryKey(key)
                        }
                    }
                )) {
                    if privateKeyBookmark == nil {
                        Text("请选择密钥").tag("")
                    }
                    ForEach(store.sshKeys) { key in
                        Text("\(key.name) · \(key.algorithmLabel)").tag(key.id.uuidString)
                    }
                    if privateKeyBookmark != nil, libraryKey == nil {
                        Text(privateKeyPath.map { ($0 as NSString).lastPathComponent } ?? L10n.text("本机私钥文件")).tag("file")
                    }
                    Divider()
                    Text("选择本机文件…").tag("choose")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                Button { selectPrivateKey() } label: { Image(systemName: "folder") }
                    .buttonStyle(SnakeIconButtonStyle(minSize: CGSize(width: 32, height: 30)))
                    .help("选择本机私钥文件…")
                    .accessibilityLabel("选择本机私钥文件…")
            }
            .frame(height: 32)
        }
    }

    /// Fills the username and a copy of the password from 密码管理; 手动输入 unlinks.
    private var savedPasswordPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("常用账号").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            Picker("常用账号", selection: Binding<UUID?>(
                get: { selectedSavedPasswordID.flatMap { id in store.savedPasswords.contains { $0.id == id } ? id : nil } },
                set: { id in
                    credential.reset()
                    if let id, let item = store.savedPasswords.first(where: { $0.id == id }) {
                        username = item.username
                        selectedSavedPasswordID = item.id
                        selectedFromLibraryThisEdit = true
                    } else {
                        selectedSavedPasswordID = nil
                        selectedFromLibraryThisEdit = false
                    }
                }
            )) {
                Text("手动输入").tag(UUID?.none)
                if !store.savedPasswords.isEmpty { Divider() }
                ForEach(store.savedPasswords) { item in
                    Text("\(item.name) · \(item.username)").tag(Optional(item.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(height: 32)
        }
    }

    /// One line under the row in both modes, so the sheet keeps its height.
    @ViewBuilder
    private var credentialDetail: some View {
        if authMethod == .privateKey {
            if privateKeyUnavailable {
                Label("私钥文件不可用，请重新选择。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if let key = store.sshKey(forBookmark: privateKeyBookmark) {
                Label("\(key.algorithmLabel)  \(key.fingerprint)", systemImage: "key.viewfinder")
                    .foregroundStyle(SnakeStyle.muted).textSelection(.enabled)
            } else if let privateKeyPath {
                Label(privateKeyPath, systemImage: "doc").foregroundStyle(SnakeStyle.muted).textSelection(.enabled)
            } else {
                Label(store.sshKeys.isEmpty
                      ? L10n.text("密钥管理中还没有密钥，可在密码管理的「密钥」页导入或生成，或选择本机文件。")
                      : L10n.text("从密钥管理选用，或选择本机私钥文件。"), systemImage: "info.circle")
                    .foregroundStyle(SnakeStyle.muted)
            }
        } else if let id = selectedSavedPasswordID, let item = store.savedPasswords.first(where: { $0.id == id }) {
            Label(L10n.format("已关联「%@」：单独改用户名或密码会解除关联。", item.name), systemImage: "link")
                .foregroundStyle(SnakeStyle.muted)
        } else {
            Label(store.savedPasswords.isEmpty
                  ? L10n.text("在密码管理里保存常用账号后，可在这里一键填入。")
                  : L10n.text("选择常用账号会自动填入用户名和密码。"), systemImage: "info.circle")
                .foregroundStyle(SnakeStyle.muted)
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("文件夹").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            Picker("文件夹", selection: $folderID) {
                Text("不放入文件夹").tag(UUID?.none)
                ForEach(store.folderPaths, id: \.folder.id) { target in Text(target.path).tag(Optional(target.folder.id)) }
            }
            .labelsHidden()
            .frame(height: 32)
        }
        .frame(maxWidth: .infinity)
    }

    private func compactField(label: String, text: Binding<String>, placeholder: String = "", monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .frame(height: 32)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var editorIconPreview: some View {
        if symbolName == SSHProfile.customIconSymbolName,
           let customIconData,
           let image = NSImage(data: customIconData) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 51, height: 51)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 1) }
        } else {
            Image(systemName: symbolName.isEmpty || symbolName == SSHProfile.customIconSymbolName ? "server.rack" : symbolName)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 51, height: 51)
                .background(SnakeStyle.action, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var savedCredentialAccount: String? {
        if authMethod == .privateKey, let pickedKeyID,
           let key = store.sshKeys.first(where: { $0.id == pickedKeyID }) {
            return key.hasPassphrase ? key.passphraseAccount : nil
        }
        if selectedFromLibraryThisEdit,
           let id = selectedSavedPasswordID,
           let item = store.savedPasswords.first(where: { $0.id == id }) { return item.credentialAccount }
        guard let originalProfile, originalProfile.authMethod == authMethod else { return nil }
        return originalProfile.keychainAccount
    }

    private func resolvePrivateKeyPath() {
        guard let bookmark = privateKeyBookmark else {
            privateKeyPath = nil
            privateKeyUnavailable = false
            return
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            privateKeyPath = url.path
            privateKeyUnavailable = stale || !FileManager.default.fileExists(atPath: url.path)
        } catch {
            privateKeyPath = nil
            privateKeyUnavailable = true
        }
    }

    private func selectProfileImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = L10n.text("选择照片")
        panel.begin { response in
            guard response == .OK,
                  let url = panel.url,
                  let image = NSImage(contentsOf: url) else { return }
            Task { @MainActor in
                cropSource = ProfileIconCropSource(image: image)
            }
        }
    }

    private func selectPrivateKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("选择私钥")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                Task { @MainActor in
                    privateKeyBookmark = bookmark
                    pickedKeyID = nil
                }
            } catch {
                Task { @MainActor in errorMessage = L10n.text("无法保存私钥访问授权。") }
            }
        }
    }

    private func pickLibraryKey(_ key: SSHKeyRecord) {
        do {
            privateKeyBookmark = try store.sshKeyBookmark(for: key.id)
            pickedKeyID = key.id
            credential.reset()
            errorMessage = nil
        } catch {
            errorMessage = L10n.text("无法保存私钥访问授权。")
        }
    }

    /// The library key's passphrase becomes this session's own copy, as a saved
    /// password does, unless the user typed a different one.
    private func libraryPassphrase() throws -> String? {
        guard authMethod == .privateKey, !credential.hasUserEdits, let pickedKeyID,
              let key = store.sshKeys.first(where: { $0.id == pickedKeyID }), key.hasPassphrase,
              let data = try CredentialStore.readData(account: key.passphraseAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func save() {
        guard let parsedPort = Int(port) else {
            errorMessage = L10n.text("端口必须是 1 到 65535 之间的数字。")
            return
        }
        let availableSavedPasswordID = selectedSavedPasswordID.flatMap { id in
            store.savedPasswords.contains(where: { $0.id == id }) ? id : nil
        }
        let profile = SSHProfile(
            id: profileID,
            // A folder deleted while the editor was open leaves the session at the top level.
            groupID: folderID.flatMap { id in store.groups.contains { $0.id == id } ? id : nil },
            name: name,
            host: host,
            port: parsedPort,
            username: username,
            authMethod: authMethod,
            keychainAccount: originalProfile?.authMethod == authMethod ? originalProfile?.keychainAccount : nil,
            privateKeyBookmark: privateKeyBookmark,
            // Tags are no longer edited; keep whatever an older version stored.
            tags: originalProfile?.tags ?? [],
            symbolName: symbolName.isEmpty ? "server.rack" : symbolName,
            sortOrder: originalProfile?.sortOrder ?? store.profiles.count,
            savedPasswordID: authMethod == .password && !credential.hasUserEdits ? availableSavedPasswordID : nil
        )
        do {
            if profile.usesCustomIcon {
                guard let customIconData else {
                    errorMessage = L10n.text("请重新选择并裁剪头像照片。")
                    return
                }
                try ProfileIconStore.save(customIconData, for: profile.id)
            }
            try store.save(profile: profile, credential: credential.valueToSave ?? libraryPassphrase(),
                           fromSavedPassword: selectedFromLibraryThisEdit && !credential.hasUserEdits ? availableSavedPasswordID : nil)
            if !profile.usesCustomIcon, originalProfile?.usesCustomIcon == true {
                ProfileIconStore.delete(for: profile.id)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProfileIconCropSource: Identifiable {
    let id = UUID()
    let image: NSImage
}

private struct ProfileIconCropView: View {
    let image: NSImage
    let onUse: (Data) -> Void
    let onCancel: () -> Void
    @State private var zoom = 1.0
    @State private var offset = CGSize.zero
    @State private var dragOrigin = CGSize.zero

    private let viewportSize: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("裁剪会话头像")
                        .font(.system(size: 18, weight: .bold))
                    Text("拖动照片调整位置，使用滑块缩放")
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                }
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark") }
                    .buttonStyle(SnakeIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 68)

            Divider()

            VStack(spacing: 18) {
                ZStack {
                    Color.black.opacity(0.92)
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: viewportSize, height: viewportSize)
                        .scaleEffect(zoom)
                        .offset(offset)
                    cropGrid
                }
                .frame(width: viewportSize, height: viewportSize)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1.5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            offset = clampedOffset(CGSize(
                                width: dragOrigin.width + value.translation.width,
                                height: dragOrigin.height + value.translation.height
                            ))
                        }
                        .onEnded { _ in dragOrigin = offset }
                )

                HStack(spacing: 11) {
                    Image(systemName: "photo")
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                    Slider(value: $zoom, in: 1...3)
                        .onChange(of: zoom) { _, _ in
                            offset = clampedOffset(offset)
                            dragOrigin = offset
                        }
                    Image(systemName: "photo.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SnakeStyle.muted)
                    Button("重置") {
                        zoom = 1
                        offset = .zero
                        dragOrigin = .zero
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(SnakeStyle.action)
                }
                .frame(width: viewportSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SnakeStyle.canvas)

            Divider()
            HStack {
                Text("保存后会生成 512×512 PNG，仅存放在 Snake 数据目录中。")
                    .font(.system(size: 10))
                    .foregroundStyle(SnakeStyle.muted)
                Spacer()
                Button("取消", action: onCancel)
                    .buttonStyle(SnakeOutlineButtonStyle())
                Button("使用头像") {
                    if let data = ProfileIconCropRenderer.pngData(
                        from: image,
                        zoom: zoom,
                        offset: offset,
                        viewportSize: viewportSize
                    ) {
                        onUse(data)
                    }
                }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22)
            .frame(height: 62)
        }
        .frame(width: 520, height: 500)
    }

    private var cropGrid: some View {
        ZStack {
            HStack(spacing: 0) {
                Spacer()
                Rectangle().fill(Color.white.opacity(0.24)).frame(width: 0.5)
                Spacer()
                Rectangle().fill(Color.white.opacity(0.24)).frame(width: 0.5)
                Spacer()
            }
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(Color.white.opacity(0.24)).frame(height: 0.5)
                Spacer()
                Rectangle().fill(Color.white.opacity(0.24)).frame(height: 0.5)
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }

    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return .zero }
        let baseScale = max(viewportSize / size.width, viewportSize / size.height)
        let displayedWidth = size.width * baseScale * zoom
        let displayedHeight = size.height * baseScale * zoom
        let maxX = max(0, (displayedWidth - viewportSize) / 2)
        let maxY = max(0, (displayedHeight - viewportSize) / 2)
        return CGSize(
            width: min(max(proposed.width, -maxX), maxX),
            height: min(max(proposed.height, -maxY), maxY)
        )
    }
}

@MainActor
enum ProfileIconCropRenderer {
    static func pngData(
        from image: NSImage,
        zoom: Double,
        offset: CGSize,
        viewportSize: CGFloat
    ) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0,
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 512,
                pixelsHigh: 512,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        let outputScale = 512 / viewportSize
        let baseScale = max(viewportSize / sourceSize.width, viewportSize / sourceSize.height)
        let drawWidth = sourceSize.width * baseScale * zoom * outputScale
        let drawHeight = sourceSize.height * baseScale * zoom * outputScale
        let drawX = ((viewportSize - sourceSize.width * baseScale * zoom) / 2 + offset.width) * outputScale
        let drawY = ((viewportSize - sourceSize.height * baseScale * zoom) / 2 - offset.height) * outputScale

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 512, height: 512).fill()
        image.draw(
            in: NSRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

private struct MappingEditorView: View {
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.dismiss) private var dismiss
    private let original: MountMapping?
    private let mappingID: UUID
    @State private var name: String
    @State private var profileID: UUID?
    @State private var remotePath: String
    @State private var userAccessPath: String
    @State private var autoMount: Bool
    @State private var errorMessage: String?
    @State private var browsingProfile: SSHProfile?

    init(mapping: MountMapping?) {
        original = mapping
        mappingID = mapping?.id ?? UUID()
        _name = State(initialValue: mapping?.name ?? "")
        _profileID = State(initialValue: mapping?.profileID)
        _remotePath = State(initialValue: mapping?.remotePath ?? "")
        _userAccessPath = State(initialValue: mapping?.userAccessPath ?? "")
        _autoMount = State(initialValue: mapping?.autoMount ?? true)
    }

    var body: some View {
        SnakeEditorSheet(
            context: L10n.text("磁盘映射"),
            title: original == nil ? L10n.text("新增映射") : L10n.text("编辑映射"),
            width: 720,
            height: 720,
            onClose: { dismiss() }
        ) {
            EditorSection(L10n.text("基本信息")) {
                HStack(alignment: .top, spacing: 12) {
                    EditorField(label: L10n.text("映射名称"), text: $name, placeholder: L10n.text("生产文件"))
                    EditorRow(L10n.text("SSH 会话")) {
                        Picker("SSH 会话", selection: $profileID) {
                            Text("选择一个 SSH 会话").tag(UUID?.none)
                            ForEach(store.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                        }
                        .labelsHidden()
                    }
                }
            }
            EditorSection(L10n.text("目录"), footnote: L10n.text("选择存放位置及入口名称，挂载后即可在 Finder 中访问。")) {
                EditorRow(L10n.text("远程目录")) {
                    HStack(spacing: 8) {
                        EditorValueBox(remotePath.isEmpty ? L10n.text("选择 SSH 会话后浏览远程文件夹") : remotePath,
                                       placeholder: remotePath.isEmpty) {}
                        Button("浏览目录…", systemImage: "folder") { browsingProfile = selectedProfile }
                            .buttonStyle(SnakeOutlineButtonStyle())
                            .disabled(selectedProfile == nil)
                    }
                }
                EditorRow(L10n.text("本地访问目录")) {
                    HStack(spacing: 8) {
                        TextField(L10n.text("选择 Finder 入口的位置"), text: $userAccessPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                        Button("选择位置…", systemImage: "folder") { chooseLocalPath() }
                            .buttonStyle(SnakeOutlineButtonStyle())
                    }
                }
            }
            EditorSection(L10n.text("选项")) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("应用启动时自动挂载").font(.system(size: 13, weight: .medium))
                        Text("启动时只尝试一次；失败后在映射列表中提示。")
                            .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                    }
                    Spacer(minLength: 12)
                    Toggle("应用启动时自动挂载", isOn: $autoMount)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }
            EditorSection(L10n.text("访问路径"), footnote: L10n.text("在 Finder 里打开入口，读写的就是服务器上的远程目录。")) {
                MappingAccessPaths(
                    remote: remotePath.isEmpty ? nil : "\(profileConnection):\(remotePath)",
                    mountPoint: selectedProfile != nil && !remotePath.isEmpty ? managedPath : nil,
                    volumeName: volumeName,
                    entry: userAccessPath.isEmpty ? nil : userAccessPath
                )
            }
            if let errorMessage { Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red) }
        } leading: {
            Button("取消") { dismiss() }.buttonStyle(SnakeOutlineButtonStyle())
        } trailing: {
            Button("保存映射") { save() }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
        }
        .onChange(of: profileID) { _, _ in
            remotePath = ""
            errorMessage = nil
        }
        .sheet(item: $browsingProfile) { profile in
            RemoteDirectoryPicker(profile: profile, initialPath: remotePath) { path in
                remotePath = path
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    name = path == "/" ? profile.name : (path as NSString).lastPathComponent
                }
                errorMessage = nil
            }
        }
    }

    private var selectedProfile: SSHProfile? {
        store.profiles.first { $0.id == profileID }
    }

    private func chooseLocalPath() {
        let panel = NSSavePanel()
        panel.title = L10n.text("选择本地访问目录")
        panel.message = L10n.text("选择 Finder 入口的存放位置和名称。请使用尚不存在的名称。")
        panel.prompt = L10n.text("选择")
        panel.nameFieldLabel = L10n.text("入口名称：")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !userAccessPath.isEmpty {
            let url = URL(fileURLWithPath: (userAccessPath as NSString).expandingTildeInPath)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            let suggestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            panel.nameFieldStringValue = suggestedName.isEmpty ? L10n.text("远程目录") : suggestedName.replacingOccurrences(of: "/", with: "-")
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel selects a future symlink location; it does not create a file.
            if FileManager.default.fileExists(atPath: url.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                errorMessage = L10n.text("该本地位置已被占用，请选择其他入口名称。")
                return
            }
            userAccessPath = url.path
            errorMessage = nil
        }
    }

    private var profileConnection: String {
        store.profiles.first(where: { $0.id == profileID })?.connectionLabel ?? L10n.text("选择 SSH 会话")
    }

    /// What Finder's sidebar calls the mounted disk, once there is enough to name it.
    private var volumeName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profile = selectedProfile, !trimmed.isEmpty else { return nil }
        return MountOperations.volumeName(mappingName: trimmed, connectionName: profile.name)
    }

    private var managedPath: String {
        if let original, !ManagedMountPath.isStable(original.managedMountPath) {
            return original.managedMountPath
        }
        guard let profile = selectedProfile,
              let path = try? ManagedMountPath.make(profile: profile, local: userAccessPath, remote: remotePath) else {
            return L10n.text("选择会话和目录后生成")
        }
        return path
    }

    private func save() {
        guard let profileID else {
            errorMessage = L10n.text("请选择一个 SSH 会话。")
            return
        }
        guard !remotePath.isEmpty else {
            errorMessage = L10n.text("请浏览并选择远程目录。")
            return
        }
        let mapping = MountMapping(
            id: mappingID,
            profileID: profileID,
            name: name,
            remotePath: remotePath,
            userAccessPath: userAccessPath,
            managedMountPath: managedPath,
            autoMount: autoMount,
            state: .idle
        )
        do {
            try store.save(mapping: mapping)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct MountDependencyStatus {
    let macFUSEAvailable: Bool
    let sshfsPath: String?

    var isReady: Bool { macFUSEAvailable && sshfsPath != nil }

    static func detect() -> MountDependencyStatus {
        let manager = FileManager.default
        let candidates = ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs"]
        return MountDependencyStatus(
            macFUSEAvailable: manager.fileExists(atPath: "/Library/Filesystems/macfuse.fs"),
            sshfsPath: candidates.first(where: manager.isExecutableFile(atPath:))
        )
    }
}

/// Settings is application-modal: while its window is open no other Snake
/// window accepts input, so it has to be closed before returning to work.
private struct SettingsModalAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsModalAnchorView { SettingsModalAnchorView() }
    func updateNSView(_ nsView: SettingsModalAnchorView, context: Context) {}
}

final class SettingsModalAnchorView: NSView {
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window !== observedWindow else { return }
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow)
        }
        observedWindow = window
        guard let window else { return }
        // A minimised modal window would leave every other window unusable.
        window.styleMask.remove(.miniaturizable)
        // SwiftUI reuses the window, so modality restarts each time it comes back.
        center.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        beginModalIfNeeded()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) { beginModalIfNeeded() }

    @objc private func windowWillClose(_ notification: Notification) {
        if let window = observedWindow, NSApp.modalWindow === window { NSApp.stopModal() }
    }

    /// The File menu's Command-W targets workspace tabs and is disabled while
    /// modal; close Settings itself instead of beeping.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "w",
              let window = observedWindow, window.isKeyWindow, window.attachedSheet == nil else {
            return super.performKeyEquivalent(with: event)
        }
        window.performClose(nil)
        return true
    }

    /// Deferred so the window finishes ordering in before the modal loop starts.
    private func beginModalIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let window = self?.observedWindow, window.isVisible, NSApp.modalWindow == nil else { return }
                NSApp.runModal(for: window)
            }
        }
    }
}

/// Shared container for every settings tab.
///
/// A bare `Form` neither scrolls nor aligns to the top inside a fixed window,
/// so each pane scrolls, keeps the same outer padding and starts at the top
/// instead of being vertically centred with large empty margins.
struct SettingsPane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            Form {
                content
            }
            .formStyle(.grouped)
            // The window's canvas shows through, so the form has no shorter grey slab.
            .scrollContentBackground(.hidden)
        }
    }
}

/// Section footer text.
///
/// A grouped `Form` inside a `ScrollView` lays its footers out with trailing
/// alignment; pinning the text to the leading edge matches the rest of macOS.
struct SettingsFooter: View {
    private let key: LocalizedStringKey

    init(_ key: LocalizedStringKey) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

public struct SnakeSettingsView: View {
    @EnvironmentObject private var store: ApplicationStore
    @State private var shortcutError: String?
    @State private var remoteOpenUsage: RemoteOpenCacheReport?
    @State private var remoteOpenError: String?
    @State private var confirmsRemoteOpenClear = false
    @State private var serverRelayError: String?
    @State private var section: SettingsSection = .appearance
    @AppStorage(PasswordAutoFill.defaultsKey) private var passwordAutoFill = true

    public init() {}

    /// Settings use a sidebar like System Settings: every pane gets the full width
    /// instead of sharing a narrow tab strip. Passwords moved to their own tab.
    enum SettingsSection: CaseIterable, Identifiable {
        case appearance, transfer, shortcuts, terminal, privacy
        var id: Self { self }

        var title: String {
            switch self {
            case .appearance: L10n.text("外观")
            case .transfer: L10n.text("传输")
            case .shortcuts: L10n.text("快捷键")
            case .terminal: L10n.text("终端")
            case .privacy: L10n.text("隐私与安全")
            }
        }

        var detail: String {
            switch self {
            case .appearance: L10n.text("应用外观与界面语言")
            case .transfer: L10n.text("SFTP 并行传输、打开远程文件与服务器互传")
            case .shortcuts: L10n.text("工作区与 SFTP 快捷键")
            case .terminal: L10n.text("终端配色、字体与渲染")
            case .privacy: L10n.text("密码输入与自动填充")
            }
        }

        /// `terminal` is a pictogram; `textformat` would render as 「格式」 in Chinese.
        var symbol: String {
            switch self {
            case .appearance: "circle.lefthalf.filled"
            case .transfer: "arrow.up.arrow.down"
            case .shortcuts: "command"
            case .terminal: "terminal"
            case .privacy: "lock.fill"
            }
        }

        var tint: Color {
            switch self {
            case .appearance: .indigo
            case .transfer: .blue
            case .shortcuts: .gray
            case .terminal: .teal
            case .privacy: .green
            }
        }
    }

    public var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(.system(size: 20, weight: .bold))
                    Text(section.detail).font(.system(size: 12)).foregroundStyle(SnakeStyle.muted)
                }
                // Lines the title up with the grouped form's section boxes below it.
                .padding(.horizontal, 50)
                .padding(.top, 22)
                .padding(.bottom, 2)
                Group {
                    switch section {
                    case .appearance: appearancePane
                    case .transfer: transferPane
                    case .shortcuts: shortcutPane
                    case .terminal: terminalPane
                    case .privacy: privacyPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(SnakeStyle.canvas)
        }
        .frame(minWidth: 780, idealWidth: 900, minHeight: 560, idealHeight: 680)
        .background(SettingsModalAnchor())
        .environment(\.locale, store.appLanguage.locale)
        .preferredColorScheme(store.isDarkAppearancePreferred ? .dark : .light)
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { item in
                Button { section = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(item.tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(item.title).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .background(section == item ? SnakeStyle.selectedRow : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == item ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(10)
        .padding(.top, 8)
        .frame(width: 200)
        .background(SnakeStyle.chromeFrost)
    }

    // MARK: - Panes

    private var appearancePane: some View {
        SettingsPane {
            Section {
                Picker("外观", selection: $store.isDarkAppearancePreferred) {
                    Text("浅色").tag(false)
                    Text("深色").tag(true)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("应用外观")
            } footer: {
                SettingsFooter("立即应用到所有窗口与终端，并记住本次选择；不会重新连接或清空终端内容。")
            }
            Section {
                Picker("语言", selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                Text("语言")
            } footer: {
                SettingsFooter("界面语言立即生效并记住选择；系统权限弹窗、Finder 与 macOS 提供的菜单文案跟随系统语言。")
            }
        }
    }

    private var privacyPane: some View {
        SettingsPane {
            Section {
                Toggle("点击密码输入框时显示系统密码自动填充", isOn: $passwordAutoFill)
            } header: {
                Text("密码输入")
            } footer: {
                SettingsFooter("关闭后，Snake 的密码和私钥口令输入框不再弹出 macOS「密码」的自动填充建议，需要手动输入或粘贴。只影响 Snake 自己的输入框，不改动系统的密码设置。")
            }
        }
    }

    private var transferPane: some View {
        SettingsPane {
            Section {
                LabeledContent("并行传输阈值") {
                    HStack(spacing: 6) {
                        TextField("", value: $store.multipartThresholdMB, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            .accessibilityLabel(L10n.text("并行传输阈值"))
                        Text("MB").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("并行连接数") {
                    Stepper(value: $store.multipartConcurrency, in: 1...8) {
                        Text(L10n.format("%@ 个", store.multipartConcurrency))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("每主机连接数") {
                    Stepper(value: $store.hostConcurrencyLimit, in: HostTransferBudget.allowedLimits) {
                        Text(L10n.format("%@ 个", store.hostConcurrencyLimit))
                            .frame(width: 48, alignment: .trailing)
                    }
                }
            } header: {
                Text("SFTP 传输")
            } footer: {
                SettingsFooter("超过阈值的文件使用独立 SFTP 连接分片上传或下载；下载文件和分片共享并发上限。上传支持续传，下载重试重新传输。校验优先 SHA-256，其次 MD5，不可用时标记未校验，不读回文件。同时进行多个传输时，同一台主机的分片与逐文件传输连接受「每主机连接数」约束；每个标签的常驻连接、每个上传批次的 1 条操作连接不计入。超出的传输会在记录里显示“等待中”。")
            }
            Section {
                LabeledContent("保存目录") {
                    HStack(spacing: 8) {
                        Text(store.remoteOpenDirectoryPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(store.remoteOpenDirectoryPath)
                        Button("选择…") { chooseRemoteOpenDirectory() }
                        if store.remoteOpenDirectoryBookmark != nil {
                            Button("恢复默认") {
                                remoteOpenError = store.setRemoteOpenDirectory(nil)
                                Task { await refreshRemoteOpenUsage() }
                            }
                        }
                    }
                }
                Picker("自动清理", selection: $store.remoteOpenCleanupPolicy) {
                    ForEach(RemoteOpenCleanupPolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                Picker("容量上限", selection: $store.remoteOpenSizeLimit) {
                    ForEach(RemoteOpenSizeLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                LabeledContent("当前占用") {
                    HStack(spacing: 8) {
                        Text(remoteOpenUsageText).foregroundStyle(.secondary)
                        Button("立即清理") { confirmsRemoteOpenClear = true }
                            .disabled((remoteOpenUsage?.files ?? 0) == 0)
                    }
                }
                if let remoteOpenError {
                    Label(remoteOpenError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = store.remoteOpenCacheNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("打开远程文件")
            } footer: {
                SettingsFooter("打开远程文件时先下载到该目录再交给系统打开；Snake 只清理自己下载的副本，不会改动所选目录中的其他内容。默认位置是系统缓存目录。")
            }
            Section {
                LabeledContent("中转目录") {
                    HStack(spacing: 8) {
                        Text(store.serverRelayDirectoryPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(store.serverRelayDirectoryPath)
                        Button("选择…") { chooseServerRelayDirectory() }
                        if store.serverRelayDirectoryBookmark != nil {
                            Button("恢复默认") { serverRelayError = store.setServerRelayDirectory(nil) }
                        }
                    }
                }
                if let serverRelayError {
                    Label(serverRelayError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = store.serverRelayNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("服务器互传")
            } footer: {
                SettingsFooter("把文件从一个 SFTP 标签拖到另一台服务器时，先下载到该目录，再上传到目标服务器；上传结束后（无论成功、失败或取消）立即删除本次中转文件，失败后需重新拖动。中转需要与文件大小相当的本地空间，不传输软链接。默认位置是系统缓存目录。")
            }
        }
        .task { await refreshRemoteOpenUsage() }
        .confirmationDialog("确定要清理已下载的远程文件副本吗？", isPresented: $confirmsRemoteOpenClear, titleVisibility: .visible) {
            Button("立即清理", role: .destructive) {
                Task {
                    _ = await store.clearRemoteOpenCache()
                    await refreshRemoteOpenUsage()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理后再次打开会重新下载。")
        }
    }

    private var remoteOpenUsageText: String {
        guard let remoteOpenUsage else { return L10n.text("正在读取…") }
        return L10n.plural(
            "%@ 个文件 · %@",
            count: remoteOpenUsage.files,
            remoteOpenUsage.files,
            L10n.byteCount(remoteOpenUsage.bytes)
        )
    }

    private func refreshRemoteOpenUsage() async {
        if let usage = await store.remoteOpenCacheUsage() {
            remoteOpenUsage = usage
            remoteOpenError = nil
        } else {
            remoteOpenError = L10n.text("缓存目录无法访问，暂时无法显示占用。")
        }
    }

    private func chooseRemoteOpenDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("选择")
        panel.message = L10n.text("选择保存已打开远程文件的目录。")
        panel.directoryURL = URL(fileURLWithPath: store.remoteOpenDirectoryPath, isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                remoteOpenError = store.setRemoteOpenDirectory(url)
                await refreshRemoteOpenUsage()
            }
        }
    }

    private func chooseServerRelayDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L10n.text("选择")
        panel.message = L10n.text("选择服务器互传时存放中转文件的目录。")
        panel.directoryURL = URL(fileURLWithPath: store.serverRelayDirectoryPath, isDirectory: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in serverRelayError = store.setServerRelayDirectory(url) }
        }
    }

    private var shortcutPane: some View {
        SettingsPane {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("新建 SSH 会话标签")
                        Text("在当前分栏打开新的会话管理标签")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    SFTPShortcutRecorder(shortcut: store.newSessionTabShortcut) { newShortcut in
                        shortcutError = store.updateNewSessionTabShortcut(newShortcut)
                    }
                    .frame(width: 150, height: 28)
                }
                .padding(.vertical, 2)
            } header: {
                Text("工作区快捷键")
            }
            Section {
                shortcutRow(.search, detail: L10n.text("打开并聚焦当前目录检索"))
                shortcutRow(.delete, detail: L10n.text("确认后删除当前选中的远程项目"))
                shortcutRow(.uploadFile, detail: L10n.text("打开访达文件选择器并上传到当前目录"))
                if let shortcutError {
                    Label(shortcutError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("SFTP 快捷键")
            } footer: {
                SettingsFooter("点击右侧键帽后按下新组合。为避免在地址栏中误操作，快捷键必须包含 Command、Control 或 Option；冲突组合不会保存。")
            }
            Section {
                Button("恢复默认快捷键") {
                    store.resetAllShortcuts()
                    shortcutError = nil
                }
            }
        }
    }

    private var terminalPane: some View {
        SettingsPane {
            Section {
                Picker("配色主题", selection: $store.selectedTerminalThemeID) {
                    Section("内置") {
                        ForEach(TerminalThemePreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    if !store.importedTerminalThemes.isEmpty {
                        Section("已导入") {
                            ForEach(store.importedTerminalThemes) { theme in
                                Text(theme.name).tag(theme.selectionID)
                            }
                        }
                    }
                }
                HStack {
                    Button("导入 .itermcolors…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [UTType(filenameExtension: "itermcolors")
                            ?? UTType(importedAs: "com.snake.itermcolors")]
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { store.importTerminalTheme(from: url) }
                    }
                    if store.selectedTerminalThemeID.hasPrefix("imported:") {
                        Button("删除已选主题", role: .destructive) { store.deleteSelectedImportedTerminalTheme() }
                    }
                }
                if let notice = store.terminalThemeNotice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Toggle("日志关键词高亮", isOn: $store.terminalLogHighlightEnabled)
                Toggle("输出字段高亮", isOn: $store.terminalFieldHighlightEnabled)
            } header: {
                Text("终端配色")
            } footer: {
                SettingsFooter("内置浅色主题使用 Snake 白底适配；导入主题保留原背景。只改变终端显示，不修改远端 ls／ll。")
            }
            Section {
                Picker("字体", selection: $store.terminalFontName) {
                    ForEach(terminalFonts, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }
                LabeledContent("字号") {
                    Stepper(value: $store.terminalFontSize, in: 9...32, step: 1) {
                        Text("\(Int(store.terminalFontSize)) pt")
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Toggle("GPU 渲染（Metal）", isOn: $store.terminalMetalRenderingEnabled)
            } header: {
                Text("终端字体")
            } footer: {
                SettingsFooter("GPU 渲染在大量输出时更流畅；如遇显示异常可关闭，改用 CPU 绘制。")
            }
            Section {
                Text("终端配色示例 · 文件颜色仅用于预览")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                terminalColorPreview
            } footer: {
                SettingsFooter("配色、高亮与字体立即应用到所有终端，不会重连或清空屏幕缓冲。")
            }
        }
    }

    private var previewTheme: TerminalTheme {
        store.terminalTheme(isDark: store.isDarkAppearancePreferred)
    }

    /// A shortcut row keeps its recorder at a fixed width and lets the
    /// explanation wrap under the title instead of widening the form's label
    /// column (which used to squeeze the recorder in English).
    private func shortcutRow(_ action: SFTPShortcutAction, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            SFTPShortcutRecorder(shortcut: shortcut(for: action)) { newShortcut in
                shortcutError = store.updateSFTPShortcut(action, shortcut: newShortcut)
            }
            .frame(width: 150, height: 28)
        }
        .padding(.vertical, 2)
    }

    private func shortcut(for action: SFTPShortcutAction) -> SFTPShortcut {
        switch action {
        case .search: store.sftpSearchShortcut
        case .delete: store.sftpDeleteShortcut
        case .uploadFile: store.sftpUploadShortcut
        }
    }

    private var terminalColorPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("user@snake ~ % ls")
            (Text("Documents/  ").foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[4])))
             + Text("logs/  ").foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[6])))
             + Text("start.sh").foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[2]))))
            Text("普通输出 · 连接保持正常")
            Text("# gray / comment / 次要输出")
                .foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[8])))
            previewLog("drwxr-xr-x  4.0K  2026-09-13 09:30")
            previewLog("running  192.0.2.10:22  /var/log  80%")
            previewLog(L10n.text("[ERROR] FATAL 连接超时"))
            previewLog(L10n.text("WARN / WARNING 正在重试"))
            previewLog(L10n.text("INFO 服务已启动"))
            previewLog(L10n.text("DEBUG / TRACE 请求完成"))
        }
        .font(.custom(store.terminalFontName, size: store.terminalFontSize))
        .foregroundStyle(Color(nsColor: TerminalTheme.nsColor(previewTheme.foregroundHex)))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Wrap sample lines instead of clipping them when the chosen font size
        // makes them wider than the pane.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: TerminalTheme.nsColor(previewTheme.backgroundHex)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("终端配色预览")
    }

    private func previewLog(_ line: String) -> Text {
        let source = line as NSString
        var result = Text("")
        var offset = 0
        let matcher = TerminalOutputHighlighter(logs: store.terminalLogHighlightEnabled,
                                               fields: store.terminalFieldHighlightEnabled)
        for match in matcher.matches(in: line) {
            result = result + Text(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
                + Text(source.substring(with: match.range)).foregroundColor(
                    Color(nsColor: TerminalTheme.nsColor(match.color(in: previewTheme))))
            offset = NSMaxRange(match.range)
        }
        return result + Text(source.substring(from: offset))
    }

    private var terminalFonts: [String] {
        let names = NSFontManager.shared.availableFonts.filter { name in
            NSFont(name: name, size: 13)?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
        }
        return Array(Set(names + [store.terminalFontName])).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

/// The three places a mapping's files pass through, top to bottom, each on a
/// full-width line so long paths stay readable instead of being squeezed into
/// three columns.
private struct MappingAccessPaths: View {
    let remote: String?
    let mountPoint: String?
    let volumeName: String?
    let entry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MappingPathStep(
                symbol: "server.rack",
                title: L10n.text("远程目录"),
                caption: L10n.text("服务器上的文件夹"),
                value: remote,
                placeholder: L10n.text("选择 SSH 会话后浏览远程文件夹"),
                isLast: false
            )
            MappingPathStep(
                symbol: "externaldrive",
                title: L10n.text("实际挂载点"),
                caption: volumeName.map { L10n.format("SSHFS 挂载在这里，Finder 侧栏显示为「%@」", $0) }
                    ?? L10n.text("SSHFS 挂载在这里，由 Snake 管理"),
                value: mountPoint,
                placeholder: L10n.text("选择会话和目录后生成"),
                isLast: false
            )
            MappingPathStep(
                symbol: "folder",
                title: L10n.text("Finder 入口（软链接）"),
                caption: L10n.text("指向挂载点，平时从这里打开"),
                value: entry,
                placeholder: L10n.text("选择 Finder 入口的位置"),
                isLast: true
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SnakeStyle.hairline, lineWidth: 1) }
    }
}

private struct MappingPathStep: View {
    let symbol: String
    let title: String
    let caption: String
    let value: String?
    let placeholder: String
    let isLast: Bool
    @State private var copied = false

    private var tint: Color { value == nil ? .secondary : SnakeStyle.action }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(value == nil ? SnakeStyle.muted : SnakeStyle.action)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.12), in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(SnakeStyle.hairline)
                        .frame(width: 1.5)
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(value ?? placeholder)
                    .font(.system(size: 12, design: value == nil ? .default : .monospaced))
                    .foregroundStyle(value == nil ? SnakeStyle.muted : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(value ?? "")
            }
            .padding(.top, 1)
            .padding(.bottom, isLast ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let value {
                Button { copy(value) } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                }
                .buttonStyle(SnakeIconButtonStyle())
                .help("复制路径").accessibilityLabel("复制路径")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
