import AppKit
import SnakeCoreBindings
import SwiftUI

/// MCP workspace tab (beside 磁盘映射): the local server, its tokens and the
/// command audit, filling the window like terminal and SFTP tabs.
struct McpSettingsPane: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var mcp: McpController
    @State var section = Section.service

    enum Section: Hashable { case service, audit }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    heading
                    Spacer(minLength: 16)
                    sectionPicker
                }
                VStack(alignment: .leading, spacing: 12) { heading; sectionPicker }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider()
            switch section {
            case .service: McpServicePane(mcp: mcp)
            case .audit: McpAuditPane(mcp: mcp)
            }
        }
        .background(SnakeStyle.canvas)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("MCP 服务").font(.system(size: 22, weight: .bold))
            Text("让 AI 工具通过本机 MCP 服务，在指定的 SSH 会话上执行命令并留下审计记录。")
                .font(.system(size: 13)).foregroundStyle(SnakeStyle.muted)
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Text("服务与 Token").tag(Section.service)
            Text("命令审计").tag(Section.audit)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 260)
    }
}

// MARK: - Service and tokens

private struct McpServicePane: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var mcp: McpController
    @State private var editor: McpTokenDraft?
    @State private var shownSecret: McpShownSecret?
    @State private var pendingDelete: McpTokenInfo?
    @State private var revealingID: UUID?
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                serverCard
                tokenSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { mcp.reloadTokens() }
        .sheet(item: $editor) { draft in
            McpTokenEditorSheet(draft: draft, profiles: store.profiles) { result in
                save(result)
            } onCancel: { editor = nil }
        }
        .sheet(item: $shownSecret) { secret in
            McpTokenSecretSheet(secret: secret, snippet: mcp.configurationSnippet(token: secret.value)) {
                shownSecret = nil
            }
        }
        .confirmationDialog(L10n.text("删除此 Token？"), isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { token in
            Button("删除 Token", role: .destructive) { perform { try mcp.deleteToken(id: token.id) } }
            Button("取消", role: .cancel) {}
        } message: { token in
            Text(L10n.format("使用「%@」的 AI 工具将无法再连接。已有的审计记录会保留。", token.name))
        }
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 22))
                    .foregroundStyle(stateColor)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stateText).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        if case .failed = mcp.serverState {
                            Button("重试") { mcp.restartServer() }.controlSize(.small)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(mcp.endpoint)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(SnakeStyle.muted)
                            .textSelection(.enabled)
                        Button { copy(mcp.endpoint) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("复制")
                    }
                }
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    Text("端口").foregroundStyle(SnakeStyle.muted)
                    TextField("", value: $mcp.port, format: .number.grouping(.never))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        .accessibilityLabel(L10n.text("端口"))
                }
                Toggle("启用 MCP 服务", isOn: $mcp.isEnabled)
                    .toggleStyle(.switch)
            }
            Text("服务只监听本机 127.0.0.1，使用 Streamable HTTP（POST /mcp）。AI 工具通过 Authorization: Bearer <Token> 访问，只能在 Token 绑定的会话上执行命令。命令通过独立的 SSH exec 通道运行，不影响已打开的终端；主机密钥必须先在 Snake 中信任过。")
                .font(.system(size: 12))
                .foregroundStyle(SnakeStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(stateColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Token").font(.system(size: 15, weight: .semibold))
                    Text("Token 加密保存在本机，验证身份后可再次查看或复制。吊销后立即失效，可随时恢复；删除不可恢复，但审计记录会保留 Token 名称。")
                        .font(.system(size: 12))
                        .foregroundStyle(SnakeStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("新建 Token", systemImage: "plus") { editor = McpTokenDraft() }
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                    .disabled(store.profiles.isEmpty)
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
            }
            tokenTable
        }
    }

    private var tokenTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("名称").frame(width: 220, alignment: .leading)
                Text("可用会话").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Text("有效期").frame(width: 140, alignment: .leading)
                Text("最近使用").frame(width: 120, alignment: .leading)
                Text("操作").frame(width: 116, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SnakeStyle.muted)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            Divider()
            if mcp.tokens.isEmpty {
                Text(store.profiles.isEmpty ? L10n.text("请先新建 SSH 会话，再为它创建 Token。") : L10n.text("尚未创建 Token。"))
                    .font(.system(size: 13))
                    .foregroundStyle(SnakeStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            ForEach(mcp.tokens) { token in
                tokenRow(token)
                if token.id != mcp.tokens.last?.id { Divider().opacity(0.6) }
            }
        }
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
    }

    private func tokenRow(_ token: McpTokenInfo) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(token.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    McpStateBadge(state: token.state())
                }
                Text(token.prefix + "…").font(.system(size: 11, design: .monospaced)).foregroundStyle(SnakeStyle.muted)
            }
            .frame(width: 220, alignment: .leading)
            .help(L10n.format("创建于 %@", token.createdAt.formatted(date: .numeric, time: .shortened)))
            Text(boundSessions(token))
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                .help(boundSessions(token))
            Text(token.expiresAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? L10n.text("永不过期"))
                .font(.system(size: 12))
                .foregroundStyle(token.state() == .expired ? .orange : .primary)
                .frame(width: 140, alignment: .leading)
            Text(token.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? L10n.text("从未使用"))
                .font(.system(size: 12))
                .foregroundStyle(SnakeStyle.muted)
                .frame(width: 120, alignment: .leading)
            HStack(spacing: 10) {
                Button {
                    reveal(token)
                } label: {
                    if revealingID == token.id { ProgressView().controlSize(.small) }
                    else { Image(systemName: "eye") }
                }
                .help("验证身份后查看 Token 和配置")
                .disabled(revealingID != nil)
                Button { editor = McpTokenDraft(token) } label: { Image(systemName: "pencil") }
                    .help("编辑名称、绑定会话和有效期")
                Button {
                    perform { try mcp.setRevoked(token.revokedAt == nil, tokenID: token.id) }
                } label: {
                    Image(systemName: token.revokedAt == nil ? "nosign" : "arrow.uturn.backward")
                }
                .help(token.revokedAt == nil ? L10n.text("吊销") : L10n.text("恢复"))
                Button(role: .destructive) { pendingDelete = token } label: { Image(systemName: "trash") }
                    .help("删除")
            }
            .buttonStyle(.borderless)
            .frame(width: 116, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var stateSymbol: String {
        switch mcp.serverState {
        case .listening: "checkmark.circle.fill"
        case .starting: "clock.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "pause.circle.fill"
        }
    }

    private var stateText: String {
        switch mcp.serverState {
        case .stopped: L10n.text("已停止")
        case .starting: L10n.text("正在启动…")
        case .listening: L10n.text("运行中")
        case .failed(let reason): L10n.format("启动失败：%@", reason)
        }
    }

    private var stateColor: Color {
        switch mcp.serverState {
        case .listening: SnakeStyle.secure
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private func boundSessions(_ token: McpTokenInfo) -> String {
        let names = token.profileIDs.compactMap { id in store.profiles.first { $0.id == id }?.name }
        return names.isEmpty ? L10n.text("未绑定会话") : names.joined(separator: "、")
    }

    private func save(_ draft: McpTokenDraft) {
        let profiles = Array(draft.profileIDs)
        perform {
            if let id = draft.id {
                try mcp.updateToken(id: id, name: draft.name, profileIDs: profiles, expiresAt: draft.expiresAt)
            } else {
                let secret = try mcp.createToken(name: draft.name, profileIDs: profiles, expiresAt: draft.expiresAt)
                shownSecret = McpShownSecret(name: draft.name, value: secret, isNew: true)
            }
            editor = nil
        }
    }

    private func reveal(_ token: McpTokenInfo) {
        revealingID = token.id
        message = nil
        Task {
            defer { revealingID = nil }
            let authentication = DeviceOwnerCredentialAuthentication(reason: L10n.text("验证身份以查看 Snake 的 MCP Token"))
            defer { authentication.invalidate() }
            do {
                try await authentication.authenticate()
                let secret = try await mcp.storedSecret(for: token.id)
                shownSecret = McpShownSecret(name: token.name, value: secret, isNew: false)
            } catch CredentialAuthenticationError.cancelled {
            } catch CredentialAuthenticationError.unavailable {
                message = L10n.text("系统身份验证不可用，请检查 Mac 登录密码或 Touch ID 设置。")
            } catch CredentialAuthenticationError.failed {
                message = L10n.text("身份验证未通过，未显示 Token。")
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct McpStateBadge: View {
    let state: McpTokenInfo.State

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var title: String {
        switch state {
        case .active: L10n.text("有效")
        case .revoked: L10n.text("已吊销")
        case .expired: L10n.text("已过期")
        }
    }

    private var color: Color {
        switch state {
        case .active: SnakeStyle.secure
        case .revoked: .red
        case .expired: .orange
        }
    }
}

struct McpTokenDraft: Identifiable {
    enum Expiry: Hashable, CaseIterable { case never, days7, days30, days90, custom }

    let id: UUID?
    var name: String
    var profileIDs: Set<UUID>
    var expiry: Expiry
    var customDate: Date

    init() {
        id = nil
        name = ""
        profileIDs = []
        expiry = .never
        customDate = .now.addingTimeInterval(30 * 86_400)
    }

    init(_ token: McpTokenInfo) {
        id = token.id
        name = token.name
        profileIDs = Set(token.profileIDs)
        expiry = token.expiresAt == nil ? .never : .custom
        customDate = token.expiresAt ?? .now.addingTimeInterval(30 * 86_400)
    }

    var expiresAt: Date? {
        switch expiry {
        case .never: nil
        case .days7: .now.addingTimeInterval(7 * 86_400)
        case .days30: .now.addingTimeInterval(30 * 86_400)
        case .days90: .now.addingTimeInterval(90 * 86_400)
        case .custom: customDate
        }
    }
}

extension McpTokenDraft.Expiry {
    var title: String {
        switch self {
        case .never: L10n.text("永不过期")
        case .days7: L10n.text("7 天")
        case .days30: L10n.text("30 天")
        case .days90: L10n.text("90 天")
        case .custom: L10n.text("指定日期")
        }
    }
}

private struct McpTokenEditorSheet: View {
    @State var draft: McpTokenDraft
    let profiles: [SSHProfile]
    let onSave: (McpTokenDraft) -> Void
    let onCancel: () -> Void

    var body: some View {
        SnakeEditorSheet(
            context: L10n.text("MCP 服务"),
            title: draft.id == nil ? L10n.text("新建 Token") : L10n.text("编辑 Token"),
            onClose: onCancel
        ) {
            EditorSection(L10n.text("基本信息")) {
                HStack(alignment: .top, spacing: 12) {
                    EditorField(label: L10n.text("名称"), text: $draft.name, placeholder: L10n.text("例如 Claude Code"))
                    EditorRow(L10n.text("有效期")) {
                        Picker("有效期", selection: $draft.expiry) {
                            ForEach(McpTokenDraft.Expiry.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                if draft.expiry == .custom {
                    EditorRow(L10n.text("到期时间")) {
                        DatePicker("到期时间", selection: $draft.customDate, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
            }
            EditorSection(
                L10n.format("可用会话（已选 %@ 个）", draft.profileIDs.count),
                footnote: L10n.text("AI 工具只能在勾选的会话上执行命令。")
            ) {
                VStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        Toggle(isOn: Binding(get: { draft.profileIDs.contains(profile.id) }, set: { value in
                            if value { draft.profileIDs.insert(profile.id) } else { draft.profileIDs.remove(profile.id) }
                        })) {
                            HStack {
                                Text(profile.name).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(profile.connectionLabel).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(SnakeStyle.muted)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        if profile.id != profiles.last?.id { Divider().opacity(0.6) }
                    }
                }
                .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SnakeStyle.hairline, lineWidth: 1) }
            }
        } leading: {
            Button("取消", action: onCancel).buttonStyle(SnakeOutlineButtonStyle())
        } trailing: {
            Button(draft.id == nil ? L10n.text("创建") : L10n.text("保存")) { onSave(draft) }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.profileIDs.isEmpty)
        }
    }
}

struct McpShownSecret: Identifiable {
    let id = UUID()
    let name: String
    let value: String
    let isNew: Bool
}

private struct McpTokenSecretSheet: View {
    let secret: McpShownSecret
    let snippet: String
    let onClose: () -> Void

    var body: some View {
        SnakeEditorSheet(
            context: L10n.text("MCP 服务"),
            title: secret.isNew ? L10n.format("已创建「%@」", secret.name) : secret.name,
            onClose: onClose
        ) {
            EditorSection(L10n.text("Token")) {
                EditorValueBox(secret.value) {
                    Button("复制 Token") { copy(secret.value) }.controlSize(.small)
                }
            }
            EditorSection(
                L10n.text("Claude Code 配置（.mcp.json）"),
                footnote: L10n.text("配置文件包含 Token，请勿提交到 Git 仓库。窗口 60 秒后自动关闭。")
            ) {
                Text(snippet)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SnakeStyle.hairline, lineWidth: 1) }
            }
        } leading: {
            Button("复制配置") { copy(snippet) }.buttonStyle(SnakeOutlineButtonStyle())
        } trailing: {
            Button("完成", action: onClose)
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
        }
        .task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { onClose() }
        }
    }
}

// MARK: - Audit

private struct McpAuditPane: View {
    @EnvironmentObject private var store: ApplicationStore
    @ObservedObject var mcp: McpController
    @State private var tokenFilter = ""
    @State private var profileFilter = ""
    @State private var statusFilter = ""
    @State private var range = TimeRange.all
    @State private var records: [CoreMcpAuditRecord] = []
    @State private var total = 0
    @State private var pageSize = 200
    @State private var selection: Set<String> = []
    @State private var pendingDeletion: Deletion?
    @State private var message: String?

    enum TimeRange: Hashable, CaseIterable {
        case all, hour, day, week, month
        var title: String {
            switch self {
            case .all: L10n.text("全部时间")
            case .hour: L10n.text("最近 1 小时")
            case .day: L10n.text("最近 24 小时")
            case .week: L10n.text("最近 7 天")
            case .month: L10n.text("最近 30 天")
            }
        }
        var seconds: TimeInterval? {
            switch self {
            case .all: nil
            case .hour: 3_600
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    enum Deletion: Identifiable {
        case selected, filtered, all
        var id: Self { self }
    }

    static let statuses = ["succeeded", "failed", "timeout", "error", "denied", "running"]

    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            HStack(spacing: 0) {
                table
                Divider()
                detailPanel
                    .frame(width: 340)
                    .frame(maxHeight: .infinity)
                    .background(SnakeStyle.canvas)
            }
            Divider()
            retention
        }
        .onAppear(perform: reload)
        .onChange(of: mcp.auditRevision) { _, _ in reload() }
        .onChange(of: tokenFilter) { _, _ in resetAndReload() }
        .onChange(of: profileFilter) { _, _ in resetAndReload() }
        .onChange(of: statusFilter) { _, _ in resetAndReload() }
        .onChange(of: range) { _, _ in resetAndReload() }
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { deletion in
            Button("删除", role: .destructive) { delete(deletion) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除后无法恢复。正在执行的命令不会被删除。")
        }
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker("Token", selection: $tokenFilter) {
                Text("全部 Token").tag("")
                ForEach(mcp.tokens) { Text($0.name).tag($0.id.uuidString) }
            }
            .frame(maxWidth: 220)
            Picker("会话", selection: $profileFilter) {
                Text("全部会话").tag("")
                ForEach(store.profiles) { Text($0.name).tag($0.id.uuidString) }
            }
            .frame(maxWidth: 240)
            Picker("状态", selection: $statusFilter) {
                Text("全部状态").tag("")
                ForEach(Self.statuses, id: \.self) { Text(McpAuditStatus.title($0)).tag($0) }
            }
            .frame(maxWidth: 170)
            Picker("时间", selection: $range) {
                ForEach(TimeRange.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 190)
            Spacer(minLength: 12)
            Text(L10n.format("共 %@ 条", total)).foregroundStyle(SnakeStyle.muted)
            if records.count < total {
                Button("加载更多") { pageSize += 200; reload() }
            }
            Menu("删除…") {
                Button(L10n.format("删除所选（%@ 条）", selection.count)) { pendingDeletion = .selected }
                    .disabled(selection.isEmpty)
                Button("删除当前筛选结果") { pendingDeletion = .filtered }
                Divider()
                Button("清空全部审计记录") { pendingDeletion = .all }
            }
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var table: some View {
        Table(records, selection: $selection) {
            TableColumn("时间") { record in
                Text(McpController.date(record.startedAt).formatted(date: .numeric, time: .standard))
                    .font(.system(size: 11, design: .monospaced))
            }
            .width(min: 120, ideal: 140)
            TableColumn("状态") { record in McpAuditStatus(status: record.status) }
                .width(min: 50, ideal: 56)
            TableColumn("Token") { record in
                Text(record.tokenName.isEmpty ? L10n.text("无效 Token") : record.tokenName)
                    .font(.system(size: 12))
                    .foregroundStyle(record.tokenId == nil ? .red : .primary)
                    .lineLimit(1)
            }
            .width(min: 64, ideal: 100)
            TableColumn("会话") { record in
                Text(record.profileLabel).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(record.profileLabel)
            }
            .width(min: 80, ideal: 140)
            TableColumn("退出码") { record in
                Text(record.exitStatus.map(String.init) ?? "–").font(.system(size: 11, design: .monospaced))
            }
            .width(min: 40, ideal: 48)
            TableColumn("命令") { record in
                Text(record.command).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(record.command)
            }
            .width(min: 160)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let record = records.first(where: { $0.id == id }) {
                Button("复制命令") { copy(record.command) }
            }
        }
        .overlay {
            if records.isEmpty {
                Text("没有符合条件的审计记录").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if selection.count == 1, let id = selection.first, let record = records.first(where: { $0.id == id }) {
            McpAuditDetailView(record: record)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundStyle(SnakeStyle.muted)
                Text("选择一条记录查看详情").font(.system(size: 13)).foregroundStyle(SnakeStyle.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var retention: some View {
        HStack(spacing: 14) {
            Text("滚动删除").font(.system(size: 12, weight: .semibold))
            LabeledContent("保留天数") {
                TextField("", value: $mcp.retentionDays, format: .number.grouping(.never))
                    .labelsHidden().multilineTextAlignment(.trailing).frame(width: 56)
                    .accessibilityLabel(L10n.text("保留天数"))
            }
            LabeledContent("最多保留") {
                HStack(spacing: 4) {
                    TextField("", value: $mcp.maxRecords, format: .number.grouping(.never))
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
                        .accessibilityLabel(L10n.text("最多保留"))
                    Text("条").foregroundStyle(.secondary)
                }
            }
            Button("立即清理") { mcp.pruneAudit() }
            Text("超过保留天数或条数上限的最早记录会自动删除，0 表示不限制。启动时、每新增 100 条及每小时检查一次。")
                .font(.system(size: 11))
                .foregroundStyle(SnakeStyle.muted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2) }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var filter: CoreMcpAuditFilter {
        .matching(
            tokenID: tokenFilter.isEmpty ? nil : tokenFilter,
            profileID: profileFilter.isEmpty ? nil : profileFilter,
            status: statusFilter.isEmpty ? nil : statusFilter,
            since: range.seconds.map { McpController.milliseconds(.now.addingTimeInterval(-$0)) }
        )
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .selected: L10n.format("删除所选的 %@ 条记录？", selection.count)
        case .filtered: L10n.format("删除当前筛选的 %@ 条记录？", total)
        case .all, nil: L10n.text("清空全部审计记录？")
        }
    }

    private func resetAndReload() {
        pageSize = 200
        selection.removeAll()
        reload()
    }

    private func reload() {
        let filter = filter
        records = mcp.auditRecords(filter: filter, limit: pageSize)
        total = mcp.auditCount(filter: filter)
        selection.formIntersection(records.map(\.id))
    }

    private func delete(_ deletion: Deletion) {
        do {
            switch deletion {
            case .selected: try mcp.deleteAudit(filter: .matching(ids: Array(selection)))
            case .filtered: try mcp.deleteAudit(filter: filter)
            case .all: try mcp.deleteAudit(filter: .matching())
            }
            selection.removeAll()
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct McpAuditStatus: View {
    let status: String

    var body: some View {
        Text(Self.title(status))
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    static func title(_ status: String) -> String {
        switch status {
        case "succeeded": L10n.text("成功")
        case "failed": L10n.text("失败")
        case "timeout": L10n.text("超时")
        case "error": L10n.text("错误")
        case "denied": L10n.text("已拒绝")
        case "running": L10n.text("执行中")
        default: status
        }
    }

    private var color: Color {
        switch status {
        case "succeeded": SnakeStyle.secure
        case "running": SnakeStyle.action
        case "timeout", "failed": .orange
        default: .red
        }
    }
}

/// Inline detail beside the audit table.
private struct McpAuditDetailView: View {
    let record: CoreMcpAuditRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("命令详情").font(.system(size: 15, weight: .semibold))
                    McpAuditStatus(status: record.status)
                    Spacer()
                    Button("复制命令") { copy(record.command) }.controlSize(.small)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                    row(L10n.text("时间"), McpController.date(record.startedAt).formatted(date: .numeric, time: .standard))
                    row(L10n.text("Token"), record.tokenName.isEmpty ? L10n.text("无效 Token") : record.tokenName)
                    row(L10n.text("会话"), record.profileLabel)
                    if !record.clientName.isEmpty { row(L10n.text("客户端"), record.clientName) }
                    if let cwd = record.cwd { row(L10n.text("工作目录"), cwd) }
                    row(L10n.text("退出码"), record.exitStatus.map(String.init) ?? "–")
                    if let duration = record.durationMs { row(L10n.text("耗时"), L10n.format("%@ 毫秒", duration)) }
                    row(L10n.text("输出大小"), L10n.format("stdout %@ / stderr %@",
                        ByteCountFormatter.string(fromByteCount: record.stdoutBytes, countStyle: .file),
                        ByteCountFormatter.string(fromByteCount: record.stderrBytes, countStyle: .file)))
                    if let error = record.errorMessage { row(L10n.text("错误"), error) }
                }
                .font(.system(size: 12))
                block(L10n.text("命令"), record.command)
                if !record.stdoutExcerpt.isEmpty { block("stdout", record.stdoutExcerpt) }
                if !record.stderrExcerpt.isEmpty { block("stderr", record.stderrExcerpt) }
                Text("审计中每路输出最多保存 16 KB。").font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(SnakeStyle.muted)
            Text(value).textSelection(.enabled).lineLimit(3)
        }
    }

    private func block(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .padding(6)
            .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension CoreMcpAuditRecord: Identifiable {}
