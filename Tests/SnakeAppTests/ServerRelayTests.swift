import Foundation
import XCTest
import SnakeCoreBindings
@testable import SnakeApp

/// Server-to-server copies relay through a private batch folder that must be the
/// only thing Snake ever deletes in the relay location.
@MainActor
final class ServerRelayTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)", isDirectory: true)

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBatchIsPrivateAndRemovedWithItsContents() throws {
        let batch = try ServerRelay.makeBatch(root: root, ownedRoot: false)
        XCTAssertTrue(ServerRelay.isBatch(batch))
        let mode = try FileManager.default.attributesOfItem(atPath: batch.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        try FileManager.default.createDirectory(at: batch.appendingPathComponent("dir"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: batch.appendingPathComponent("dir/file"))

        ServerRelay.removeBatch(batch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.path))
    }

    func testOnlyBatchFoldersAreEverRemoved() throws {
        let manager = FileManager.default
        let userFolder = root.appendingPathComponent("snake-relay-notes", isDirectory: true)
        let userUUIDFolder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: userFolder, withIntermediateDirectories: false)
        try manager.createDirectory(at: userUUIDFolder, withIntermediateDirectories: false)
        let userFile = root.appendingPathComponent("snake-relay-\(UUID().uuidString)")
        try Data("mine".utf8).write(to: userFile)
        // A link that looks like a batch must not lead removal into its target.
        let target = root.appendingPathComponent("target", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("keep"))
        let link = root.appendingPathComponent("snake-relay-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let stale = try ServerRelay.makeBatch(root: root, ownedRoot: false)

        XCTAssertEqual(ServerRelay.removeStaleBatches(root: root), 1)
        XCTAssertFalse(manager.fileExists(atPath: stale.path))
        for kept in [userFolder, userUUIDFolder, userFile, target.appendingPathComponent("keep")] {
            XCTAssertTrue(manager.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        XCTAssertNotNil(try? manager.destinationOfSymbolicLink(atPath: link.path))
        ServerRelay.removeBatch(link)
        XCTAssertTrue(manager.fileExists(atPath: target.appendingPathComponent("keep").path))
    }

    /// Uploading reads through links, so links from the source server are dropped
    /// before the upload and their targets are never touched.
    func testSymbolicLinksAreRemovedWithoutFollowingThem() throws {
        let manager = FileManager.default
        let secret = root.appendingPathComponent("secret")
        try Data("local".utf8).write(to: secret)
        let batch = try ServerRelay.makeBatch(root: root, ownedRoot: false)
        let folder = batch.appendingPathComponent("folder", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("remote".utf8).write(to: folder.appendingPathComponent("data"))
        try manager.createSymbolicLink(atPath: folder.appendingPathComponent("leak").path, withDestinationPath: secret.path)
        try manager.createSymbolicLink(atPath: batch.appendingPathComponent("up").path, withDestinationPath: root.path)

        XCTAssertEqual(ServerRelay.removeSymbolicLinks(in: batch), 2)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path), ["data"])
        XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "local")
    }

    func testRelayFolderSettingPersistsAndFallsBackToTheSystemCache() throws {
        let suite = "snake.relay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = root.appendingPathComponent("test.sqlite3")
        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(store.serverRelayDirectoryPath, ServerRelay.defaultRoot().path)

        let chosen = root.appendingPathComponent("chosen", isDirectory: true)
        XCTAssertNil(store.setServerRelayDirectory(chosen))
        XCTAssertEqual(
            URL(fileURLWithPath: store.serverRelayDirectoryPath).resolvingSymlinksInPath(),
            chosen.resolvingSymlinksInPath()
        )
        let reopened = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(reopened.serverRelayDirectoryPath, store.serverRelayDirectoryPath)

        XCTAssertNil(reopened.setServerRelayDirectory(nil))
        XCTAssertEqual(reopened.serverRelayDirectoryPath, ServerRelay.defaultRoot().path)
    }

    /// A failed download's local copy must never be uploaded back to its server, and a
    /// relay upload has no file left to retry from.
    func testDownloadAndRelayRecordsAreNeverRetriedAsUploads() throws {
        let suite = "snake.relay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        let uploader = LocalUploadCoordinator(profile: SSHProfile(name: "a", host: "127.0.0.1", username: "u"))
        let local = root.appendingPathComponent("copy")
        try Data("x".utf8).write(to: local)
        var download = SFTPUploadRecord(jobID: UUID(), fileName: "copy", remotePath: "/srv/copy", fileSize: 1,
                                        startedAt: .now, state: .failed, localURL: local, overwrite: false)
        download.isDownload = true
        var relay = SFTPUploadRecord(jobID: UUID(), fileName: "copy", remotePath: "/srv/copy", fileSize: 1,
                                     startedAt: .now, state: .failed, localURL: local, overwrite: false)
        relay.isRelay = true
        uploader.records = [download, relay]

        uploader.retry(jobID: download.jobID, store: store)
        uploader.retry(jobID: relay.jobID, store: store)
        XCTAssertNil(uploader.batchTask)
        XCTAssertEqual(uploader.records.map(\.state), [.failed, .failed])
    }

    /// Real relay over a disposable loopback sshd (the same fixture as the Rust SFTP
    /// regressions): both "servers" are this machine, so remote paths are local ones.
    func testRelayCopiesATreeThroughTheBatchAndSkipsLinks() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let portValue = environment["SNAKE_SFTP_TEST_PORT"], let port = UInt16(portValue),
              let user = environment["SNAKE_SFTP_TEST_USER"], let key = environment["SNAKE_SFTP_TEST_KEY"] else {
            throw XCTSkip("Set SNAKE_SFTP_TEST_PORT, SNAKE_SFTP_TEST_USER and SNAKE_SFTP_TEST_KEY for the loopback sshd")
        }
        let manager = FileManager.default
        let base = root.resolvingSymlinksInPath()
        let hosts = base.appendingPathComponent("known_hosts").path
        let fingerprint = try probeHostKey(host: "127.0.0.1", port: port).fingerprint
        _ = try openSftpPrivateKey(host: "127.0.0.1", port: port, username: user, privateKeyPath: key, passphrase: nil,
                                   knownHostsPath: hosts, acceptFingerprint: fingerprint, dedicated: true)
        let make: @Sendable () throws -> CoreSftpHandle = {
            try openSftpPrivateKey(host: "127.0.0.1", port: port, username: user, privateKeyPath: key, passphrase: nil,
                                   knownHostsPath: hosts, acceptFingerprint: nil, dedicated: true)
        }

        let tree = base.appendingPathComponent("source/tree", isDirectory: true)
        try manager.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("small".utf8).write(to: tree.appendingPathComponent("a.txt"))
        let large = Data((0..<(3 * 1_048_576 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try large.write(to: tree.appendingPathComponent("sub/large.bin"))
        let secret = base.appendingPathComponent("secret")
        try Data("local only".utf8).write(to: secret)
        try manager.createSymbolicLink(atPath: tree.appendingPathComponent("leak").path, withDestinationPath: secret.path)
        let destination = base.appendingPathComponent("destination", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: false)

        let suite = "snake.relay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationStore(databaseURL: base.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        store.multipartThresholdMB = 1
        store.multipartConcurrency = 2
        let coordinator = LocalUploadCoordinator(profile: SSHProfile(name: "目标", host: "127.0.0.1", username: user))
        coordinator.transferHandleFactory = make
        let source = DownloadSource(profile: SSHProfile(name: "来源", host: "127.0.0.1", username: user), makeHandle: make)
        let batch = try ServerRelay.makeBatch(root: base.appendingPathComponent("relay"), ownedRoot: false)

        await coordinator.relay(RemoteFile(name: "tree", path: tree.path, isDirectory: true), from: source,
                                through: batch, to: destination.path, store: store)
        ServerRelay.removeBatch(batch)

        let copied = destination.appendingPathComponent("tree")
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("a.txt")), Data("small".utf8))
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("sub/large.bin")), large)
        XCTAssertFalse(manager.fileExists(atPath: copied.appendingPathComponent("leak").path))
        XCTAssertFalse(manager.fileExists(atPath: batch.path))
        XCTAssertFalse(coordinator.records.isEmpty)
        XCTAssertTrue(coordinator.records.allSatisfy { $0.isRelay && $0.state == .succeeded }, "\(coordinator.records.map(\.state))")
        XCTAssertTrue(coordinator.records.filter(\.isDownload).allSatisfy { $0.relaySource == "来源" })
        XCTAssertTrue(coordinator.records.contains { !$0.isDownload && $0.remotePath.hasSuffix("tree/sub/large.bin") })
    }
}
