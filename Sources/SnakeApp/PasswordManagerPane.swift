import AppKit
import SwiftUI

/// Credentials tab (beside MCP): reusable passwords and private keys that
/// sessions take their credentials from, filling the window like the MCP tab.
struct PasswordManagerPane: View {
    @EnvironmentObject private var store: ApplicationStore
    @State private var section: Section
    @State private var query = ""
    @State private var passwordEditor: PasswordEditorDraft?
    @State private var pendingPasswordDelete: SavedPassword?
    @State private var keySheet: KeySheet?
    @State private var keyRename: SSHKeyRecord?
    @State private var pendingKeyDelete: SSHKeyRecord?
    @State private var copiedKeyID: UUID?
    @State private var message: String?

    enum Section: Hashable { case passwords, keys }

    init(section: Section = .passwords) {
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) {
                    heading
                    Spacer(minLength: 16)
                    sectionPicker
                }
                VStack(alignment: .leading, spacing: 12) { heading; sectionPicker }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    toolbar
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch section {
                    case .passwords: passwordContent
                    case .keys: keyContent
                    }
                    footnote
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SnakeStyle.canvas)
        .onChange(of: section) { _, _ in
            query = ""
            message = nil
        }
        .sheet(item: $passwordEditor) { draft in
            PasswordEditorSheet(draft: draft) { passwordEditor = nil }
                .environmentObject(store)
        }
        .sheet(item: $keySheet) { sheet in
            Group {
                switch sheet {
                case .importKey: SSHKeyImportSheet { keySheet = nil }
                case .generateKey: SSHKeyGenerateSheet { keySheet = nil }
                }
            }
            .environmentObject(store)
        }
        .sheet(item: $keyRename) { key in
            SSHKeyRenameSheet(key: key) { keyRename = nil }
                .environmentObject(store)
        }
        .confirmationDialog(L10n.text("删除此密码条目？"), isPresented: Binding(
            get: { pendingPasswordDelete != nil }, set: { if !$0 { pendingPasswordDelete = nil } }
        ), presenting: pendingPasswordDelete) { item in
            Button("删除密码条目", role: .destructive) { perform { try store.deleteSavedPassword(item) } }
            Button("取消", role: .cancel) {}
        } message: { item in
            Text(L10n.format("将解除 %@ 个会话的关联，但保留会话各自的账号和密码。", store.linkedProfiles(for: item.id).count))
        }
        .confirmationDialog(L10n.text("删除此密钥？"), isPresented: Binding(
            get: { pendingKeyDelete != nil }, set: { if !$0 { pendingKeyDelete = nil } }
        ), presenting: pendingKeyDelete) { key in
            Button("删除密钥", role: .destructive) { perform { try store.deleteSSHKey(id: key.id) } }
            Button("取消", role: .cancel) {}
        } message: { key in
            Text(L10n.format("「%@」的私钥文件和口令会从 Snake 中删除，无法恢复。服务器上的公钥不受影响。", key.name))
        }
    }

    // MARK: - Header

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("密码管理").font(.system(size: 22, weight: .bold))
            Text("常用账号密码与私钥保存在本机，新建或编辑会话时可直接选用。")
                .font(.system(size: 13)).foregroundStyle(SnakeStyle.muted)
        }
    }

    private var sectionPicker: some View {
        Picker("", selection: $section) {
            Text(L10n.text("密码")).tag(Section.passwords)
            Text(L10n.text("密钥")).tag(Section.keys)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(SnakeStyle.muted)
                TextField(section == .passwords ? L10n.text("搜索名称、用户名或会话") : L10n.text("搜索名称、指纹或会话"),
                          text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 360)
            .frame(height: 32)
            .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(SnakeStyle.hairline, lineWidth: 1) }
            Spacer(minLength: 12)
            switch section {
            case .passwords:
                Button("新增密码", systemImage: "plus") { passwordEditor = PasswordEditorDraft() }
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            case .keys:
                Button("导入私钥…", systemImage: "square.and.arrow.down") { keySheet = .importKey }
                    .buttonStyle(SnakeOutlineButtonStyle())
                Button("生成密钥", systemImage: "plus") { keySheet = .generateKey }
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
        }
    }

    private var footnote: some View {
        Label(section == .passwords
              ? L10n.text("密码用钥匙串中的密钥加密保存；查看需要验证身份，验证后 30 秒内再次查看不用重复验证。会话保存的是自己的密码副本。")
              : L10n.text("私钥以仅你本人可读的文件保存在 Snake 的数据目录，口令加密保存。删除前需先让使用它的会话换用其他私钥。"),
              systemImage: "lock.shield")
            .font(.system(size: 11))
            .foregroundStyle(SnakeStyle.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Header and rows share it so the time column lines up.
    private static let actionsWidth: CGFloat = 132

    // MARK: - Passwords

    private var passwordRows: [SavedPassword] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = store.savedPasswords.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { item in
            item.name.localizedCaseInsensitiveContains(needle)
                || item.username.localizedCaseInsensitiveContains(needle)
                || store.linkedProfiles(for: item.id).contains { $0.name.localizedCaseInsensitiveContains(needle) }
        }
    }

    @ViewBuilder
    private var passwordContent: some View {
        if store.savedPasswords.isEmpty {
            emptyState(symbol: "key.horizontal", title: L10n.text("还没有保存常用账号"),
                       detail: L10n.text("保存一次账号和密码，之后新建会话时直接从这里填入。")) {
                Button("新增密码", systemImage: "plus") { passwordEditor = PasswordEditorDraft() }
                    .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
        } else {
            let rows = passwordRows
            table(header: [(L10n.text("名称"), 260), (L10n.text("用户名"), 180), (L10n.text("关联会话"), nil),
                           (L10n.text("创建 / 修改"), 140)],
                  isEmpty: rows.isEmpty, emptyText: L10n.text("没有匹配的密码条目。")) {
                ForEach(rows) { item in
                    passwordRow(item)
                    if item.id != rows.last?.id { Divider().opacity(0.6) }
                }
            }
        }
    }

    private func passwordRow(_ item: SavedPassword) -> some View {
        let linked = store.linkedProfiles(for: item.id)
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                RowIcon(symbol: "key.horizontal.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(linked.isEmpty ? L10n.text("未关联会话") : L10n.format("已关联 %@ 个会话", linked.count))
                        .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                }
            }
            .frame(width: 260, alignment: .leading)
            Text(item.username)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            sessionChips(linked)
            TimestampStack(created: item.createdAt, updated: item.updatedAt)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 8) {
                Button("编辑") { passwordEditor = PasswordEditorDraft(item) }
                    .buttonStyle(SnakeOutlineButtonStyle())
                Button("删除") { pendingPasswordDelete = item }
                    .buttonStyle(SnakeOutlineButtonStyle())
            }
            .fixedSize()
            .frame(width: Self.actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { passwordEditor = PasswordEditorDraft(item) }
        .snakeContextMenu {
            Button("编辑密码", systemImage: "pencil") { passwordEditor = PasswordEditorDraft(item) }
            Divider()
            Button("删除密码", systemImage: "trash", role: .destructive) { pendingPasswordDelete = item }
        }
    }

    // MARK: - Keys

    private var keyRows: [SSHKeyRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = store.sshKeys.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !needle.isEmpty else { return sorted }
        return sorted.filter { key in
            key.name.localizedCaseInsensitiveContains(needle)
                || key.fingerprint.localizedCaseInsensitiveContains(needle)
                || store.profiles(usingKey: key.id).contains { $0.name.localizedCaseInsensitiveContains(needle) }
        }
    }

    @ViewBuilder
    private var keyContent: some View {
        if store.sshKeys.isEmpty {
            emptyState(symbol: "key.viewfinder", title: L10n.text("还没有私钥"),
                       detail: L10n.text("导入已有的私钥文件，或在 Snake 里生成一把新的 Ed25519 密钥，新建会话时直接选用。")) {
                HStack(spacing: 8) {
                    Button("导入私钥…", systemImage: "square.and.arrow.down") { keySheet = .importKey }
                        .buttonStyle(SnakeOutlineButtonStyle())
                    Button("生成密钥", systemImage: "plus") { keySheet = .generateKey }
                        .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                }
            }
        } else {
            let rows = keyRows
            table(header: [(L10n.text("名称"), 240), (L10n.text("指纹"), 240), (L10n.text("使用的会话"), nil),
                           (L10n.text("创建 / 修改"), 140)],
                  isEmpty: rows.isEmpty, emptyText: L10n.text("没有匹配的密钥。")) {
                ForEach(rows) { key in
                    keyRow(key)
                    if key.id != rows.last?.id { Divider().opacity(0.6) }
                }
            }
        }
    }

    private func keyRow(_ key: SSHKeyRecord) -> some View {
        let users = store.profiles(usingKey: key.id)
        return HStack(spacing: 12) {
            HStack(spacing: 12) {
                RowIcon(symbol: "key.viewfinder")
                VStack(alignment: .leading, spacing: 3) {
                    Text(key.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([key.algorithmLabel, key.hasPassphrase ? L10n.text("有口令") : L10n.text("无口令")].joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(SnakeStyle.muted)
                }
            }
            .frame(width: 240, alignment: .leading)
            Text(key.fingerprint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SnakeStyle.muted)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
                .frame(width: 240, alignment: .leading)
                .help(key.fingerprint)
            sessionChips(users)
            TimestampStack(created: key.createdAt, updated: key.updatedAt)
                .frame(width: 140, alignment: .leading)
            HStack(spacing: 8) {
                Button(copiedKeyID == key.id ? L10n.text("已复制") : L10n.text("复制公钥")) { copyPublicKey(key) }
                    .buttonStyle(SnakeOutlineButtonStyle())
                    .help("复制 authorized_keys 用的公钥")
                Menu {
                    Button("重命名…", systemImage: "pencil") { keyRename = key }
                    Button("删除…", systemImage: "trash", role: .destructive) { pendingKeyDelete = key }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .fixedSize()
            .frame(width: Self.actionsWidth, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .snakeContextMenu {
            Button("复制公钥", systemImage: "doc.on.doc") { copyPublicKey(key) }
            Button("重命名", systemImage: "pencil") { keyRename = key }
            Divider()
            Button("删除密钥", systemImage: "trash", role: .destructive) { pendingKeyDelete = key }
        }
    }

    private func copyPublicKey(_ key: SSHKeyRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
        copiedKeyID = key.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedKeyID == key.id { copiedKeyID = nil }
        }
    }

    // MARK: - Shared pieces

    private func table<Rows: View>(header: [(String, CGFloat?)], isEmpty: Bool, emptyText: String,
                                   @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(header.enumerated()), id: \.offset) { _, column in
                    if let width = column.1 {
                        Text(column.0).frame(width: width, alignment: .leading)
                    } else {
                        Text(column.0).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("操作").frame(width: Self.actionsWidth, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(SnakeStyle.muted)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            Divider()
            if isEmpty {
                Text(emptyText)
                    .font(.system(size: 13)).foregroundStyle(SnakeStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            rows()
        }
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
    }

    /// Session names as small capsules; more than three collapse into "+N".
    private func sessionChips(_ profiles: [SSHProfile]) -> some View {
        HStack(spacing: 6) {
            if profiles.isEmpty {
                Text("—").foregroundStyle(SnakeStyle.muted)
            }
            ForEach(profiles.prefix(3)) { profile in
                Text(profile.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(SnakeStyle.action.opacity(0.10), in: Capsule())
                    .foregroundStyle(SnakeStyle.action)
            }
            if profiles.count > 3 {
                Text("+\(profiles.count - 3)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SnakeStyle.muted)
            }
        }
        .frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
        .help(profiles.map(\.name).joined(separator: "、"))
    }

    private func emptyState<Actions: View>(symbol: String, title: String, detail: String,
                                           @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(SnakeStyle.action)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(SnakeStyle.muted).multilineTextAlignment(.center)
            actions()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.10), lineWidth: 1) }
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

private enum KeySheet: Identifiable {
    case importKey, generateKey
    var id: Self { self }
}

private struct RowIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(SnakeStyle.action)
            .frame(width: 34, height: 34)
            .background(SnakeStyle.action.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Imports an existing private key file.
private struct SSHKeyImportSheet: View {
    @EnvironmentObject private var store: ApplicationStore
    let onClose: () -> Void
    @State private var file: URL?
    @State private var name = ""
    @State private var passphrase = ""
    @State private var message: String?

    var body: some View {
        SnakeEditorSheet(context: L10n.text("密钥管理"), title: L10n.text("导入私钥"), width: 560, height: 420, onClose: onClose) {
            EditorSection(L10n.text("私钥文件"), footnote: L10n.text("支持 OpenSSH、PEM 和 PuTTY 格式。Snake 保存一份副本，原文件之后移动或删除都不影响使用。")) {
                EditorValueBox(file?.path ?? L10n.text("尚未选择文件"), placeholder: file == nil) {
                    Button("选择…") { choose() }.buttonStyle(SnakeOutlineButtonStyle())
                }
                HStack(alignment: .top, spacing: 12) {
                    EditorField(label: L10n.text("名称"), text: $name, placeholder: L10n.text("例如：工作电脑"))
                    EditorRow(L10n.text("口令（私钥已加密时填写）")) {
                        SecureField("", text: $passphrase).textFieldStyle(.roundedBorder)
                    }
                }
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            EmptyView()
        } trailing: {
            Button("取消", action: onClose).buttonStyle(SnakeOutlineButtonStyle())
            Button("导入") { save() }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .disabled(file == nil)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        panel.prompt = L10n.text("选择私钥")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                file = url
                if name.isEmpty { name = url.lastPathComponent }
            }
        }
    }

    private func save() {
        guard let file else { return }
        do {
            try store.importSSHKey(from: file, name: name, passphrase: passphrase.isEmpty ? nil : passphrase)
            passphrase = ""
            onClose()
        } catch {
            message = error.localizedDescription
        }
    }
}

/// Generates an Ed25519 key, then shows its public key for the server.
private struct SSHKeyGenerateSheet: View {
    @EnvironmentObject private var store: ApplicationStore
    let onClose: () -> Void
    @State private var name = ""
    @State private var comment = "\(NSUserName())@snake"
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var created: SSHKeyRecord?
    @State private var copied = false
    @State private var message: String?

    var body: some View {
        SnakeEditorSheet(context: L10n.text("密钥管理"), title: created == nil ? L10n.text("生成密钥") : (created?.name ?? ""),
                         width: 580, height: created == nil ? 470 : 400, onClose: onClose) {
            if let created {
                EditorSection(L10n.text("公钥"), footnote: L10n.text("把这一行追加到服务器的 ~/.ssh/authorized_keys，之后会话选用这把密钥即可登录。")) {
                    Text(created.publicKey)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(SnakeStyle.raisedSurface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SnakeStyle.hairline, lineWidth: 1) }
                    Text(created.fingerprint).font(.system(size: 11, design: .monospaced)).foregroundStyle(SnakeStyle.muted)
                }
            } else {
                EditorSection(L10n.text("新密钥"), footnote: L10n.text("生成 Ed25519 密钥。注释会写进公钥末尾，便于在服务器上认出这把钥匙。")) {
                    HStack(alignment: .top, spacing: 12) {
                        EditorField(label: L10n.text("名称"), text: $name, placeholder: L10n.text("例如：生产服务器"))
                        EditorField(label: L10n.text("注释"), text: $comment, monospaced: true)
                    }
                }
                EditorSection(L10n.text("口令（可选）"), footnote: L10n.text("设置后私钥文件本身也会加密；口令加密保存在 Snake，连接时自动使用。")) {
                    HStack(alignment: .top, spacing: 12) {
                        EditorRow(L10n.text("口令")) { SecureField("", text: $passphrase).textFieldStyle(.roundedBorder) }
                        EditorRow(L10n.text("再次输入")) { SecureField("", text: $confirmation).textFieldStyle(.roundedBorder) }
                    }
                }
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            EmptyView()
        } trailing: {
            if let created {
                Button(copied ? L10n.text("已复制") : L10n.text("复制公钥")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(created.publicKey, forType: .string)
                    copied = true
                }
                .buttonStyle(SnakeOutlineButtonStyle())
                Button("完成", action: onClose).buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            } else {
                Button("取消", action: onClose).buttonStyle(SnakeOutlineButtonStyle())
                Button("生成") { generate() }.buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
            }
        }
    }

    private func generate() {
        guard passphrase == confirmation else {
            message = L10n.text("两次输入的口令不一致。")
            return
        }
        do {
            created = try store.generateSSHKey(name: name, comment: comment, passphrase: passphrase.isEmpty ? nil : passphrase)
            passphrase = ""
            confirmation = ""
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

private struct SSHKeyRenameSheet: View {
    @EnvironmentObject private var store: ApplicationStore
    let key: SSHKeyRecord
    let onClose: () -> Void
    @State private var name: String
    @State private var message: String?

    init(key: SSHKeyRecord, onClose: @escaping () -> Void) {
        self.key = key
        self.onClose = onClose
        _name = State(initialValue: key.name)
    }

    var body: some View {
        SnakeEditorSheet(context: L10n.text("密钥管理"), title: L10n.text("重命名密钥"), width: 480, height: 260, onClose: onClose) {
            EditorField(label: L10n.text("名称"), text: $name)
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
            }
        } leading: {
            EmptyView()
        } trailing: {
            Button("取消", action: onClose).buttonStyle(SnakeOutlineButtonStyle())
            Button("保存") {
                do {
                    try store.renameSSHKey(id: key.id, to: name)
                    onClose()
                } catch {
                    message = error.localizedDescription
                }
            }
            .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
        }
    }
}

/// `record == nil` adds a new entry.
struct PasswordEditorDraft: Identifiable {
    let id = UUID()
    let record: SavedPassword?

    init(_ record: SavedPassword? = nil) {
        self.record = record
    }
}

/// Add or edit one saved password. Linked sessions are listed in the sheet itself:
/// ticking one copies this edit's new username or password into that session.
struct PasswordEditorSheet: View {
    @EnvironmentObject private var store: ApplicationStore
    let draft: PasswordEditorDraft
    let onClose: () -> Void
    @StateObject private var credential = CredentialRevealController.sharingGrace()
    @State private var name: String
    @State private var username: String
    @State private var syncedProfileIDs: Set<UUID> = []
    @State private var message: String?

    init(draft: PasswordEditorDraft, onClose: @escaping () -> Void) {
        self.draft = draft
        self.onClose = onClose
        _name = State(initialValue: draft.record?.name ?? "")
        _username = State(initialValue: draft.record?.username ?? "")
    }

    private var linked: [SSHProfile] {
        draft.record.map { store.linkedProfiles(for: $0.id) } ?? []
    }

    var body: some View {
        SnakeEditorSheet(
            context: L10n.text("密码管理"),
            title: draft.record == nil ? L10n.text("新增密码") : (draft.record?.name ?? ""),
            width: 560,
            // Sized to the form so short entries leave no empty band above the buttons.
            height: linked.isEmpty ? 376 : min(620, 400 + 28 * CGFloat(linked.count)),
            onClose: onClose
        ) {
            EditorSection(L10n.text("账号"), footnote: L10n.text("独立加密保存；查看已保存的密码需要验证身份。")) {
                HStack(alignment: .top, spacing: 12) {
                    EditorField(label: L10n.text("名称"), text: $name, placeholder: L10n.text("例如：生产环境 root"))
                    EditorField(label: L10n.text("用户名"), text: $username, monospaced: true)
                }
                CredentialInputView(account: draft.record?.credentialAccount, isPassphrase: false, reveal: credential)
            }
            if !linked.isEmpty {
                EditorSection(
                    L10n.format("关联会话（%@）", linked.count),
                    footnote: L10n.text("只在修改了用户名或密码时同步，且只同步勾选的会话；未勾选的会话保持原凭据和关联。")
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(linked) { profile in
                            Toggle(isOn: Binding(
                                get: { syncedProfileIDs.contains(profile.id) },
                                set: { if $0 { syncedProfileIDs.insert(profile.id) } else { syncedProfileIDs.remove(profile.id) } }
                            )) {
                                HStack(spacing: 8) {
                                    Text(profile.name).font(.system(size: 12, weight: .medium))
                                    Text(profile.connectionLabel)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(SnakeStyle.muted)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } leading: {
            TimestampStack(created: draft.record?.createdAt, updated: draft.record?.updatedAt)
        } trailing: {
            Button("取消", action: onClose).buttonStyle(SnakeOutlineButtonStyle())
            Button(draft.record == nil ? L10n.text("保存密码") : L10n.text("保存修改")) { save() }
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
        }
        .onDisappear { credential.reset() }
    }

    private func save() {
        let record = SavedPassword(
            id: draft.record?.id ?? UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let password = credential.valueToSave
        guard !record.name.isEmpty, !record.username.isEmpty, draft.record != nil || password != nil else {
            message = ApplicationStoreError.invalidSavedPassword.localizedDescription
            return
        }
        // Only a changed username or password has anything to copy into sessions.
        let changesCredential = draft.record?.username != record.username || password != nil
        let selected = changesCredential ? syncedProfileIDs : []
        do {
            let skipped = try store.saveSavedPassword(record, password: password, selectedProfileIDs: selected)
            if skipped.isEmpty {
                onClose()
            } else {
                message = L10n.text("已保存；部分会话状态变化，已跳过同步。")
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
