import CryptoKit
import Darwin
import XCTest
import SnakeCoreBindings
@testable import SnakeApp

final class TransferIntegrityTests: XCTestCase {
    func testSHA256MD5StreamingAndCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-integrity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("中文 '文件")
        for data in [Data(), Data("abc".utf8), Data(repeating: 0x7c, count: 3 * 1024 * 1024 + 7)] {
            try data.write(to: file)
            XCTAssertEqual(try TransferIntegrity.localDigest(url: file, algorithm: "SHA-256", control: CoreTransferControl()), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(try TransferIntegrity.localDigest(url: file, algorithm: "MD5", control: CoreTransferControl()), Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let cancelled = CoreTransferControl(); cancelled.cancel()
        XCTAssertThrowsError(try TransferIntegrity.localDigest(url: file, algorithm: "SHA-256", control: cancelled))
        XCTAssertThrowsError(try TransferIntegrity.compare("abc", "def"))
        XCTAssertThrowsError(try TransferIntegrity.localDigest(url: file, algorithm: "unknown", control: CoreTransferControl()))
    }

    func testNoFollowStagingAtomicOverwriteAndCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("snake-staging-\(UUID())")
        let outside = fm.temporaryDirectory.appendingPathComponent("snake-outside-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let location = try DownloadLocation(root: root)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertThrowsError(try location.directory(["escape", "child"]))
        for unsafe in ["..", ".", "", "a/b", "a\0b"] { XCTAssertThrowsError(try DownloadLocation.validate(unsafe)) }
        let parent = try location.directory(["folder"])
        let file = parent.url.appendingPathComponent("target")
        try Data("old".utf8).write(to: file)
        var staging: DownloadStaging? = try DownloadStaging(parent: parent, size: 3)
        let temporary = try XCTUnwrap(staging).name
        let bytes: [UInt8] = [110, 101, 119]
        XCTAssertEqual(pwrite(try XCTUnwrap(staging).fd, bytes, 3, 0), 3)
        XCTAssertEqual(try Data(contentsOf: file), Data("old".utf8))
        XCTAssertThrowsError(try staging?.publish(as: "target", overwrite: false))
        try staging?.publish(as: "target", overwrite: true)
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
        staging = nil
        XCTAssertFalse(try parent.exists(temporary))
        try parent.createLink(name: "link", target: "../missing", overwrite: false)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: parent.url.appendingPathComponent("link").path), "../missing")
    }

    func testRootDedupeAndRangeCoverage() {
        let folder = RemoteFile(name: "logs", path: "/data/logs", isDirectory: true)
        let child = RemoteFile(name: "a", path: "/data/logs/a", isDirectory: false)
        let similar = RemoteFile(name: "logs2", path: "/data/logs2", isDirectory: false)
        XCTAssertEqual(DownloadManifest.roots([child, folder, folder, similar]).map(\.path), [folder.path, similar.path])
        for size: UInt64 in [0, 1, 7, 1024 * 1024 * 51 + 13] {
            let ranges = LocalUploadCoordinator.uploadRanges(totalBytes: size, workerCount: 4)
            XCTAssertEqual(ranges.reduce(0) { $0 + $1.length }, size)
            XCTAssertLessThanOrEqual(ranges.count, 4)
            for pair in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(pair.0.offset + pair.0.length, pair.1.offset) }
        }
    }

    func testUnverifiedAndCheckingAreNotPassed() {
        XCTAssertTrue(TransferVerification.unavailable("没有工具").isWarning)
        XCTAssertTrue(TransferVerification.checking("MD5").isChecking)
        XCTAssertFalse(TransferVerification.passed("MD5").isWarning)
        XCTAssertNotEqual(TransferVerification.unavailable("没有工具"), .passed("SHA-256"))
    }

    func testBestEffortSkipsUnavailableChecksButRetainsCancelAndMismatch() throws {
        let capability = TransferIntegrity.bestEffortCapability { throw TransferIntegrity.error("probe failed") }
        XCTAssertEqual(capability.tool, "sftp-only")
        XCTAssertTrue(capability.algorithm.isEmpty)
        let unavailable = try TransferIntegrity.bestEffortVerification(algorithm: "SHA-256", local: { "a" }, remote: { throw TransferIntegrity.error("command failed") })
        XCTAssertTrue(unavailable.isWarning)
        XCTAssertThrowsError(try TransferIntegrity.bestEffortVerification(algorithm: "MD5", local: { "a" }, remote: { "b" }))
        XCTAssertThrowsError(try TransferIntegrity.bestEffortVerification(algorithm: "SHA-256", local: { throw CoreError.TransferCancelled }, remote: { "a" }))
        XCTAssertEqual(try TransferIntegrity.bestEffortVerification(algorithm: "MD5", local: { "a" }, remote: { "a" }), .passed("MD5"))
    }
}

@MainActor
final class SFTPDownloadIntegrationTests: XCTestCase {
    private func factory(user: String, root: URL) throws -> @Sendable () throws -> CoreSftpHandle {
        guard let value = ProcessInfo.processInfo.environment["SNAKE_TRANSFER_TEST_PORT"], let port = UInt16(value) else {
            throw XCTSkip("Set SNAKE_TRANSFER_TEST_PORT for the disposable loopback Docker fixture")
        }
        let key = try probeHostKey(host: "127.0.0.1", port: port)
        let hosts = root.appendingPathComponent("known_hosts").path
        // First verified connection writes the fixture host key; concurrent
        // workers subsequently read it without rewriting known_hosts.
        _ = try openSftpPassword(host: "127.0.0.1", port: port, username: user, password: Data("snake-fixture-only".utf8), knownHostsPath: hosts, acceptFingerprint: key.fingerprint)
        return { try openSftpPassword(host: "127.0.0.1", port: port, username: user, password: Data("snake-fixture-only".utf8), knownHostsPath: hosts, acceptFingerprint: nil) }
    }

    func testUploadDownloadTreesSHA256MD5AndUnavailable() async throws {
        for user in ["sha", "md5", "none", "restricted", "fish", "zsh", "probeerror", "hasherror"] {
            let expectsUnverified = ["none", "restricted", "probeerror", "hasherror"].contains(user)
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("snake-download-integration-\(UUID())")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            let make = try factory(user: user, root: root)
            let suite = "snake-download-test-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = ApplicationStore(databaseURL: root.appendingPathComponent("db"), userDefaults: defaults)
            store.multipartThresholdMB = 1; store.multipartConcurrency = 4
            let profile = SSHProfile(name: user, host: "127.0.0.1", username: user)
            let coordinator = LocalUploadCoordinator(profile: profile)
            coordinator.transferHandleFactory = make
            let tree = root.appendingPathComponent("中文 '文件夹 \\ $HOME `echo nope`")
            try fm.createDirectory(at: tree.appendingPathComponent("empty"), withIntermediateDirectories: true)
            let contents = [".hidden": Data("hidden".utf8), "zero": Data(), "large": Data(repeating: 0x2c, count: 2 * 1024 * 1024 + 17), "small": Data("small".utf8)]
            for (name, bytes) in contents { try bytes.write(to: tree.appendingPathComponent(name)) }
            let remote = "/home/\(user)/fixture-\(UUID())"
            let handle = try make()
            try handle.createDirectory(path: remote)
            do {
                coordinator.upload(urls: [tree], destinationRoot: remote, store: store)
                try await wait(coordinator)
                XCTAssertNil(coordinator.errorMessage)
                XCTAssertTrue(coordinator.records.allSatisfy { $0.state == .succeeded }, "\(coordinator.records.map { $0.verification.label })")
                XCTAssertEqual(coordinator.records.count, contents.count)
                for record in coordinator.records {
                    if expectsUnverified { XCTAssertTrue(record.verification.isWarning) }
                    else { XCTAssertEqual(record.verification, .passed(user == "md5" ? "MD5" : "SHA-256")) }
                }
            }
            let destination = root.appendingPathComponent("download")
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let folder = RemoteFile(name: tree.lastPathComponent, path: remote + "/" + tree.lastPathComponent, isDirectory: true)
            let link = RemoteFile(name: "fixture-link", path: "/home/\(user)/fixture-link", isDirectory: false, isSymbolicLink: true, linkTarget: "../missing")
            coordinator.download(files: [folder, folder, link], to: destination, store: store)
            try await wait(coordinator)
            XCTAssertNil(coordinator.errorMessage)
            let downloaded = coordinator.records.filter(\.isDownload)
            XCTAssertEqual(downloaded.count, contents.count + 3)
            XCTAssertTrue(downloaded.allSatisfy { $0.state == .succeeded }, "\(downloaded.map { $0.verification.label })")
            for (name, bytes) in contents { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(tree.lastPathComponent).appendingPathComponent(name)), bytes) }
            XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent(tree.lastPathComponent + "/empty").path))
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("fixture-link").path), "../missing")
            let fileRecords = downloaded.filter { contents[$0.fileName] != nil }
            XCTAssertTrue(fileRecords.allSatisfy { expectsUnverified ? $0.verification.isWarning : $0.verification == .passed(user == "md5" ? "MD5" : "SHA-256") })
        }
    }

    func testMismatchedDigestDoesNotPublishOrOverwrite() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("snake-corrupt-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let make = try factory(user: "corrupt", root: root)
        let profile = SSHProfile(name: "corrupt", host: "127.0.0.1", username: "corrupt")
        let suite = "snake-corrupt-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("db"), userDefaults: defaults)
        let coordinator = LocalUploadCoordinator(profile: profile); coordinator.transferHandleFactory = make
        let handle = try make()
        let remote = "/home/corrupt/fixture-\(UUID())"; try handle.createDirectory(path: remote)
        let file = root.appendingPathComponent("target"); try Data("old".utf8).write(to: file)
        try handle.upload(localPath: file.path, remotePath: remote + "/target")
        try Data("new".utf8).write(to: file)
        coordinator.upload(urls: [file], destinationRoot: remote, store: store)
        try await waitUntil { coordinator.pendingConflict != nil }
        coordinator.resolveConflict(.overwrite)
        try await wait(coordinator)
        XCTAssertEqual(coordinator.records.first?.state, .failed)
        let copy = root.appendingPathComponent("copy"); try handle.download(remotePath: remote + "/target", localPath: copy.path)
        XCTAssertEqual(try Data(contentsOf: copy), Data("old".utf8))
        let downloadRoot = root.appendingPathComponent("download"); try fm.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        let old = downloadRoot.appendingPathComponent("target"); try Data("keep".utf8).write(to: old)
        coordinator.download(files: [RemoteFile(name: "target", path: remote + "/target", isDirectory: false)], to: downloadRoot, store: store)
        try await waitUntil { coordinator.pendingDownloadConflict != nil }
        coordinator.resolveDownloadConflict(.overwrite)
        try await wait(coordinator)
        XCTAssertEqual(coordinator.records.first?.state, .failed)
        XCTAssertEqual(try Data(contentsOf: old), Data("keep".utf8))
    }

    func testRangePauseResumeCancelAndSourceMutation() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("snake-range-test-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let make = try factory(user: "sha", root: root)
        let source = root.appendingPathComponent("source")
        let data = Data(repeating: 0x71, count: 1024 * 1024 + 19)
        try data.write(to: source)
        let handle = try make()
        let remote = "/home/sha/range-\(UUID())"
        try handle.upload(localPath: source.path, remotePath: remote)
        let location = try DownloadLocation(root: root)
        let staging = try DownloadStaging(parent: location, size: UInt64(data.count))
        let control = CoreTransferControl(); control.pause()
        let task = Task.detached {
            try handle.downloadRange(remotePath: remote, localFd: staging.fd, offset: 0, length: UInt64(data.count), control: control, observer: NoopTransferObserver())
        }
        try await Task.sleep(for: .milliseconds(120))
        var first: UInt8 = 1
        XCTAssertEqual(pread(staging.fd, &first, 1, 0), 1)
        XCTAssertEqual(first, 0, "Paused worker must not write")
        control.resume(); try await task.value
        XCTAssertEqual(try TransferIntegrity.localDigest(fd: staging.fd, algorithm: "SHA-256", control: control), SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let cancelled = CoreTransferControl(); cancelled.cancel()
        XCTAssertThrowsError(try handle.downloadRange(remotePath: remote, localFd: staging.fd, offset: 0, length: 1, control: cancelled, observer: NoopTransferObserver()))
        let before = try handle.fileMetadata(path: remote)
        let changed = root.appendingPathComponent("changed"); try Data("short".utf8).write(to: changed)
        try handle.removeFile(path: remote)
        try handle.uploadControlled(localPath: changed.path, remotePath: remote, control: CoreTransferControl(), observer: NoopTransferObserver())
        XCTAssertNotEqual(try handle.fileMetadata(path: remote), before)
        XCTAssertThrowsError(try handle.downloadRange(remotePath: remote, localFd: staging.fd, offset: 0, length: UInt64(data.count), control: CoreTransferControl(), observer: NoopTransferObserver()))
    }

    private func wait(_ coordinator: LocalUploadCoordinator) async throws { try await waitUntil { !coordinator.isPreparing } }
    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while !predicate() {
            if Date() > deadline { XCTFail("Transfer fixture timed out"); throw TransferIntegrity.error("测试超时") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

private final class NoopTransferObserver: CoreTransferObserver, @unchecked Sendable {
    func onProgress(completedBytes: UInt64, totalBytes: UInt64) {}
}
