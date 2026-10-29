import Foundation
import XCTest
@testable import SnakeApp

/// The askpass broker must hand the secret only to the SnakeMountHelper running in
/// askpass mode beneath the authorised mount process, and only for credential prompts.
final class MountAskpassTests: XCTestCase {
    private let secret = Data("s3cret pass,word".utf8)

    private func helperURL() throws -> URL {
        let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("SnakeMountHelper")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw XCTSkip("Build SnakeMountHelper first: swift build --product SnakeMountHelper")
        }
        return url
    }

    /// Runs the helper as ssh would run SSH_ASKPASS: prompt in argv[1], answer on stdout.
    private func askpass(_ helper: URL, socket: String, prompt: String) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = helper
        process.arguments = [prompt]
        process.environment = ["SNAKE_ASKPASS_SOCKET": socket]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    func testAuthorisedAskpassReceivesTheSecretForAPasswordPrompt() throws {
        let helper = try helperURL()
        let broker = try MountAskpassBroker(secret: secret, helperPath: helper.path)
        defer { broker.close() }
        // The helper is our direct child here, so this process stands in for sshfs.
        broker.authorize(mountPID: getpid())
        let result = try askpass(helper, socket: broker.socketPath, prompt: "root@10.0.0.8's password: ")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, secret + Data("\n".utf8))
        // reconnect asks again while the mount is alive.
        XCTAssertEqual(try askpass(helper, socket: broker.socketPath, prompt: "Enter passphrase for key: ").output,
                       secret + Data("\n".utf8))
    }

    func testNonCredentialPromptsAndForeignAncestorsGetNothing() throws {
        let helper = try helperURL()
        let broker = try MountAskpassBroker(secret: secret, helperPath: helper.path)
        defer { broker.close() }
        broker.authorize(mountPID: getpid())
        let confirmation = try askpass(helper, socket: broker.socketPath,
                                       prompt: "Are you sure you want to continue connecting (yes/no)?")
        XCTAssertNotEqual(confirmation.status, 0)
        XCTAssertTrue(confirmation.output.isEmpty)

        // A helper that does not descend from the authorised mount is refused.
        broker.authorize(mountPID: Int32.max)
        let foreign = try askpass(helper, socket: broker.socketPath, prompt: "password: ")
        XCTAssertNotEqual(foreign.status, 0)
        XCTAssertTrue(foreign.output.isEmpty)
    }

    /// sshfs double-forks ssh, so askpass is parented to launchd; only the process
    /// group still ties it to the mount.
    func testOrphanedAskpassInTheMountGroupReceivesTheSecret() throws {
        let helper = try helperURL()
        let broker = try MountAskpassBroker(secret: secret, helperPath: helper.path)
        defer { broker.close() }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The subshell outlives its parent, so the helper ends up parented to launchd.
        shell.arguments = ["-c", "( sleep 0.5; exec \"$0\" 'root@host'\\''s password: ' ) &", helper.path]
        shell.environment = ["SNAKE_ASKPASS_SOCKET": broker.socketPath]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let group = getpgid(shell.processIdentifier)
        XCTAssertGreaterThan(group, 0)
        broker.authorize(mountPID: group)
        shell.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(data, secret + Data("\n".utf8))
    }

    func testOtherExecutablesAndClosedBrokersGetNothing() throws {
        let helper = try helperURL()
        let broker = try MountAskpassBroker(secret: secret, helperPath: helper.path)
        broker.authorize(mountPID: getppid())
        // This test process is not the helper binary, even though it descends from its parent.
        XCTAssertTrue(try readReply(from: broker.socketPath).isEmpty)

        let path = broker.socketPath
        broker.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: (path as NSString).deletingLastPathComponent))
    }

    func testPasswordSessionsDisablePublicKeysAndNeverNameAKey() {
        let options = MountOperations.sshOptions(knownHostsPath: "/tmp/known_hosts", privateKeyPath: nil)
            .split(separator: ",").map(String.init)
        XCTAssertTrue(options.contains("PubkeyAuthentication=no"))
        XCTAssertFalse(options.contains { $0.hasPrefix("IdentityFile=") })
        XCTAssertTrue(options.contains("NumberOfPasswordPrompts=1"))
        XCTAssertFalse(options.contains { $0 != "NumberOfPasswordPrompts=1" && $0.localizedCaseInsensitiveContains("password") })
    }

    /// Like sshfs's ssh and mount_macfuse: an orphan left in the helper's group
    /// after the leader exits must still be found and ended.
    func testFailedMountGroupCleanupEndsOrphanedMembers() throws {
        let leader = Process()
        leader.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        leader.arguments = ["-e", "setpgrp(0, 0); if (fork() == 0) { sleep 30; exit 0 } exit 0"]
        try leader.run()
        let group = leader.processIdentifier
        leader.waitUntilExit()
        let orphans = MountOperations.processes(inGroup: group)
        XCTAssertEqual(orphans.count, 1)
        MountOperations.terminateProcessGroup(group)
        let deadline = Date().addingTimeInterval(3)
        while !MountOperations.processes(inGroup: group).isEmpty, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(MountOperations.processes(inGroup: group).isEmpty)
        XCTAssertTrue(MountOperations.processes(inGroup: 1).isEmpty, "launchd's group is never targeted")
    }

    private func readReply(from path: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 ? Data(buffer[0..<count]) : Data()
    }
}
