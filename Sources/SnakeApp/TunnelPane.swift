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

    var body: some View {
        ResourceListCard {
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

    private var subtitle: String {
        let session = profile.map { "\($0.name) · \($0.connectionLabel)" } ?? L10n.text("未绑定 SSH 会话")
        return tunnel.note.isEmpty ? session : "\(tunnel.note) · \(session)"
    }

    var body: some View {
        ResourceRow(
            symbol: "point.topleft.down.to.point.bottomright.curvepath",
            tint: state.indicatorColor == .secondary ? SnakeStyle.action : state.indicatorColor,
            subtitle: subtitle,
            status: state.label,
            statusColor: state.indicatorColor,
            automaticLabel: tunnel.autoStart ? L10n.text("自动连接") : nil,
            automaticHelp: L10n.text("启动 Snake 时自动连接这条隧道"),
            problem: state.detail,
            isSelected: isSelected
        ) {
            HStack(spacing: 8) {
                Text(tunnel.localAddress)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(SnakeStyle.muted)
                Text(tunnel.remoteAddress)
                Button { copyLocalAddress() } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10))
                        .foregroundStyle(SnakeStyle.muted)
                }
                .buttonStyle(.plain)
                .help("复制本地地址")
            }
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .lineLimit(1)
        } actions: {
            primaryButton
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(SnakeIconButtonStyle())
                .help("编辑隧道").accessibilityLabel("编辑隧道")
            Button { confirmingDeletion = true } label: { Image(systemName: "trash") }
                .buttonStyle(SnakeIconButtonStyle())
                .help("删除隧道").accessibilityLabel("删除隧道")
        }
        // A plain single tap would wait out the double-click interval before
        // firing; the simultaneous tap highlights the row on the first click.
        .onTapGesture(count: 2, perform: onEdit)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .snakeContextMenu {
            switch state {
            case .running, .starting: Button("断开", systemImage: "stop.circle") { tunnels.stop(tunnel.id) }
            case .disconnected, .failed: Button("重新连接", systemImage: "arrow.clockwise") { tunnels.reconnect(tunnel.id) }
            case .stopped: Button("连接", systemImage: "play.circle") { tunnels.start(tunnel.id) }
            }
            Section("管理") {
                Button("编辑隧道", systemImage: "pencil", action: onEdit)
                Button("复制本地地址", systemImage: "doc.on.doc") { copyLocalAddress() }
                Toggle(isOn: autoStartBinding) { Label("启动 Snake 时自动连接", systemImage: "bolt") }
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

    private var autoStartBinding: Binding<Bool> {
        Binding(get: { tunnel.autoStart }, set: { value in perform { try tunnels.setAutoStart(value, for: tunnel.id) } })
    }

    /// One button whose words say exactly what it does now.
    @ViewBuilder
    private var primaryButton: some View {
        switch state {
        case .running, .starting:
            Button("断开") { tunnels.stop(tunnel.id) }
                .buttonStyle(SnakeOutlineButtonStyle())
                .frame(width: 88)
        case .disconnected, .failed:
            Button("重新连接") { tunnels.reconnect(tunnel.id) }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .frame(width: 88)
                .disabled(profile == nil)
        case .stopped:
            Button("连接") { tunnels.start(tunnel.id) }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .frame(width: 88)
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
                Toggle("启动 Snake 时自动连接", isOn: $autoStart)
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
