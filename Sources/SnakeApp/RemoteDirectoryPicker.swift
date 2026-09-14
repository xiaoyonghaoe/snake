import SwiftUI

/// A read-only directory chooser with its own short-lived SFTP connection.
struct RemoteDirectoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runtime: SFTPRuntime
    @State private var openedInitialPath = false
    let initialPath: String
    let onSelect: (String) -> Void

    init(profile: SSHProfile, initialPath: String, onSelect: @escaping (String) -> Void) {
        _runtime = StateObject(wrappedValue: SFTPRuntime(profile: profile))
        self.initialPath = initialPath
        self.onSelect = onSelect
    }

    private var isReady: Bool {
        runtime.connectionState == .connected && runtime.loadingPath == nil
    }

    private var directories: [RemoteFile] {
        runtime.entries.filter { $0.isDirectory && $0.name != "." && $0.name != ".." }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("选择远程目录").font(.system(size: 21, weight: .bold))
                Text(runtime.profile.connectionLabel)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SnakeStyle.muted)
                Text("点击文件夹进入，打开目标目录后点击“选择此目录”。")
                    .font(.system(size: 12)).foregroundStyle(SnakeStyle.muted)
            }
            .padding(20)
            Divider()
            HStack(spacing: 8) {
                Button { runtime.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!isReady || !runtime.canGoBack)
                    .help("后退").accessibilityLabel("后退")
                Button {
                    runtime.navigate(to: (runtime.currentPath as NSString).deletingLastPathComponent)
                } label: { Image(systemName: "arrow.up") }
                    .disabled(!isReady || runtime.currentPath == "/")
                    .help("上一级").accessibilityLabel("上一级")
                Button("根目录") { runtime.navigate(to: "/") }
                    .disabled(!isReady || runtime.currentPath == "/")
                Text(runtime.currentPath)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(runtime.currentPath)
                Button { runtime.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!isReady)
                    .help("刷新").accessibilityLabel("刷新")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .background(SnakeStyle.chromeFrost)

            if let error = runtime.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.system(size: 12)).textSelection(.enabled)
                    Spacer()
                    Button("重试") { runtime.retryLastOperation() }
                }
                .padding(12)
            }

            Group {
                if runtime.connectionState == .connecting || runtime.loadingPath != nil {
                    ProgressView(runtime.connectionState == .connecting ? L10n.text("正在连接远程服务器…") : L10n.text("正在读取目录…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isReady {
                    if directories.isEmpty {
                        ContentUnavailableView(L10n.text("没有子文件夹"), systemImage: "folder", description: Text("可以直接选择当前目录。"))
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(directories) { directory in
                                    Button { runtime.navigate(to: directory.path) } label: {
                                        HStack(spacing: 10) {
                                            Image(systemName: directory.isSymbolicLink ? "folder.badge.questionmark" : "folder.fill")
                                                .foregroundStyle(SnakeStyle.action)
                                            Text(directory.name).lineLimit(1)
                                            Spacer()
                                            Image(systemName: "chevron.right").foregroundStyle(SnakeStyle.muted)
                                        }
                                        .padding(.horizontal, 16)
                                        .frame(height: 36)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.format("打开文件夹 %@", directory.name))
                                    Divider().padding(.leading, 42)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(L10n.text("尚未连接"), systemImage: "network", description: Text("连接成功后即可浏览远程文件夹。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SnakeOutlineButtonStyle())
                Spacer()
                Button("选择此目录") {
                    onSelect(runtime.currentPath)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(SnakeOutlineButtonStyle(emphasized: true))
                .disabled(!isReady)
            }
            .padding(16)
        }
        .frame(width: 620, height: 500)
        .background(SnakeStyle.canvas)
        .task { runtime.connectIfNeeded() }
        .onChange(of: runtime.connectionState) { _, state in
            guard state == .connected, !openedInitialPath else { return }
            openedInitialPath = true
            if initialPath.hasPrefix("/"), initialPath != runtime.currentPath {
                runtime.navigate(to: initialPath)
            }
        }
        .onDisappear { runtime.disconnect() }
        .alert(runtime.pendingHostKey?.title ?? L10n.text("确认主机密钥"), isPresented: Binding(
            get: { runtime.pendingHostKey != nil },
            set: { if !$0, runtime.pendingHostKey != nil { runtime.rejectPendingHostKey() } }
        )) {
            Button("取消", role: .cancel) { runtime.rejectPendingHostKey() }
            Button(runtime.pendingHostKey?.acceptTitle ?? L10n.text("信任并连接")) { runtime.acceptPendingHostKey() }
        } message: {
            if let prompt = runtime.pendingHostKey {
                Text(prompt.message)
            }
        }
    }
}
