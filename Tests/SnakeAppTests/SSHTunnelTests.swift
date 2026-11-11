import XCTest
import SnakeCoreBindings
@testable import SnakeApp

@MainActor
final class SSHTunnelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "snake.tests.tunnels.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var database: URL { root.appendingPathComponent("test.sqlite3") }

    private func makeStore() -> ApplicationStore {
        ApplicationStore(databaseURL: database, userDefaults: defaults, keyDirectoryURL: root.appendingPathComponent("Keys"))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Tunnel state did not settle")
    }

    func testSaveValidatesAndPersistsAcrossRelaunch() throws {
        let store = makeStore()
        let profile = SSHProfile(name: "db", host: "192.0.2.10", username: "root")
        try store.save(profile: profile)
        let tunnels = store.tunnels

        XCTAssertThrowsError(try tunnels.save(SSHTunnel(localPort: 13306, remotePort: 3306))) {
            XCTAssertEqual($0 as? SSHTunnelError, .profileRequired)
        }
        XCTAssertThrowsError(try tunnels.save(SSHTunnel(profileID: profile.id, localPort: 0, remotePort: 3306))) {
            XCTAssertEqual($0 as? SSHTunnelError, .invalidLocalPort)
        }
        XCTAssertThrowsError(try tunnels.save(SSHTunnel(profileID: profile.id, localPort: 13306, remotePort: 70_000))) {
            XCTAssertEqual($0 as? SSHTunnelError, .invalidRemotePort)
        }
        XCTAssertThrowsError(try tunnels.save(SSHTunnel(profileID: profile.id, localPort: 13306, remoteHost: "  ", remotePort: 3306))) {
            XCTAssertEqual($0 as? SSHTunnelError, .remoteHostRequired)
        }

        let mysql = SSHTunnel(profileID: profile.id, localPort: 13306, remoteHost: " 127.0.0.1 ", remotePort: 3306,
                              note: " 生产库 ", autoStart: true)
        try tunnels.save(mysql)
        XCTAssertThrowsError(try tunnels.save(SSHTunnel(profileID: profile.id, localPort: 13306, remotePort: 5432))) {
            XCTAssertEqual($0 as? SSHTunnelError, .duplicateLocalPort(13306))
        }
        let stored = try XCTUnwrap(tunnels.tunnels.first)
        XCTAssertEqual(stored.remoteHost, "127.0.0.1")
        XCTAssertEqual(stored.note, "生产库")
        XCTAssertNotNil(stored.createdAt)
        XCTAssertEqual(tunnels.state(of: stored.id), .stopped)

        try tunnels.setAutoStart(false, for: stored.id)
        let reloaded = makeStore().tunnels.tunnels
        XCTAssertEqual(reloaded.map(\.localPort), [13306])
        XCTAssertEqual(reloaded.first?.autoStart, false)
        XCTAssertEqual(reloaded.first?.remoteAddress, "127.0.0.1:3306")

        try tunnels.delete(stored.id)
        XCTAssertTrue(makeStore().tunnels.tunnels.isEmpty)
    }

    func testDeletingTheSessionUnbindsItsTunnels() throws {
        let store = makeStore()
        let profile = SSHProfile(name: "db", host: "192.0.2.10", username: "root")
        try store.save(profile: profile)
        try store.tunnels.save(SSHTunnel(profileID: profile.id, localPort: 15432, remotePort: 5432))
        store.delete(profile: profile)
        XCTAssertEqual(store.tunnels.tunnels.count, 1)
        XCTAssertNil(store.tunnels.tunnels.first?.profileID)
        XCTAssertNil(makeStore().tunnels.tunnels.first?.profileID, "the unbinding is stored")

        let id = try XCTUnwrap(store.tunnels.tunnels.first?.id)
        store.tunnels.start(id)
        guard case .failed = store.tunnels.state(of: id) else { return XCTFail("an unbound tunnel cannot start") }
    }

    func testStartFailureIsShownAndStopDropsALateResult() async throws {
        let profile = SSHProfile(name: "db", host: "192.0.2.10", username: "root")
        let gate = DispatchSemaphore(value: 0)
        let controller = SSHTunnelController(persistence: nil, starter: { _, tunnel, _ in
            if tunnel.localPort == 18080 { gate.wait() }
            throw CoreError.Connection(message: "", stage: "tunnel_port_in_use")
        })
        controller.profile = { $0 == profile.id ? profile : nil }
        try controller.save(SSHTunnel(profileID: profile.id, localPort: 13306, remotePort: 3306))
        try controller.save(SSHTunnel(profileID: profile.id, localPort: 18080, remotePort: 8080))
        let busy = controller.tunnels[0].id
        let slow = controller.tunnels[1].id

        controller.start(busy)
        XCTAssertEqual(controller.state(of: busy), .starting)
        await waitUntil { controller.state(of: busy) != .starting }
        XCTAssertEqual(controller.state(of: busy).label, TunnelState.failed("").label)
        XCTAssertEqual(controller.state(of: busy).detail, L10n.text("本地端口已被占用，请换一个端口或先关闭占用它的程序"))

        controller.start(slow)
        controller.stop(slow)
        gate.signal()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state(of: slow), .stopped, "a cancelled attempt does not overwrite the stop")
    }

    func testHostKeyAndAuthenticationErrorsReadAsGuidance() {
        let unknown = SSHTunnelController.message(for: CoreError.HostKeyUnknown(host: "h", port: 22, algorithm: "ed25519", fingerprint: "f"))
        XCTAssertTrue(unknown.contains("指纹"))
        XCTAssertEqual(SSHTunnelController.message(for: CoreError.Connection(message: "refused", stage: "ssh_direct_tcpip")),
                       L10n.format("服务器拒绝转发：%@", "refused"))
    }

    func testKeyIndexWithoutUpdatedAtFallsBackAndRenameMovesIt() throws {
        let keys = root.appendingPathComponent("Keys", isDirectory: true)
        let store = makeStore()
        let record = try store.generateSSHKey(name: "旧", comment: "", passphrase: nil)
        // Rewrite the index the way 1.4.0 stored it, without updatedAt.
        let index = keys.appendingPathComponent("index.json")
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        entries[0]["updatedAt"] = nil
        try JSONSerialization.data(withJSONObject: entries).write(to: index)

        let legacy = try XCTUnwrap(makeStore().sshKeys.first)
        XCTAssertEqual(legacy.updatedAt, legacy.createdAt)
        let relaunched = makeStore()
        try relaunched.renameSSHKey(id: record.id, to: "新")
        let renamed = try XCTUnwrap(relaunched.sshKeys.first)
        XCTAssertGreaterThan(renamed.updatedAt, legacy.createdAt)
        XCTAssertEqual(renamed.createdAt, legacy.createdAt)
    }
}
