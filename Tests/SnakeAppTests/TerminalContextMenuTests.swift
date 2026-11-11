import AppKit
import XCTest
@testable import SnakeApp

@MainActor
final class TerminalContextMenuTests: XCTestCase {
    private let profile = SSHProfile(name: "新闻社", host: "172.25.67.40", port: 13022, username: "root")

    private func openMenu(_ runtime: TerminalRuntime) throws -> NSMenu {
        let menu = try XCTUnwrap(runtime.terminalSurface().menu)
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    private func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.items.first { $0.title == L10n.text(title) }
    }

    func testOfflineTerminalOffersOnlyWhatCanWork() throws {
        let runtime = TerminalRuntime(profile: profile)
        let menu = try openMenu(runtime)
        XCTAssertEqual(item(menu, "复制")?.isEnabled, false, "nothing is selected")
        XCTAssertEqual(item(menu, "粘贴")?.isEnabled, false, "nothing to type into before connecting")
        XCTAssertEqual(item(menu, "粘贴所选内容")?.isEnabled, false)
        XCTAssertEqual(item(menu, "全选")?.isEnabled, true)
        XCTAssertEqual(item(menu, "清屏")?.isEnabled, false)
        XCTAssertEqual(item(menu, "上传文件")?.isEnabled, false)
        XCTAssertEqual(item(menu, "打开 SFTP")?.isEnabled, false, "no window coordinator in tests")
        XCTAssertEqual(item(menu, "复制 SSH 命令")?.isEnabled, true)
        XCTAssertEqual(item(menu, "重新连接")?.isEnabled, false, "dimmed, not hidden")
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), [L10n.text("文件"), L10n.text("会话")])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem && !$0.isSectionHeader }.allSatisfy { $0.image != nil })
        XCTAssertFalse(menu.items.contains { $0.title.hasSuffix("…") })
        XCTAssertEqual(item(menu, "复制")?.keyEquivalent, "c")
    }

    func testFailedTerminalOffersReconnectAndTheLog() throws {
        let runtime = TerminalRuntime(profile: profile)
        runtime.requestConnection()
        runtime.cancelConnecting()
        let menu = try openMenu(runtime)
        XCTAssertEqual(item(menu, "重新连接")?.isEnabled, true)
        let log = try XCTUnwrap(menu.items.firstIndex { $0.title == L10n.text("查看连接日志") })
        menu.performActionForItem(at: log)
        XCTAssertTrue(runtime.showsLog)
    }

    func testSSHCommandOmitsTheDefaultPort() {
        XCTAssertEqual(TerminalContextMenu.sshCommand(for: profile), "ssh -p 13022 root@172.25.67.40")
        XCTAssertEqual(TerminalContextMenu.sshCommand(for: SSHProfile(name: "a", host: "example.com", username: "deploy")),
                       "ssh deploy@example.com")
    }

    func testSFTPOpenedFromATerminalRemembersTheDirectory() {
        let tab = WorkspaceTabRuntime(sftp: profile, path: "/var/log")
        XCTAssertEqual(tab.sftp?.pendingInitialPath, "/var/log")
        XCTAssertNil(WorkspaceTabRuntime(sftp: profile).sftp?.pendingInitialPath)
    }
}
