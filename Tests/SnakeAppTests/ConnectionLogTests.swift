import XCTest
import SnakeCoreBindings
@testable import SnakeApp

@MainActor
final class ConnectionLogTests: XCTestCase {
    private let profile = SSHProfile(name: "新闻社", host: "172.25.67.40", port: 13022, username: "root")

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("State did not settle")
    }

    func testLogKeepsTheNewestEntriesAndCopiesAsText() {
        let log = ConnectionLog(now: { Date(timeIntervalSince1970: 0) })
        for index in 0..<(ConnectionLog.limit + 5) { log.append(.info, "entry \(index)") }
        XCTAssertEqual(log.entries.count, ConnectionLog.limit)
        XCTAssertEqual(log.entries.first?.message, "entry 5")

        let fresh = ConnectionLog()
        fresh.beginAttempt(profile, kind: "SSH")
        fresh.recordFailure("TCP 连接失败", error: CoreError.Connection(message: "Connection refused", stage: "tcp_connect"))
        let text = fresh.text
        XCTAssertTrue(text.contains("[INFO]"))
        XCTAssertTrue(text.contains("root@172.25.67.40:13022"))
        XCTAssertTrue(text.contains("[ERROR] TCP 连接失败"))
        XCTAssertTrue(text.contains("stage=tcp_connect · Connection refused"))
    }

    func testTechnicalDetailNamesTheStageWithoutSecrets() {
        XCTAssertEqual(ConnectionLog.technicalDetail(CoreError.Authentication(message: "", stage: "auth_password")), "stage=auth_password")
        XCTAssertEqual(
            ConnectionLog.technicalDetail(CoreError.HostKeyUnknown(host: "h", port: 22, algorithm: "ssh-ed25519", fingerprint: "SHA256:x")),
            "host_key_unknown · h:22 ssh-ed25519 SHA256:x"
        )
    }

    func testCancellingATerminalAttemptIsLoggedAndKeepsTheFailureMessage() {
        let runtime = TerminalRuntime(profile: profile)
        runtime.requestConnection()
        XCTAssertEqual(runtime.state, .connecting)
        runtime.cancelConnecting()
        XCTAssertEqual(runtime.state, .failed)
        XCTAssertEqual(runtime.errorMessage, L10n.text("已取消连接。"))
        XCTAssertEqual(runtime.log.entries.last?.level, .warning)
        XCTAssertEqual(runtime.log.entries.last?.message, L10n.text("已取消连接。"))
    }

    func testFailedSFTPAttemptRecordsStartAndReason() async {
        // No saved password: authentication fails before any network or credential access.
        let runtime = SFTPRuntime(profile: profile)
        runtime.connectIfNeeded()
        await waitUntil { runtime.connectionState == .failed }
        XCTAssertNotNil(runtime.errorMessage)
        XCTAssertEqual(runtime.log.entries.first?.level, .info)
        XCTAssertEqual(runtime.log.entries.last?.level, .error)
        XCTAssertEqual(runtime.log.entries.last?.message, runtime.errorMessage)
    }

    func testAuthMethodReadsAsPasswordOrKey() {
        XCTAssertEqual(AuthMethod.password.label, L10n.text("密码"))
        XCTAssertEqual(AuthMethod.privateKey.label, L10n.text("密钥"))
    }
}
