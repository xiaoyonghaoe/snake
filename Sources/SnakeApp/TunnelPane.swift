import AppKit
import SwiftUI

enum MountWorkspaceSection: Hashable {
    case mappings
    case tunnels
}

struct TunnelEditorDraft: Identifiable {
    let id = UUID()
    var tunnel: SSHTunnel?
}

extension TunnelState {
    var indicatorColor: Color {
        switch self {
        case .running: SnakeStyle.secure
        case .starting: .orange
        case .disconnected, .failed: .red
        case .stopped: .secondary
        }
    }
}

/// The SSH tunnel half of the mapping workspace.
struct TunnelTable: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var tunnels: SSHTunnelController
    @ObservedObject var runtime: WorkspaceTabRuntime
    let onNew: () -> Void
    let onEdit: (SSHTunnel) -> Void

    static let stateWidth: CGFloat = 120
    static let sessionWidth: CGFloat = 200
    static let localWidth: CGFloat = 150
    static let autoStartWidth: CGFloat = 64
    /// Header and rows share it so every column lines up.
    static let actionsWidth: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("状态").frame(width: Self.stateWidth, alignment: .leading)
                Text("会话").frame(width: Self.sessionWidth, alignment: .leading)
                Text("本地端口").frame(width: Self.localWidth, alignment: .leading)
                Text("远端").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                Text("备注").frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                Text("随启动").frame(width: Self.autoStartWidth, alignment: .leading)
                Text("操作").frame(width: Self.actionsWidth, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SnakeStyle.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
            if tunnels.tunnels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(SnakeStyle.action)
                    Text("还没有 SSH 隧道").font(.system(size: 14, weight: .semibold))
                    Text("把服务器那边的端口映射到本机，例如把服务器上的 MySQL 3306 映射到本机 13306。")
                        .font(.system(size: 12))
                        .foregroundStyle(SnakeStyle.muted)
                        .multilineTextAlignment(.center)
                    Button("新增隧道", systemImage: "plus", action: onNew)
                        .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 36)
                .padding(.horizontal, 24)
            }
            ForEach(tunnels.tunnels) { tunnel in
                TunnelRow(
                    tunnels: tunnels,
                    tunnel: tunnel,
                    isSelected: runtime.selectedTunnelID == tunnel.id,
                    onSelect: { runtime.selectedTunnelID = tunnel.id },
                    onEdit: { onEdit(tunnel) }
                )
                if tunnel.id != tunnels.tunnels.last?.id { Divider().opacity(0.6) }
            }
        }
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
    }
}

private struct TunnelRow: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var tunnels: SSHTunnelController
    let tunnel: SSHTunnel
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    @State private var confirmingDeletion = false
    @State private var copied = false

    private var state: TunnelState { tunnels.state(of: tunnel.id) }
    private var profile: SSHProfile? { tunnel.profileID.flatMap { id in store.profiles.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Circle().fill(state.indicatorColor).frame(width: 8, height: 8)
                    Text(state.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .frame(width: TunnelTable.stateWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile?.name ?? L10n.text("未绑定 SSH 会话"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(profile == nil ? SnakeStyle.muted : SnakeStyle.ink)
                        .lineLimit(1)
                    if let profile {
                        Text(profile.connectionLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SnakeStyle.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(width: TunnelTable.sessionWidth, alignment: .leading)
                Button { copyLocalAddress() } label: {
                    HStack(spacing: 5) {
                        Text(tunnel.localAddress).font(.system(size: 12, design: .monospaced))
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                            .foregroundStyle(SnakeStyle.muted)
                    }
                }
                .buttonStyle(.plain)
                .help("复制本地地址")
                .frame(width: TunnelTable.localWidth, alignment: .leading)
                Text(tunnel.remoteAddress)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    .help(tunnel.remoteAddress)
                Text(tunnel.note.isEmpty ? "—" : tunnel.note)
                    .font(.system(size: 12))
                    .foregroundStyle(tunnel.note.isEmpty ? SnakeStyle.muted : SnakeStyle.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)
                    .help(tunnel.note)
                Toggle("", isOn: Binding(
                    get: { tunnel.autoStart },
                    set: { value in perform { try tunnels.setAutoStart(value, for: tunnel.id) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: TunnelTable.autoStartWidth, alignment: .leading)
                HStack(spacing: 8) {
                    primaryButton
                    Button("编辑", action: onEdit).buttonStyle(SnakeOutlineButtonStyle())
                    Menu {
                        Button("删除…", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .fixedSize()
                .frame(width: TunnelTable.actionsWidth, alignment: .trailing)
            }
            if let detail = state.detail {
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .padding(.leading, TunnelTable.stateWidth + 12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(isSelected ? SnakeStyle.selectedRow.opacity(0.75) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onEdit)
        .onTapGesture(perform: onSelect)
        .snakeContextMenu {
            switch state {
            case .running, .starting: Button("停止", systemImage: "stop.fill") { tunnels.stop(tunnel.id) }
            case .disconnected, .failed: Button("重连", systemImage: "arrow.clockwise") { tunnels.reconnect(tunnel.id) }
            case .stopped: Button("启动", systemImage: "play.fill") { tunnels.start(tunnel.id) }
            }
            Section("管理") {
                Button("编辑隧道", systemImage: "pencil", action: onEdit)
                Button("复制本地地址", systemImage: "doc.on.doc") { copyLocalAddress() }
            }
            Divider()
            Button("删除隧道", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
        }
        .confirmationDialog(L10n.format("删除隧道 %@？", tunnel.localAddress), isPresented: $confirmingDeletion) {
            Button("删除隧道", role: .destructive) { perform { try tunnels.delete(tunnel.id) } }
        } message: {
            Text("正在运行的隧道会先停止，本机端口随之关闭。")
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state {
        case .running, .starting:
            Button("停止") { tunnels.stop(tunnel.id) }
                .buttonStyle(SnakeOutlineButtonStyle())
                .frame(width: 58)
        case .disconnected, .failed:
            Button("重连") { tunnels.reconnect(tunnel.id) }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .frame(width: 58)
                .disabled(profile == nil)
        case .stopped:
            Button("启动") { tunnels.start(tunnel.id) }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .frame(width: 58)
                .disabled(profile == nil)
        }
    }

    private func copyLocalAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tunnel.localAddress, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.mountActionError = error.localizedDescription }
    }
}

struct TunnelEditorSheet: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var tunnels: SSHTunnelController
    let tunnel: SSHTunnel?
    let onClose: () -> Void
    @State private var profileID: UUID?
    @State private var localPort: String
    @State private var remoteHost: String
    @State private var remotePort: String
    @State private var note: String
    @State private var autoStart: Bool
    @State private var message: String?

    init(tunnels: SSHTunnelController, tunnel: SSHTunnel?, onClose: @escaping () -> Void) {
        self.tunnels = tunnels
        self.tunnel = tunnel
        self.onClose = onClose
        _profileID = State(initialValue: tunnel?.profileID)
        _localPort = State(initialValue: tunnel.map { String($0.localPort) } ?? "")
        _remoteHost = State(initialValue: tunnel?.remoteHost ?? "127.0.0.1")
        _remotePort = State(initialValue: tunnel.map { String($0.remotePort) } ?? "")
        _note = State(initialValue: tunnel?.note ?? "")
        _autoStart = State(initialValue: tunnel?.autoStart ?? false)
    }

    private var sortedProfiles: [SSHProfile] {
        store.profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SnakeEditorSheet(
            context: L10n.text("SSH 隧道"),
            title: tunnel == nil ? L10n.text("新增隧道") : L10n.text("编辑隧道"),
            width: 580,
            height: 520,
            onClose: onClose
        ) {
            EditorSection(L10n.text("会话"), footnote: L10n.text("隧道单独建立一条 SSH 连接；这台服务器的主机指纹需要先在终端里确认过。")) {
                EditorRow(L10n.text("SSH 会话")) {
                    Picker("", selection: $profileID) {
                        Text("请选择会话").tag(UUID?.none)
                        ForEach(sortedProfiles) { profile in
                            Text("\(profile.name)  ·  \(profile.connectionLabel)").tag(Optional(profile.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            EditorSection(
                L10n.text("转发"),
                footnote: L10n.text("本机只监听 127.0.0.1。远端主机按服务器的视角填写：转发到服务器自己填 127.0.0.1，也可以填服务器能访问的内网地址。")
            ) {
                HStack(alignment: .top, spacing: 12) {
                    EditorField(label: L10n.text("本地端口"), text: $localPort, placeholder: "13306", monospaced: true)
                        .frame(width: 120)
                    EditorField(label: L10n.text("远端主机"), text: $remoteHost, placeholder: "127.0.0.1", monospaced: true)
                    EditorField(label: L10n.text("远端端口"), text: $remotePort, placeholder: "3306", monospaced: true)
                        .frame(width: 120)
                }
            }
            EditorSection(L10n.text("其他")) {
                EditorField(label: L10n.text("备注"), text: $note, placeholder: L10n.text("例如：生产库 MySQL"))
                Toggle("随 Snake 启动", isOn: $autoStart)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            TimestampStack(created: tunnel?.createdAt, updated: tunnel?.updatedAt)
        } trailing: {
            Button("取消", action: onClose).buttonStyle(SnakeOutlineButtonStyle())
            Button(tunnel == nil ? L10n.text("保存隧道") : L10n.text("保存修改")) { save() }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
        }
    }

    private func save() {
        guard let local = Int(localPort.trimmingCharacters(in: .whitespaces)) else {
            message = SSHTunnelError.invalidLocalPort.localizedDescription
            return
        }
        guard let remote = Int(remotePort.trimmingCharacters(in: .whitespaces)) else {
            message = SSHTunnelError.invalidRemotePort.localizedDescription
            return
        }
        var draft = tunnel ?? SSHTunnel(localPort: local, remotePort: remote)
        draft.profileID = profileID
        draft.localPort = local
        draft.remoteHost = remoteHost
        draft.remotePort = remote
        draft.note = note
        draft.autoStart = autoStart
        do {
            try tunnels.save(draft)
            onClose()
        } catch {
            message = error.localizedDescription
        }
    }
}
