import Foundation
import XCTest
@testable import SnakeApp

final class MountOperationsTests: XCTestCase {
    func testMountReadinessDoesNotWaitForFilesystemProcessToExit() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        XCTAssertTrue(MountOperations.waitForMount(process: process, timeout: 0.5, isMounted: { true }))
        XCTAssertTrue(process.isRunning)
    }

    func testSuccessfulExitWithoutMountIsNotMounted() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertFalse(MountOperations.waitForMount(process: process, timeout: 0.5, isMounted: { false }))
    }

    @MainActor
    func testLoopbackMountLifecycleAndFinderVolumeName() async throws {
        guard ProcessInfo.processInfo.environment["SNAKE_MOUNT_INTEGRATION"] == "1" else {
            throw XCTSkip("Set SNAKE_MOUNT_INTEGRATION=1 for the local macFUSE fixture")
        }
        let manager = FileManager.default
        let project = URL(fileURLWithPath: manager.currentDirectoryPath)
        let key = project.appendingPathComponent("ssh_test/client_key")
        let bookmark = try key.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = UUID().uuidString
        let accessURL = manager.temporaryDirectory.appendingPathComponent("snake-mount-link-\(id)")
        let mountPath = "/Users/Shared/.SnakeMounts/integration-\(id)"
        let mapping = MountMapping(name: "挂载测试", remotePath: project.appendingPathComponent("ssh_test").path,
                                   userAccessPath: accessURL.path, managedMountPath: mountPath)
        let profile = SSHProfile(name: "本机连接", host: "127.0.0.1", port: 49326, username: "xiaoyong",
                                 authMethod: .privateKey, privateKeyBookmark: bookmark)
        defer {
            if MountOperations.mountedPaths().contains(mountPath) { _ = MountOperations.unmount(mapping: mapping) }
            if !MountOperations.mountedPaths().contains(mountPath) {
                try? manager.removeItem(at: accessURL)
                try? manager.removeItem(atPath: mountPath)
            }
        }
        let result = MountOperations.mount(mapping: mapping, profile: profile)
        XCTAssertEqual(result.state, .mounted, result.message ?? "")
        guard result.state == .mounted else { return }
        XCTAssertTrue(MountOperations.mountedPaths().contains(mountPath))
        XCTAssertTrue(manager.fileExists(atPath: accessURL.appendingPathComponent("sshd_config").path))
        let mountedURL = URL(fileURLWithPath: mountPath, isDirectory: true)
        let name = try mountedURL.resourceValues(forKeys: [.volumeNameKey]).volumeName
        XCTAssertEqual(name, "挂载测试 · 本机连接")
        let suite = "com.snake.tests.mount-quit.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let storeRoot = manager.temporaryDirectory.appendingPathComponent("snake-mount-store-\(id)")
        try manager.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: storeRoot)
        }
        let store = ApplicationStore(databaseURL: storeRoot.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        // Deliberately save an idle mapping: quit must consult the actual mount table.
        try store.save(mapping: mapping)
        let failures = await store.prepareForTermination()
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertTrue(store.isPreparingToQuit)
        XCTAssertFalse(MountOperations.mountedPaths().contains(mountPath))
    }

    @MainActor
    func testQuitIsCancelledWhenMountIsBusyOrMountTableCannotBeRead() async throws {
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-quit-test-\(id)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "com.snake.tests.quit.\(id)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = ApplicationStore(databaseURL: root.appendingPathComponent("test.sqlite3"), userDefaults: defaults)
        let path = "/Users/Shared/.SnakeMounts/quit-test-\(id)"
        let mapping = MountMapping(name: "忙碌磁盘", remotePath: "/remote", userAccessPath: root.appendingPathComponent("link").path,
                                   managedMountPath: path)
        try store.save(mapping: mapping)
        let busy = await store.prepareForTermination(mountedPaths: { [path, "/Volumes/unrelated"] }, unmount: { target in
            XCTAssertEqual(target.id, mapping.id)
            return .init(state: .failed, message: "Resource busy")
        })
        XCTAssertEqual(busy.count, 1)
        XCTAssertTrue(busy[0].contains("忙碌磁盘"))
        XCTAssertTrue(busy[0].contains("挂载点：\(path)"))
        XCTAssertTrue(busy[0].contains("原因：Resource busy"))
        XCTAssertFalse(store.isPreparingToQuit)
        let unreadable = await store.prepareForTermination(mountedPaths: { throw CocoaError(.fileReadUnknown) }, unmount: { _ in
            XCTFail("An unreadable mount table must not trigger unmount")
            return .init(state: .idle, message: nil)
        })
        XCTAssertFalse(unreadable.isEmpty)
        XCTAssertFalse(store.isPreparingToQuit)
    }

    func testMountPathsSurviveOpenSSHOptionParsing() throws {
        let knownHosts = "/Users/test/Library/Application Support/Snake/known_hosts"
        let privateKey = "/Users/test/SSH Keys/测试 key"
        let options = MountOperations.sshOptions(knownHostsPath: knownHosts, privateKeyPath: privateKey)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        // -G parses configuration and exits without making a network connection.
        process.arguments = ["-G", "-F", "/dev/null"]
        for option in options.split(separator: ",") where option != "reconnect" {
            process.arguments?.append(contentsOf: ["-o", String(option)])
        }
        process.arguments?.append("127.0.0.1")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let configuration = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertTrue(configuration.contains("userknownhostsfile \(knownHosts)"))
        XCTAssertTrue(configuration.contains("identityfile \(privateKey)"))
        XCTAssertTrue(configuration.contains("stricthostkeychecking true"))
        XCTAssertTrue(configuration.contains("identitiesonly yes"))
    }
}
