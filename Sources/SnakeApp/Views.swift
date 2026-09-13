import AppKit
import Bonsplit
import SnakeCoreBindings
import SwiftUI
import UniformTypeIdentifiers

private extension UTType {
    static let snakeRemoteFile = UTType(exportedAs: "com.snake.remote-file-reference")
}

private struct SFTPFileDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var receivesFinderFiles: Bool
    let finderTarget: () -> FinderUploadTarget
    let upload: ([NSItemProvider], String) -> Void
    let perform: ([NSItemProvider]) -> Void

    private func isWorkspace(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: WorkspaceDragPayload.types.map(\.rawValue))
    }

    func validateDrop(info: DropInfo) -> Bool {
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
        finderDropLog.notice("Table perform")
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
                    .environment(\.colorScheme, store.isDarkAppearancePreferred ? .dark : .light)
            ), isDark: store.isDarkAppearancePreferred))
            .background(SnakeStyle.canvas)
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
                Image(systemName: "externaldrive")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(SnakeIconButtonStyle(selected: windowState.selectedRuntime?.kind == .mounts))
            .help("打开磁盘映射").accessibilityLabel("打开磁盘映射")


        }
        .padding(.horizontal, 4)
        .frame(height: 40)
    }
}

private struct SessionCatalogView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: WorkspaceTabRuntime
    let onEdit: (SSHProfile) -> Void
    let onNewProfile: () -> Void
    let onConnect: (SSHProfile, Bool) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            heading
                            Spacer(minLength: 16)
                            newProfileButton
                        }
                        VStack(alignment: .leading, spacing: 12) { heading; newProfileButton }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { searchField.frame(minWidth: 160); tagFilter.frame(width: 180) }
                        VStack(spacing: 8) { searchField; tagFilter }
                    }
                    if filteredProfiles.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "server.rack").font(.system(size: 28))
                            Text(store.profiles.isEmpty ? "暂无 SSH 会话" : "没有匹配的会话")
                                .font(.headline)
                            Text(store.profiles.isEmpty ? "新建会话，保存连接信息后即可打开终端或 SFTP。" : "试试其他名称、地址或标签。")
                                .foregroundStyle(SnakeStyle.muted)
                            if store.profiles.isEmpty { newProfileButton }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 48)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: min(280, max(1, geometry.size.width - 32))), spacing: 16)], spacing: 16) {
                            ForEach(filteredProfiles) { profile in
                                SessionProfileCard(
                                    profile: profile,
                                    selected: runtime.selectedProfileID == profile.id,
                                    onSelect: { runtime.selectedProfileID = profile.id },
                                    onEdit: { onEdit(profile) },
                                    onConnect: { onConnect(profile, $0) }
                                )
                            }
                        }
                    }
                }
                .padding(geometry.size.width < 500 ? 16 : 24)
            }
        }
        .background(SnakeStyle.canvas)
        .onChange(of: runtime.searchFocusRequest) { _, _ in searchFocused = true }
        .onAppear { if runtime.searchFocusRequest > 0 { searchFocused = true } }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SSH 会话").font(.system(size: 22, weight: .bold))
            Text("选择会话，在当前标签打开终端或 SFTP。")
                .font(.system(size: 13)).foregroundStyle(SnakeStyle.muted)
        }
    }
    private var newProfileButton: some View {
        Button("新建会话", systemImage: "plus", action: onNewProfile)
            .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
    }
    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(SnakeStyle.muted)
            TextField("搜索会话、IP 或标签", text: $runtime.searchQuery)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityIdentifier("session-catalog-search")
        }
        .padding(10)
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(SnakeStyle.hairline, lineWidth: 1) }
    }

    private var tagFilter: some View {
        let tags = Array(Set(store.profiles.flatMap(\.tags))).sorted()
        return HStack(spacing: 7) {
            Menu {
                Button {
                    runtime.selectedTags.removeAll()
                } label: {
                    Label("全部标签", systemImage: runtime.selectedTags.isEmpty ? "checkmark" : "tag")
                }
                if !tags.isEmpty { Divider() }
                ForEach(tags, id: \.self) { tag in
                    Toggle(tag, isOn: Binding(
                        get: { runtime.selectedTags.contains(tag) },
                        set: { selected in
                            if selected { runtime.selectedTags.insert(tag) }
                            else { runtime.selectedTags.remove(tag) }
                        }
                    ))
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: runtime.selectedTags.isEmpty ? "tag" : "tag.fill")
                        .foregroundStyle(runtime.selectedTags.isEmpty ? SnakeStyle.muted : SnakeStyle.action)
                    Text(runtime.selectedTags.isEmpty ? "全部标签" : "已选 \(runtime.selectedTags.count) 个标签")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SnakeStyle.muted)
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SnakeStyle.hairline, lineWidth: 1) }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: .infinity)

            if !runtime.selectedTags.isEmpty {
                Button { runtime.selectedTags.removeAll() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(SnakeStyle.muted)
                }
                .buttonStyle(.plain)
                .help("清除标签筛选")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
    }

    private var filteredProfiles: [SSHProfile] {
        store.profiles
            .sorted {
                if $0.sortOrder == $1.sortOrder {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.sortOrder < $1.sortOrder
            }
            .filter(matches)
    }

    private func matches(_ profile: SSHProfile) -> Bool {
        let query = runtime.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchesTag = SessionTagFilter.matches(profileTags: profile.tags, selectedTags: runtime.selectedTags)
        guard matchesTag else { return false }
        guard !query.isEmpty else { return true }
        return [profile.name, profile.host, profile.username, profile.tags.joined(separator: " ")]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query)
    }

}

private struct SessionProfileCard: View {
    @EnvironmentObject private var store: ApplicationStore
    let profile: SSHProfile
    let selected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onConnect: (Bool) -> Void
    @State private var confirmsDeletion = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ProfileIconView(profile: profile, size: 38, cornerRadius: 9)
                    Text(profile.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(profile.connectionLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SnakeStyle.muted).lineLimit(1).truncationMode(.middle)
                Text(profile.tags.isEmpty ? "未设置标签" : profile.tags.joined(separator: "  ·  "))
                    .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ProfileDragSourceRegion(profileID: profile.id))
            .contentShape(Rectangle())
            // Selection must not wait for the system double-click timeout.
            // Keep the independent double tap for opening a terminal, just as
            // SFTP rows select immediately while also supporting double-open.
            .onTapGesture(count: 2) {
                onSelect()
                onConnect(false)
            }
            .simultaneousGesture(TapGesture().onEnded {
                onSelect()
            })
            HStack(spacing: 8) {
                Button("新建终端", systemImage: "terminal") { onConnect(false) }
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                Button("SFTP", systemImage: "folder") { onConnect(true) }
                    .buttonStyle(SnakeOutlineButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? SnakeStyle.action : SnakeStyle.hairline, lineWidth: selected ? 1.5 : 1) }
        .contextMenu {
            Button("新建终端", systemImage: "terminal") { onConnect(false) }
            Button("打开 SFTP", systemImage: "folder") { onConnect(true) }
            Divider()
            Button("修改", systemImage: "pencil", action: onEdit)
            Button("删除", systemImage: "trash", role: .destructive) { confirmsDeletion = true }
        }
        .alert("删除 SSH 会话？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { store.delete(profile: profile) }
        } message: {
            Text("将关闭相关终端和 SFTP 连接、禁用关联映射，并删除该会话保存的凭据。传输历史会保留会话快照。")
        }
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
                    _ = windowState.add(WorkspaceTabRuntime(manager: .sessions), to: paneID)
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
                SessionCatalogView(runtime: runtime, onEdit: { editingProfile = $0 }, onNewProfile: { creatingProfile = true }) { profile, asSFTP in
                    guard runtime.kind == .sessions else { return }
                    if !windowState.connectChooser(tabID: tabID, profileID: profile.id, asSFTP: asSFTP, store: store) {
                        connectionError = "该会话已不可用，请刷新会话列表后重试。"
                    }
                }
            case .mounts:
                MountWorkspaceView(runtime: runtime, onNewMapping: { creatingMapping = true }, onEditMapping: { editingMapping = $0 })
            case .terminal, .sftp:
                FinderUploadSurface(
                    content: connectionContent.environmentObject(store),
                    isActive: {
                        windowState.tabs[tabID] === runtime && windowState.bonsplit.selectedTab(inPane: paneID)?.id == tabID
                    },
                    target: { runtime.finderUploadTarget },
                    perform: { urls, target, window in
                        windowState.bonsplit.focusPane(paneID)
                        runtime.uploadFromFinder(urls: urls, target: target, window: window, store: store)
                    }
                )
            }
        }
        .sheet(isPresented: $creatingProfile) { SessionEditorView(profile: nil).environmentObject(store) }
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
        else if let sftp = runtime.sftp { SFTPBrowserView(runtime: sftp) }
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
                Text(state == .idle ? "待连接" : state.label)
                    .fontWeight(.semibold)
            }
            Rectangle().fill((dark ? Color.white : Color.primary).opacity(0.16)).frame(width: 1, height: 13)
            Text(profile.connectionLabel)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            UploadStatusEntry(uploader: uploader, contextName: "终端", showsLabel: false)
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
            .help(securityInfo == nil ? "连接后可查看安全详情" : "查看连接安全详情")
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

            securityRow("主机密钥", security.hostKeyAlgorithm)
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
            securityRow("密钥交换", security.keyExchangeAlgorithm)
            securityRow("发送加密", security.clientToServerCipher)
            securityRow("接收加密", security.serverToClientCipher)
            securityRow("发送完整性", integrityLabel(security.clientToServerMac, cipher: security.clientToServerCipher))
            securityRow("接收完整性", integrityLabel(security.serverToClientMac, cipher: security.serverToClientCipher))
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
            return "由加密算法内置"
        }
        return "服务器未报告"
    }
}

private struct TerminalTabView: View {
    @ObservedObject var runtime: TerminalRuntime
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.colorScheme) private var colorScheme


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
                if runtime.state == .connecting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(runtime.connectionStatusText)
                        Spacer()
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(terminalForeground.opacity(0.82))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(SnakeStyle.action.opacity(0.16))
                } else if let error = runtime.errorMessage {
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
                    shellColorsEnabled: store.terminalShellColorsEnabled
                )
                    .background(terminalBackground)
                    .background(FinderUploadArea())
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
                Text("\(runtime.uploader.pendingConflict?.remotePath ?? "") 已存在。覆盖会在上传完整后替换原文件。")
            }
        }

        .alert(runtime.pendingHostKey?.title ?? "确认主机密钥", isPresented: Binding(
            get: { runtime.pendingHostKey != nil },
            set: { if !$0, runtime.pendingHostKey != nil { runtime.rejectPendingHostKey() } }
        )) {
            Button("取消", role: .cancel) { runtime.rejectPendingHostKey() }
            Button(runtime.pendingHostKey?.acceptTitle ?? "信任并连接") { runtime.acceptPendingHostKey() }
        } message: {
            if let key = runtime.pendingHostKey {
                Text(key.message)
            }
        }
    }

    private var terminalTheme: TerminalTheme {
        TerminalTheme(preset: store.terminalThemePreset, isDark: colorScheme == .dark,
                      logHighlightEnabled: store.terminalLogHighlightEnabled,
                      fieldHighlightEnabled: store.terminalFieldHighlightEnabled)
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
    @State private var creationKind: RemoteItemCreationKind?
    @State private var creationDestination: SFTPDirectoryDestination?
    @State private var newItemName = ""
    @State private var pathDraft = "/"
    @State private var navigationNotice: String?
    @State private var navigationNoticeID = UUID()
    @FocusState private var isEditingPath: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 7, height: 7)
                    .help(runtime.connectionState.label)
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(SFTPNavigationButtonStyle(isAvailable: runtime.canGoBack))
                    .help(runtime.canGoBack ? "后退" : "没有可回退的目录")
                    .accessibilityLabel("后退")
                    .accessibilityHint(runtime.canGoBack ? "返回上一个访问过的目录" : "没有可回退的目录")
                Button { goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(SFTPNavigationButtonStyle(isAvailable: runtime.canGoForward))
                    .help(runtime.canGoForward ? "前进" : "没有可前进的目录")
                    .accessibilityLabel("前进")
                    .accessibilityHint(runtime.canGoForward ? "前往下一个访问过的目录" : "没有可前进的目录")
                Button { navigateUp() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(SFTPNavigationButtonStyle(isAvailable: runtime.currentPath != "/"))
                    .help(runtime.currentPath == "/" ? "已经位于顶级目录" : "返回上一级")
                    .accessibilityLabel("返回上一级")
                    .accessibilityHint(runtime.currentPath == "/" ? "已经位于顶级目录" : "打开父目录")
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
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(SnakeStyle.chromeFrost)

            if runtime.connectionState == .connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在建立安全 SFTP 连接…")
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(SnakeStyle.action.opacity(0.07))
            } else if let loadingPath = runtime.loadingPath {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在打开 \(loadingPath)")
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
            } else if let error = runtime.deletionError ?? runtime.errorMessage ?? runtime.uploader.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).lineLimit(2).help(error)
                    Spacer()
                    Button(runtime.deletionError == nil ? "重试" : "知道了") {
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
                onFocusFiles: { isEditingPath = false },
                onOpen: open,
                onCreateFile: { beginCreation(.file) },
                onCreateDirectory: { beginCreation(.directory) },
                onUploadFiles: { chooseFiles(allowsDirectories: false) },
                onUploadDirectory: { chooseFiles(allowsDirectories: true) }
            )
        }
        .background(uploadConflictAlert)
        .task { runtime.connectIfNeeded() }
        .onAppear { pathDraft = runtime.currentPath }
        .onChange(of: runtime.currentPath) { _, newPath in
            pathDraft = newPath
        }
        .onChange(of: isEditingPath) { _, editing in
            if !editing { pathDraft = runtime.currentPath }
        }
        .alert(creationKind?.title ?? "新建远程项目", isPresented: Binding(
            get: { creationKind != nil },
            set: { if !$0 { creationKind = nil } }
        )) {
            TextField(creationKind?.placeholder ?? "名称", text: $newItemName)
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
            Text("将在 \(creationDestination?.path ?? "") 中创建。")
        }
        .alert(runtime.pendingHostKey?.title ?? "确认主机密钥", isPresented: Binding(
            get: { runtime.pendingHostKey != nil },
            set: { if !$0, runtime.pendingHostKey != nil { runtime.rejectPendingHostKey() } }
        )) {
            Button("取消", role: .cancel) { runtime.rejectPendingHostKey() }
            Button(runtime.pendingHostKey?.acceptTitle ?? "信任并连接") { runtime.acceptPendingHostKey() }
        } message: {
            if let key = runtime.pendingHostKey {
                Text(key.message)
            }
        }
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
                    Text("\(conflict.remotePath) 已存在。安全覆盖会先完成隐藏暂存文件，再通过 mv 替换原文件；传输中断不会损坏现有文件。")
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

    private enum RemoteItemCreationKind {
        case file
        case directory

        var title: String { self == .directory ? "新建远程文件夹" : "新建远程文件" }
        var placeholder: String { self == .directory ? "文件夹名称" : "文件名称" }
    }

private struct SFTPFileTable: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: SFTPRuntime
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
                        ForEach(runtime.entries) { file in
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
                                Text(file.isSymbolicLink ? "链接" : (file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))
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
                                Text(file.isSymbolicLink ? "链接" : (file.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)))
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
                                runtime.fileSelection.click(file.id, order: runtime.entries.map(\.id))
                                onOpen(file)
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                    focusFileList()
                                    let flags = NSEvent.modifierFlags
                                    runtime.fileSelection.click(file.id, order: runtime.entries.map(\.id), command: flags.contains(.command), shift: flags.contains(.shift))
                            })
                            .onDrag { remoteFileProvider(for: file) }
                            .contextMenu {
                                Button(file.isDirectory ? "打开文件夹" : "打开", systemImage: file.isDirectory ? "folder" : "arrow.up.forward.app") {
                                    onOpen(file)
                                }
                                Divider()
                                if file.isDirectory {
                                    creationAndUploadMenu
                                    Divider()
                                }
                                Button("重命名…", systemImage: "pencil") {
                                    renamingFile = file
                                    renameText = file.name
                                }
                                Button("修改权限…", systemImage: "lock.shield") {
                                    permissionsFile = file
                                }
                                Divider()
                                Button("删除…", systemImage: "trash", role: .destructive) {
                                    focusFileList()
                                    runtime.fileSelection.contextClick(file.id, order: runtime.entries.map(\.id))
                                    requestDeletion()
                                }
                                .disabled(runtime.isDeleting || runtime.loadingPath != nil)
                            }
                            Divider().opacity(0.38)
                        }
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: max(1, geometry.size.height - CGFloat(runtime.entries.count * 32)))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                focusFileList()
                                runtime.fileSelection = SFTPSelection()
                            }
                            .contextMenu { emptyAreaContextMenu }
                    }
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
                                Text("复制到 \(runtime.profile.name)：\(runtime.currentPath)")
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
                let itemCount = runtime.entries.count
                let total = runtime.entries.reduce(Int64(0)) { $0 + $1.size }
                ViewThatFits(in: .horizontal) {
                    Text("\(itemCount) 个项目 · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    Text("\(itemCount) 个项目")
                }
                    .font(.system(size: 11))
                    .foregroundStyle(SnakeStyle.muted)
            }
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .background(SnakeStyle.canvas)
        .onDrop(
            of: [UTType.snakeRemoteFile.identifier, UTType.fileURL.identifier],
            delegate: SFTPFileDropDelegate(
                isTargeted: $receivesRemoteFile,
                receivesFinderFiles: $receivesFinderFiles,
                finderTarget: { runtime.finderUploadTarget },
                upload: { providers, path in runtime.uploadFromFinder(providers: providers, to: path, store: store) },
                perform: loadRemoteFilePayloads
            )
        )
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
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in
            guard filesFocused, deletingFiles.isEmpty, renamingFile == nil, permissionsFile == nil else { return .ignored }
            requestDeletion()
            return .handled
        }
        .alert("删除 \(deletingFiles.count) 个远程项目？", isPresented: Binding(
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

    private func fileIcon(_ file: RemoteFile) -> String {
        if file.isSymbolicLink { return "link" }
        return file.isDirectory ? "folder" : "doc"
    }

    private func deleteConfirmationMessage(for files: [RemoteFile]) -> String {
        let names = files.prefix(8).map(\.name).joined(separator: "\n")
        let more = files.count > 8 ? "\n…另有 \(files.count - 8) 项" : ""
        return names + more + "\n\n永久删除选中项目；文件夹通过 rm -rf 删除全部内容，软链接只删除链接本身。不会移入废纸篓，无法撤销。"
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
        Divider()
        Button("刷新", systemImage: "arrow.clockwise") { runtime.refresh() }
            .disabled(runtime.connectionState == .connecting)
    }

    @ViewBuilder
    private var creationAndUploadMenu: some View {
        Button("新建文件…", systemImage: "doc.badge.plus") { onCreateFile() }
            .disabled(runtime.directoryActionDestination == nil)
        Button("新建文件夹…", systemImage: "folder.badge.plus") { onCreateDirectory() }
            .disabled(runtime.directoryActionDestination == nil)
        Divider()
        Button("上传文件…", systemImage: "square.and.arrow.up") { onUploadFiles() }
            .disabled(runtime.directoryActionDestination == nil)
        Button("上传文件夹…", systemImage: "folder.badge.plus") { onUploadDirectory() }
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
            showNavigationNotice("已经位于顶级目录")
            return
        }
        let parent = (runtime.currentPath as NSString).deletingLastPathComponent
        runtime.refresh(path: parent.isEmpty ? "/" : parent)
    }

    private func goBack() {
        isEditingPath = false
        guard runtime.canGoBack else {
            showNavigationNotice("没有可回退的目录")
            return
        }
        runtime.goBack()
    }

    private func goForward() {
        isEditingPath = false
        guard runtime.canGoForward else {
            showNavigationNotice("没有可前进的目录")
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
        runtime.open(file)
    }

    private func chooseFiles(allowsDirectories: Bool) {
        guard let destination = runtime.directoryActionDestination else { return }
        let panel = NSOpenPanel()
        panel.message = "上传到远程目录：\(destination.path)"
        panel.canChooseFiles = !allowsDirectories
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "上传"
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
                .accessibilityLabel("查看当前\(contextName)上传记录")
                .help("查看当前\(contextName)上传记录 · \(uploader.activity.summary)")
            }
        }
        .sheet(isPresented: $showsHistory) {
            UploadHistoryView(uploader: uploader, contextDescription: "当前\(contextName)标签的文件上传记录")
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
        switch uploader.activity.result {
        case .failed: return .red
        case .cancelled, .skipped: return SnakeStyle.muted
        default: return SnakeStyle.secure
        }
    }
    private var icon: String {
        if isBusy { return activeRecord?.state == .paused ? "pause.circle.fill" : "arrow.up.circle.fill" }
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
                if let progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                        .tint(color).frame(width: 72)
                        .animation(reduceMotion ? nil : .linear(duration: 0.15), value: progress)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(width: 32, alignment: .trailing)
                } else if isBusy {
                    Text(uploader.pendingConflict == nil ? "准备上传…" : "等待确认")
                        .font(.system(size: 11))
                }
                if success && showsLabel { Text("已完成").font(.system(size: 11, weight: .medium)) }
                else if showsLabel && !isBusy { Text("上传记录").font(.system(size: 11)) }
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
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(SnakeStyle.action)
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传记录")
                        .font(.system(size: 18, weight: .semibold))
                    Text(contextDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(SnakeStyle.muted)
                    Text(uploader.activity.summary)
                        .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            Divider()

            if uploader.records.isEmpty {
                ContentUnavailableView(
                    uploader.isPreparing ? "正在准备上传" : "没有文件级记录",
                    systemImage: "arrow.up.doc",
                    description: Text(uploader.errorMessage ?? (uploader.isPreparing ? "正在扫描文件或等待上传确认。" : "空文件夹和跳过的项目不会生成文件记录；本次结果见上方摘要。"))
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
                    Text(record.fileName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(record.remotePath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SnakeStyle.muted)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
            Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                .frame(width: 82, alignment: .leading)
            Text(record.startedAt, format: .dateTime.month().day().hour().minute().second())
                .frame(width: 126, alignment: .leading)
            Text(durationText)
                .frame(width: 70, alignment: .leading)
            Text(record.state.label)
                .foregroundStyle(stateColor)
                .frame(width: 72, alignment: .leading)
            controls.frame(width: 62, alignment: .trailing)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 16)
        .frame(height: 48)
        .help(store.transferJob(id: record.jobID)?.errorMessage ?? record.remotePath)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 4) {
            switch record.state {
            case .running:
                controlButton("pause.fill", "暂停") { uploader.pause(jobID: record.jobID, store: store) }
                controlButton("xmark", "取消") { uploader.cancel(jobID: record.jobID, store: store) }
            case .paused:
                controlButton("play.fill", "继续") { uploader.resume(jobID: record.jobID, store: store) }
                controlButton("xmark", "取消") { uploader.cancel(jobID: record.jobID, store: store) }
            case .queued, .scanning:
                controlButton("xmark", "取消") { uploader.cancel(jobID: record.jobID, store: store) }
            case .failed, .interrupted:
                controlButton("arrow.clockwise", "重试") { uploader.retry(jobID: record.jobID, store: store) }
            case .succeeded, .cancelled:
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
        if seconds < 60 { return "\(seconds) 秒" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var stateIcon: String {
        switch record.state {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled, .interrupted: "xmark.circle.fill"
        case .paused: "pause.circle.fill"
        default: "arrow.up.circle.fill"
        }
    }

    private var stateColor: Color {
        switch record.state {
        case .succeeded: SnakeStyle.secure
        case .failed: .red
        case .paused: .orange
        case .cancelled, .interrupted: SnakeStyle.muted
        default: SnakeStyle.action
        }
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
                permissionRow("用户", read: .ownerRead, write: .ownerWrite, execute: .ownerExecute)
                Divider()
                permissionRow("用户组", read: .groupRead, write: .groupWrite, execute: .groupExecute)
                Divider()
                permissionRow("其他", read: .otherRead, write: .otherWrite, execute: .otherExecute)
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
        if file.isSymbolicLink { return "权限会应用到软连接指向的目标。" }
        if appliesRecursively { return "权限会递归应用，耗时取决于目录内容数量。" }
        return "权限只会应用到当前远程项目。"
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
        case .ownerRead: "用户可读"
        case .ownerWrite: "用户可写"
        case .ownerExecute: "用户可执行"
        case .groupRead: "用户组可读"
        case .groupWrite: "用户组可写"
        case .groupExecute: "用户组可执行"
        case .otherRead: "其他用户可读"
        case .otherWrite: "其他用户可写"
        case .otherExecute: "其他用户可执行"
        }
    }
}

private struct MountWorkspaceView: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var runtime: WorkspaceTabRuntime
    let onNewMapping: () -> Void
    let onEditMapping: (MountMapping) -> Void
    @State private var dependencyStatus = MountDependencyStatus.detect()

    private var selectedMapping: MountMapping? {
        store.mountMappings.first { $0.id == runtime.selectedMappingID } ?? store.mountMappings.first
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack { heading; Spacer(minLength: 12); actions }
                        VStack(alignment: .leading, spacing: 12) { heading; actions }
                    }
                    .padding(geometry.size.width < 500 ? 16 : 24)
                    Divider()
                    dependencyBanner
                    if store.mountMappings.isEmpty {
                        Text("暂无磁盘映射，点击“新增映射”配置远程目录。")
                            .font(.system(size: 13)).foregroundStyle(SnakeStyle.muted).padding(24)
                    } else {
                        ScrollView(.horizontal) {
                            VStack(spacing: 0) {
                                mappingTable
                                if let mapping = selectedMapping {
                                    MappingDetailCard(mapping: mapping, onEdit: { onEditMapping(mapping) })
                                        .padding(.horizontal, 24).padding(.top, 14)
                                }
                            }
                            .frame(width: max(1100, geometry.size.width))
                            .padding(.bottom, 24)
                        }
                    }
                }
            }
        }
        .background(SnakeStyle.canvas)
        .alert("磁盘映射操作未完成", isPresented: Binding(
            get: { store.mountActionError != nil },
            set: { if !$0 { store.mountActionError = nil } }
        )) {
            Button("确定") { store.mountActionError = nil }
        } message: { Text(store.mountActionError ?? "") }
    }

    private var dependencyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: dependencyStatus.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 21))
                .foregroundStyle(dependencyStatus.isReady ? SnakeStyle.secure : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(dependencyStatus.isReady ? "挂载环境已就绪" : "挂载环境需要配置")
                    .font(.system(size: 13, weight: .semibold))
                Text(dependencyStatus.isReady ? "macFUSE 与 SSHFS 可用" : "请安装 macFUSE 与 SSHFS 后重新检测")
                    .font(.system(size: 12))
                    .foregroundStyle(SnakeStyle.muted)
            }
            Spacer()

        }
        .padding(.horizontal, 18)
        .frame(minHeight: 67)
        .background((dependencyStatus.isReady ? SnakeStyle.secure : .orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var mappingTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("状态").frame(width: 92, alignment: .leading)
                Text("名称与连接").frame(width: 195, alignment: .leading)
                Text("远程目录").frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                Text("本地目录").frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                Text("自动挂载").frame(width: 74, alignment: .leading)
                Color.clear.frame(width: 110)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SnakeStyle.muted)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Color.primary.opacity(0.04))

            ForEach(store.mountMappings) { mapping in
                MappingTableRow(
                    mapping: mapping,
                    isSelected: selectedMapping?.id == mapping.id,
                    action: { runtime.selectedMappingID = mapping.id }
                )
                Divider().opacity(0.6)
            }
        }
        .background(SnakeStyle.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
        .padding(.horizontal, 24)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("磁盘映射").font(.system(size: 22, weight: .bold))
            Text("让远程目录像本地磁盘一样出现在 Finder 中。")
                .font(.system(size: 13)).foregroundStyle(SnakeStyle.muted)
        }
    }
    private var actions: some View {
        HStack {
            Button("刷新状态", systemImage: "arrow.clockwise") {
                dependencyStatus = .detect()
                store.refreshMountStates()
            }.buttonStyle(SnakeOutlineButtonStyle())
            Button("新增映射", systemImage: "plus", action: onNewMapping)
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct MappingTableRow: View {
    @EnvironmentObject private var store: ApplicationStore
    let mapping: MountMapping
    let isSelected: Bool
    let action: () -> Void
    @State private var confirmingDeletion = false
    @State private var checkingDeletion = false
    @State private var deletionRequiresUnmount = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(stateColor).frame(width: 8, height: 8)
                Text(mapping.state.label).font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(mapping.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail).help(mapping.name)
                Text(profileName).font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                    .lineLimit(1).truncationMode(.tail).help(profileName)
            }
            .frame(width: 195, alignment: .leading)
            Text(mapping.remotePath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                .help(mapping.remotePath)
            Text(mapping.userAccessPath)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                .help(mapping.userAccessPath)
            Toggle("", isOn: Binding(get: { mapping.autoMount }, set: { store.setAutoMount($0, for: mapping.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .frame(width: 74, alignment: .leading)
            HStack(spacing: 6) {
            Button(mapping.state == .mounted || mapping.state == .external ? "打开" : "挂载") {
                if mapping.state == .mounted || mapping.state == .external {
                    store.reveal(mappingID: mapping.id)
                } else {
                    store.mount(mappingID: mapping.id)
                }
            }
                .buttonStyle(SnakeOutlineButtonStyle())
                .frame(width: 70)
                .disabled(mapping.state == .mounting)
            Button { requestDeletion() } label: { Image(systemName: "trash") }
                .buttonStyle(SnakeIconButtonStyle())
                .help("删除映射").accessibilityLabel("删除映射")
                .disabled(checkingDeletion)
            }
            .frame(width: 110)
        }
        .padding(.horizontal, 16)
        .frame(height: 66)
        .background(isSelected ? SnakeStyle.selectedRow.opacity(0.75) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .contextMenu {
            Button("删除映射…", role: .destructive) { requestDeletion() }
                .disabled(checkingDeletion)
        }
        .alert(deletionRequiresUnmount ? "“\(mapping.name)”仍处于挂载状态" : "是否删除“\(mapping.name)”？", isPresented: $confirmingDeletion) {
            Button("取消", role: .cancel) {}
            Button(deletionRequiresUnmount ? "安全卸载并删除" : "删除映射", role: .destructive) {
                store.deleteMapping(mappingID: mapping.id)
            }
        } message: {
            if deletionRequiresUnmount {
                Text("此目录正在使用挂载连接，删除前需要安全卸载。若目录被占用或卸载失败，会保留映射。"
                     + "\n\n远程目录：\(mapping.remotePath)\n本地目录：\(mapping.userAccessPath)\n\n远程文件和本地文件夹会保留。")
            }
        }
    }

    private func requestDeletion() {
        guard !checkingDeletion else { return }
        guard mapping.state != .mounting else {
            store.mountActionError = "“\(mapping.name)”正在执行挂载或卸载操作，请等待操作完成后再删除。"
            return
        }
        checkingDeletion = true
        Task { @MainActor in
            defer { checkingDeletion = false }
            do {
                let mounted = try await Task.detached(priority: .utility) { try MountOperations.checkedMountedPaths() }.value
                guard let current = store.mountMappings.first(where: { $0.id == mapping.id }) else { return }
                guard current.state != .mounting else {
                    store.mountActionError = "“\(current.name)”正在执行挂载或卸载操作，请稍后再删除。"
                    return
                }
                deletionRequiresUnmount = mounted.contains(current.managedMountPath)
                confirmingDeletion = true
            } catch {
                store.mountActionError = "无法确认目录的挂载状态，暂不能删除：\(error.localizedDescription)"
            }
        }
    }

    private var profileName: String {
        store.profiles.first(where: { $0.id == mapping.profileID })?.name ?? "未绑定 SSH 会话"
    }

    private var stateColor: Color {
        switch mapping.state {
        case .mounted, .external: SnakeStyle.secure
        case .failed, .unavailable: .red
        case .mounting: .orange
        case .idle: .secondary
        }
    }
}

private struct MappingDetailCard: View {
    @EnvironmentObject private var store: ApplicationStore
    let mapping: MountMapping
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(mapping.state == .mounted ? SnakeStyle.secure : .orange).frame(width: 8, height: 8)
                    Text(mapping.name).font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Button("编辑", action: onEdit).buttonStyle(SnakeOutlineButtonStyle())
                    .disabled(mapping.state == .mounting)
                Button("安全卸载") { store.unmount(mappingID: mapping.id) }
                    .buttonStyle(SnakeOutlineButtonStyle())
                    .disabled(mapping.state != .mounted && mapping.state != .external)
            }
            HStack(spacing: 18) {
                MappingRoute(label: "远程目录", value: "\(profileConnection):\(mapping.remotePath)")
                Image(systemName: "arrow.right").foregroundStyle(SnakeStyle.muted)
                MappingRoute(label: "实际挂载点", value: mapping.managedMountPath)
                Image(systemName: "arrow.right").foregroundStyle(SnakeStyle.muted)
                MappingRoute(label: "FINDER 入口 · 软链接", value: mapping.userAccessPath)
            }
            Text("Finder 磁盘名称：\(MountOperations.volumeName(mappingName: mapping.name, connectionName: store.profiles.first(where: { $0.id == mapping.profileID })?.name ?? "未绑定"))")
                .font(.system(size: 12)).foregroundStyle(SnakeStyle.muted)
            if let error = mapping.lastError, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(16)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
    }

    private var profileConnection: String {
        store.profiles.first(where: { $0.id == mapping.profileID })?.connectionLabel ?? "未绑定"
    }
}

private struct MappingRoute: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    @StateObject private var credential = CredentialRevealController()
    @State private var tags: String
    @State private var symbolName: String
    @State private var customIconData: Data?
    @State private var cropSource: ProfileIconCropSource?
    @State private var privateKeyBookmark: Data?
    @State private var errorMessage: String?
    @StateObject private var connectionTest = SessionConnectionTestController()

    init(profile: SSHProfile?) {
        originalProfile = profile
        profileID = profile?.id ?? UUID()
        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.host ?? "")
        _port = State(initialValue: String(profile?.port ?? 22))
        _username = State(initialValue: profile?.username ?? "")
        _authMethod = State(initialValue: profile?.authMethod ?? .password)
        _tags = State(initialValue: SessionTags.format(profile?.tags ?? []))
        _symbolName = State(initialValue: profile?.symbolName ?? "server.rack")
        _customIconData = State(initialValue: profile?.usesCustomIcon == true ? ProfileIconStore.data(for: profile?.id ?? UUID()) : nil)
        _privateKeyBookmark = State(initialValue: profile?.privateKeyBookmark)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(originalProfile == nil ? "新增会话" : "编辑会话")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(SnakeIconButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            .background(SnakeStyle.canvas)
            Divider()

            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    iconColumn
                        .padding(.vertical, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 188)

                Divider()

                ScrollView {
                    editorFields
                        .padding(.vertical, 16)
                        .padding(.trailing, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 20)
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Button(connectionTest.isTesting ? "正在测试…" : "测试连接") {
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
            .frame(height: 56)
            .background(SnakeStyle.canvas)
        }
        .frame(width: 840, height: 600)
        .onChange(of: authMethod) { _, _ in credential.reset() }
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

    private var iconColumn: some View {
        VStack(spacing: 12) {
            editorIconPreview
            Text("会话图标").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                ForEach(["server.rack", "terminal", "cylinder", "cloud"], id: \.self) { symbol in
                    Button {
                        symbolName = symbol
                        customIconData = nil
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
            Button { selectProfileImage() } label: {
                Label(customIconData == nil ? "选择照片…" : "重新选择照片…", systemImage: "photo.badge.plus")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(SnakeOutlineButtonStyle(emphasized: symbolName == SSHProfile.customIconSymbolName))
            .frame(maxWidth: .infinity)
            Text("选择后可裁剪为会话头像")
                .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
            SessionConnectionTestFeedback(state: connectionTest.state)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var editorFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                compactField(label: "会话名称", text: $name)
                compactField(label: "标签", text: $tags, placeholder: "空格分隔：生产 API")
            }
            HStack(alignment: .top, spacing: 12) {
                compactField(label: "IP 或主机名", text: $host, monospaced: true)
                compactField(label: "端口", text: $port, monospaced: true)
                    .frame(width: 100)
            }
            HStack(alignment: .top, spacing: 12) {
                compactField(label: "用户名", text: $username, monospaced: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("认证方式").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
                    Picker("认证方式", selection: $authMethod) {
                        ForEach(AuthMethod.allCases) { method in Text(method.label).tag(method) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(height: 32)
                }
                .frame(maxWidth: .infinity)
            }
            if authMethod == .privateKey {
                VStack(alignment: .leading, spacing: 6) {
                    Text("私钥文件").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
                    HStack(spacing: 8) {
                        Text(privateKeyBookmark == nil ? "选择本机私钥文件" : "已保存私钥访问授权")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SnakeStyle.muted)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("选择…") { selectPrivateKey() }.buttonStyle(SnakeOutlineButtonStyle())
                    }
                    .padding(.leading, 10)
                    .frame(height: 32)
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(SnakeStyle.hairline) }
                }
            }
            CredentialInputView(account: savedCredentialAccount, isPassphrase: authMethod == .privateKey, reveal: credential)
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield").foregroundStyle(SnakeStyle.secure)
                Text(authMethod == .password
                     ? "加密保存 · 查看需身份验证；隐藏后保留编辑草稿。"
                     : "私钥仅保存访问书签；口令加密保存，查看需身份验证。")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.24), lineWidth: 1) }
        } else {
            Image(systemName: symbolName.isEmpty || symbolName == SSHProfile.customIconSymbolName ? "server.rack" : symbolName)
                .font(.system(size: 33, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(SnakeStyle.action, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var savedCredentialAccount: String? {
        guard let originalProfile, originalProfile.authMethod == authMethod else { return nil }
        return originalProfile.keychainAccount
    }

    private func selectProfileImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "选择照片"
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
        panel.prompt = "选择私钥"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                Task { @MainActor in privateKeyBookmark = bookmark }
            } catch {
                Task { @MainActor in errorMessage = "无法保存私钥访问授权。" }
            }
        }
    }

    private func save() {
        guard let parsedPort = Int(port) else {
            errorMessage = "端口必须是 1 到 65535 之间的数字。"
            return
        }
        let profile = SSHProfile(
            id: profileID,
            groupID: nil,
            name: name,
            host: host,
            port: parsedPort,
            username: username,
            authMethod: authMethod,
            keychainAccount: originalProfile?.authMethod == authMethod ? originalProfile?.keychainAccount : nil,
            privateKeyBookmark: privateKeyBookmark,
            tags: SessionTags.parse(tags),
            symbolName: symbolName.isEmpty ? "server.rack" : symbolName,
            sortOrder: originalProfile?.sortOrder ?? store.profiles.count
        )
        do {
            if profile.usesCustomIcon {
                guard let customIconData else {
                    errorMessage = "请重新选择并裁剪头像照片。"
                    return
                }
                try ProfileIconStore.save(customIconData, for: profile.id)
            }
            try store.save(profile: profile, credential: credential.valueToSave)
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

private struct EditorField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 13))
        }
        .frame(maxWidth: .infinity)
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
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("磁盘映射").font(.system(size: 11, weight: .semibold)).foregroundStyle(SnakeStyle.muted)
                    Text(original == nil ? "新增映射" : "编辑映射").font(.system(size: 21, weight: .bold))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(SnakeIconButtonStyle())
            }
            .padding(.horizontal, 24)
            .frame(height: 78)
            Divider()

            VStack(alignment: .leading, spacing: 18) {
                Text("挂载设置").font(.system(size: 14, weight: .bold))
                HStack(spacing: 12) {
                    EditorField(label: "映射名称", text: $name, placeholder: "生产文件")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SSH 会话").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
                        Picker("SSH 会话", selection: $profileID) {
                            Text("选择一个 SSH 会话").tag(UUID?.none)
                            ForEach(store.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                        }
                        .labelsHidden()
                        .frame(height: 31)
                    }
                    .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("远程目录").font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
                    HStack {
                        Text(remotePath.isEmpty ? "选择 SSH 会话后浏览远程文件夹" : remotePath)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(remotePath.isEmpty ? SnakeStyle.muted : SnakeStyle.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("浏览目录…", systemImage: "folder") { browsingProfile = selectedProfile }
                            .buttonStyle(SnakeOutlineButtonStyle())
                            .disabled(selectedProfile == nil)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .bottom, spacing: 8) {
                        EditorField(label: "本地访问目录", text: $userAccessPath, placeholder: "选择 Finder 入口的位置", monospaced: true)
                        Button("选择位置…", systemImage: "folder") { chooseLocalPath() }
                            .buttonStyle(SnakeOutlineButtonStyle())
                    }
                    Text("选择存放位置及入口名称，挂载后即可在 Finder 中访问。")
                        .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                }
                Toggle(isOn: $autoMount) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("应用启动时自动挂载").font(.system(size: 13, weight: .medium))
                        Text("启动时只尝试一次；失败后在映射列表中提示。")
                            .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                    }
                }
                .toggleStyle(.switch)

                Divider()
                Text("访问路径").font(.system(size: 13, weight: .bold))
                HStack(spacing: 14) {
                    MappingRoute(label: "远程目录", value: "\(profileConnection):\(remotePath)")
                    Image(systemName: "arrow.right").foregroundStyle(SnakeStyle.muted)
                    MappingRoute(label: "实际挂载点", value: managedPath)
                    Image(systemName: "arrow.right").foregroundStyle(SnakeStyle.muted)
                    MappingRoute(label: "FINDER 入口 · 软链接", value: userAccessPath)
                }
                .padding(12)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let errorMessage { Text(errorMessage).font(.system(size: 12)).foregroundStyle(.red) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack {
                Button("取消") { dismiss() }.buttonStyle(SnakeOutlineButtonStyle())
                Spacer()
                Button("保存映射") { save() }.buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
            .padding(.horizontal, 24)
            .frame(height: 62)
            .background(SnakeStyle.canvas)
        }
        .frame(width: 740, height: 580)
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
        panel.title = "选择本地访问目录"
        panel.message = "选择 Finder 入口的存放位置和名称。请使用尚不存在的名称。"
        panel.prompt = "选择"
        panel.nameFieldLabel = "入口名称："
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if !userAccessPath.isEmpty {
            let url = URL(fileURLWithPath: (userAccessPath as NSString).expandingTildeInPath)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            let suggestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            panel.nameFieldStringValue = suggestedName.isEmpty ? "远程目录" : suggestedName.replacingOccurrences(of: "/", with: "-")
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // The panel selects a future symlink location; it does not create a file.
            if FileManager.default.fileExists(atPath: url.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                errorMessage = "该本地位置已被占用，请选择其他入口名称。"
                return
            }
            userAccessPath = url.path
            errorMessage = nil
        }
    }

    private var profileConnection: String {
        store.profiles.first(where: { $0.id == profileID })?.connectionLabel ?? "选择 SSH 会话"
    }

    private var managedPath: String {
        if let original, !ManagedMountPath.isStable(original.managedMountPath) {
            return original.managedMountPath
        }
        guard let profile = selectedProfile,
              let path = try? ManagedMountPath.make(profile: profile, local: userAccessPath, remote: remotePath) else {
            return "选择会话和目录后生成"
        }
        return path
    }

    private func save() {
        guard let profileID else {
            errorMessage = "请选择一个 SSH 会话。"
            return
        }
        guard !remotePath.isEmpty else {
            errorMessage = "请浏览并选择远程目录。"
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

private struct MountManagerView: View {
    @EnvironmentObject private var store: ApplicationStore
    @Environment(\.dismiss) private var dismiss
    @State private var dependencyStatus = MountDependencyStatus.detect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("磁盘映射").font(.title3.weight(.semibold))
                    Text("远程目录通过受管 SSHFS 挂载点映射到 Finder。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
            }
            .padding(20)

            List {
                Section("依赖") {
                    DependencyRow(name: "macFUSE", available: dependencyStatus.macFUSEAvailable)
                    DependencyRow(name: "sshfs", available: dependencyStatus.sshfsPath != nil)
                    if let path = dependencyStatus.sshfsPath {
                        Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Section("映射") {
                    ForEach(store.mountMappings) { mapping in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(mapping.name)
                                Spacer()
                                Text(mapping.state.label).foregroundStyle(.secondary)
                            }
                            Text("\(mapping.remotePath) → \(mapping.managedMountPath)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text("Finder：\(mapping.userAccessPath)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let error = mapping.lastError {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Button("重新检测") { dependencyStatus = .detect() }
                Spacer()
                if !dependencyStatus.isReady {
                    Link("查看安装说明", destination: URL(string: "https://osxfuse.github.io/")!)
                }
            }
            .padding(14)
            .background(.bar)
        }
        .frame(width: 680, height: 500)
    }
}

private struct DependencyRow: View {
    let name: String
    let available: Bool

    var body: some View {
        Label {
            HStack {
                Text(name)
                Spacer()
                Text(available ? "已检测到" : "未检测到")
                    .foregroundStyle(available ? Color.mint : .orange)
            }
        } icon: {
            Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(available ? Color.mint : .orange)
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

public struct SnakeSettingsView: View {
    @EnvironmentObject private var store: ApplicationStore

    public init() {}

    public var body: some View {
        TabView {
            Form {
                Section("应用外观") {
                    Picker("外观", selection: $store.isDarkAppearancePreferred) {
                        Text("浅色").tag(false)
                        Text("深色").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text("立即应用到所有窗口与终端，并记住本次选择；不会重新连接或清空终端内容。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }

            Form {
                Section("SFTP 传输") {
                    LabeledContent("并行传输阈值") {
                        HStack(spacing: 6) {
                            TextField("", value: $store.multipartThresholdMB, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 72)
                            Text("MB").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("并行连接数") {
                        Stepper(value: $store.multipartConcurrency, in: 1...8) {
                            Text("\(store.multipartConcurrency) 个")
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                    Text("超过阈值的文件会拆分并使用独立 SFTP 连接并行上传。未完成的隐藏分片会保留，再次上传同一版本文件时自动续传。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .tabItem { Label("传输", systemImage: "arrow.up.arrow.down") }

            ScrollView {
              Form {
                Section("终端配色") {
                    Picker("配色主题", selection: $store.terminalThemePreset) {
                        ForEach(TerminalThemePreset.allCases, id: \.self) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    Toggle("日志关键词高亮", isOn: $store.terminalLogHighlightEnabled)
                    Toggle("输出字段高亮", isOn: $store.terminalFieldHighlightEnabled)
                    Text("区分权限、时间、地址、路径、大小和状态；保留远端颜色，Vim、top 等备用屏幕不启用。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Toggle("自动启用 ls／ll 彩色输出", isOn: $store.terminalShellColorsEnabled)
                    Text("下次连接生效。仅临时配置当前 Shell，不修改服务器配置文件；保留复杂函数及 NO_COLOR。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Section("终端字体") {
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
                }
                terminalColorPreview
                Text("配色、高亮与字体立即应用到所有终端，不会重连或清空屏幕缓冲。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
              }
              .padding(20)
            }
            .tabItem { Label("终端", systemImage: "textformat") }
        }
        .frame(width: 580, height: 520)
        .preferredColorScheme(store.isDarkAppearancePreferred ? .dark : .light)
    }

    private var previewTheme: TerminalTheme {
        TerminalTheme(preset: store.terminalThemePreset, isDark: store.isDarkAppearancePreferred,
                      logHighlightEnabled: store.terminalLogHighlightEnabled,
                      fieldHighlightEnabled: store.terminalFieldHighlightEnabled)
    }

    private var terminalColorPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("user@snake ~ % ls")
            (Text("Documents/  ").foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[4])))
             + Text("logs/  ").foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[6])))
             + Text("start.sh").foregroundColor(Color(nsColor: TerminalTheme.nsColor(previewTheme.ansiHex[2]))))
            Text("普通输出 · 连接保持正常")
            previewLog("drwxr-xr-x  4.0K  2026-09-13 09:30")
            previewLog("running  192.0.2.10:22  /var/log  80%")
            previewLog("[ERROR] FATAL 连接超时")
            previewLog("WARN / WARNING 正在重试")
            previewLog("INFO 服务已启动")
            previewLog("DEBUG / TRACE 请求完成")
        }
        .font(.custom(store.terminalFontName, size: store.terminalFontSize))
        .foregroundStyle(Color(nsColor: TerminalTheme.nsColor(previewTheme.foregroundHex)))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
