import AppKit
import SwiftTerm

/// The terminal's right-click menu. It is rebuilt each time it opens so every
/// item reflects the selection, the clipboard and the connection right now.
@MainActor
final class TerminalContextMenu: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private weak var runtime: TerminalRuntime?
    weak var store: ApplicationStore?

    init(runtime: TerminalRuntime) {
        self.runtime = runtime
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// What the menu offers for a given moment; kept separate so tests can check it.
    struct Availability: Equatable {
        var hasSelection: Bool
        var canPaste: Bool
        var isConnected: Bool
        var canReconnect: Bool
        var knowsDirectory: Bool
        var canOpenSFTP: Bool
    }

    func availability() -> Availability {
        let view = runtime?.existingTerminalSurface
        let connected = runtime?.state == .connected
        return Availability(
            hasSelection: view?.selectionActive == true,
            canPaste: connected && NSPasteboard.general.string(forType: .string)?.isEmpty == false,
            isConnected: connected,
            canReconnect: runtime.map { $0.state == .failed || $0.state == .disconnected } ?? false,
            knowsDirectory: runtime?.currentRemoteDirectory != nil,
            canOpenSFTP: store?.workspaceCoordinator != nil
        )
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = availability()
        let build = SnakeMenuBuilder(menu: menu, target: self)
        build.item(L10n.text("复制"), symbol: "doc.on.doc", key: "c", enabled: state.hasSelection, action: #selector(copySelection))
        build.item(L10n.text("粘贴"), symbol: "doc.on.clipboard", key: "v", enabled: state.canPaste, action: #selector(paste))
        build.item(L10n.text("粘贴所选内容"), symbol: "text.insert", enabled: state.hasSelection && state.isConnected,
                   action: #selector(pasteSelection))
        build.item(L10n.text("全选"), symbol: "selection.pin.in.out", key: "a", action: #selector(selectAll))
        build.item(L10n.text("清屏"), symbol: "eraser", key: "l", modifiers: [.control], enabled: state.isConnected,
                   action: #selector(clearScreen))
        build.header(L10n.text("文件"))
        build.item(state.knowsDirectory ? L10n.text("上传文件到当前目录") : L10n.text("上传文件"), symbol: "square.and.arrow.up",
                   enabled: state.isConnected && store != nil, action: #selector(upload))
        build.item(state.knowsDirectory ? L10n.text("在 SFTP 中打开当前目录") : L10n.text("打开 SFTP"), symbol: "folder",
                   enabled: state.canOpenSFTP, action: #selector(openSFTP))
        build.header(L10n.text("会话"))
        build.item(L10n.text("复制 SSH 命令"), symbol: "terminal", action: #selector(copySSHCommand))
        build.item(L10n.text("重新连接"), symbol: "arrow.clockwise", enabled: state.canReconnect, action: #selector(reconnect))
        build.item(L10n.text("查看连接日志"), symbol: "list.bullet.rectangle", action: #selector(showLog))
    }

    @objc private func copySelection() { runtime?.existingTerminalSurface?.copy(self) }

    @objc private func paste() {
        guard runtime?.state == .connected else { return }
        runtime?.existingTerminalSurface?.paste(self)
    }

    /// Types the selected text at the prompt, like a middle click in X11 terminals.
    @objc private func pasteSelection() {
        guard runtime?.state == .connected, let view = runtime?.existingTerminalSurface,
              let text = view.getSelection(), !text.isEmpty else { return }
        view.pasteText(text)
    }

    @objc private func selectAll() { runtime?.existingTerminalSurface?.selectAll(self) }

    /// Ctrl-L: the shell redraws its prompt at the top and keeps the scrollback.
    @objc private func clearScreen() { runtime?.send(Data([0x0c])) }

    @objc private func upload() {
        guard let store else { return }
        runtime?.chooseFilesToUpload(store: store)
    }

    @objc private func openSFTP() {
        guard let runtime else { return }
        store?.workspaceCoordinator?.openSFTP(for: runtime.profile, path: runtime.currentRemoteDirectory)
    }

    @objc private func copySSHCommand() {
        guard let profile = runtime?.profile else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.sshCommand(for: profile), forType: .string)
    }

    @objc private func reconnect() { runtime?.retryConnection() }

    @objc private func showLog() { runtime?.showsLog = true }

    /// `ssh user@host`, adding `-p` only for a non-standard port.
    nonisolated static func sshCommand(for profile: SSHProfile) -> String {
        let target = "\(profile.username)@\(profile.host)"
        return profile.port == 22 ? "ssh \(target)" : "ssh -p \(profile.port) \(target)"
    }
}
