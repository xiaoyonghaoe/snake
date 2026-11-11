import XCTest
import SnakeCoreBindings
@testable import SnakeApp

@MainActor
final class SSHKeyLibraryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "snake.tests.keys.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() -> ApplicationStore {
        ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults,
                         keyDirectoryURL: root.appendingPathComponent("Keys", isDirectory: true))
    }

    private func writeKeyFile(_ content: String) throws -> URL {
        let url = root.appendingPathComponent("id_\(UUID().uuidString)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testGeneratedKeyIsStoredOwnerOnlyAndSurvivesRelaunch() throws {
        let store = makeStore()
        let record = try store.generateSSHKey(name: " 工作机 ", comment: "me@snake", passphrase: nil)
        XCTAssertEqual(record.name, "工作机")
        XCTAssertEqual(record.algorithmLabel, "Ed25519")
        XCTAssertFalse(record.hasPassphrase)
        XCTAssertTrue(record.publicKey.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(record.fingerprint.hasPrefix("SHA256:"))

        let file = store.sshKeyStore.fileURL(for: record.id)
        XCTAssertEqual(try permissions(file), 0o600)
        XCTAssertEqual(try permissions(file.deletingLastPathComponent()), 0o700)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))

        XCTAssertEqual(makeStore().sshKeys, [record])
        XCTAssertThrowsError(try store.generateSSHKey(name: "  ", comment: "", passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyError, .nameRequired)
        }
    }

    func testImportRejectsDuplicatesAndPublicKeysAndRequiresPassphrase() throws {
        let store = makeStore()
        let existing = try store.generateSSHKey(name: "已有", comment: "", passphrase: nil)
        let copy = try writeKeyFile(String(contentsOf: store.sshKeyStore.fileURL(for: existing.id), encoding: .utf8))
        XCTAssertThrowsError(try store.importSSHKey(from: copy, name: "副本", passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyError, .duplicate("已有"))
        }

        let publicOnly = try writeKeyFile(existing.publicKey)
        XCTAssertThrowsError(try store.importSSHKey(from: publicOnly, name: "公钥", passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyError, .unrecognized)
        }

        let encrypted = try writeKeyFile(generateEd25519Key(comment: "", passphrase: "pw123").privateKey)
        XCTAssertThrowsError(try store.importSSHKey(from: encrypted, name: "加密", passphrase: nil)) {
            XCTAssertEqual($0 as? SSHKeyError, .passphraseRequired)
        }
        XCTAssertThrowsError(try store.importSSHKey(from: encrypted, name: "加密", passphrase: "wrong")) {
            XCTAssertEqual($0 as? SSHKeyError, .passphraseIncorrect)
        }
        let imported = try store.importSSHKey(from: encrypted, name: "加密", passphrase: "pw123")
        XCTAssertTrue(imported.hasPassphrase)
        XCTAssertEqual(store.sshKeys.map(\.name), ["已有", "加密"])
    }

    func testDeleteIsBlockedWhileASessionUsesTheKey() throws {
        let store = makeStore()
        let record = try store.generateSSHKey(name: "部署", comment: "", passphrase: nil)
        let profile = SSHProfile(name: "dev-01", host: "192.0.2.10", username: "root", authMethod: .privateKey,
                                 privateKeyBookmark: try store.sshKeyBookmark(for: record.id))
        try store.save(profile: profile)
        XCTAssertEqual(store.profiles(usingKey: record.id).map(\.id), [profile.id])
        XCTAssertEqual(store.sshKey(forBookmark: profile.privateKeyBookmark)?.id, record.id)

        XCTAssertThrowsError(try store.deleteSSHKey(id: record.id)) {
            XCTAssertEqual($0 as? SSHKeyError, .inUse(["dev-01"]))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sshKeyStore.fileURL(for: record.id).path))

        var switched = profile
        switched.authMethod = .password
        switched.privateKeyBookmark = nil
        try store.save(profile: switched)
        try store.renameSSHKey(id: record.id, to: "旧部署")
        XCTAssertEqual(store.sshKeys.first?.name, "旧部署")
        try store.deleteSSHKey(id: record.id)
        XCTAssertTrue(store.sshKeys.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sshKeyStore.fileURL(for: record.id).path))
    }

    func testFailedPassphraseWriteLeavesNoKeyBehind() throws {
        struct Refused: Error {}
        let keys = SSHKeyStore(root: root.appendingPathComponent("Keys"), storePassphrase: { secret, _ in
            if secret != nil { throw Refused() }
        })
        let key = try generateEd25519Key(comment: "", passphrase: "pw123")
        XCTAssertThrowsError(try keys.add(name: "x", key: key, passphrase: "pw123"))
        XCTAssertTrue(keys.load().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: keys.root.path), [])
    }
}

@MainActor
final class CredentialAuthenticationGraceTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Reveal state did not settle")
    }

    func testOneApprovalCoversOtherPasswordsForThirtySeconds() async {
        var clock = ContinuousClock.now
        let grace = CredentialAuthenticationGrace(now: { clock })
        var verifiers: [FakeCredentialAuthentication] = []
        func makeController() -> CredentialRevealController {
            CredentialRevealController(grace: grace, canPresent: { true }, makeAuthentication: {
                let verifier = FakeCredentialAuthentication()
                verifiers.append(verifier)
                return verifier
            }, read: { _ in Data("fixture".utf8) })
        }

        let first = makeController()
        first.reveal(account: "test/a")
        await waitUntil { verifiers.first?.completion != nil }
        verifiers[0].resolve()
        await waitUntil { first.plaintext != nil }
        first.hide()

        clock += .seconds(29)
        let second = makeController()
        second.reveal(account: "test/b")
        await waitUntil { second.plaintext != nil }
        XCTAssertNil(verifiers.last?.completion, "inside the window no new prompt is shown")
        second.hide()

        clock += .seconds(2)
        let third = makeController()
        third.reveal(account: "test/c")
        await waitUntil { verifiers.count == 3 && verifiers[2].completion != nil }
        XCTAssertNil(third.plaintext)
        verifiers[2].resolve()
        await waitUntil { third.plaintext != nil }
        third.hide()
    }

    func testFailedApprovalDoesNotOpenTheWindow() async {
        let grace = CredentialAuthenticationGrace()
        let verifier = FakeCredentialAuthentication()
        let controller = CredentialRevealController(grace: grace, canPresent: { true }, makeAuthentication: { verifier },
                                                    read: { _ in Data("fixture".utf8) })
        controller.reveal(account: "test/a")
        await waitUntil { verifier.completion != nil }
        verifier.resolve(CredentialAuthenticationError.failed)
        await waitUntil { !controller.isLoading }
        XCTAssertFalse(grace.isActive)
        grace.recordApproval()
        XCTAssertTrue(grace.isActive)
        grace.revoke()
        XCTAssertFalse(grace.isActive)
    }
}
