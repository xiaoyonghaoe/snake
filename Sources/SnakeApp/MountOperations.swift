import AppKit
import Foundation

struct MountOperationResult: Sendable {
    let state: MountState
    let message: String?
}

enum MountOperations {
    static func mount(mapping: MountMapping, profile: SSHProfile) -> MountOperationResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: "/Library/Filesystems/macfuse.fs") else {
            return .init(state: .unavailable, message: "未检测到 macFUSE，请安装后重新检测。")
        }
        guard let sshfs = ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs"]
            .first(where: manager.isExecutableFile(atPath:)) else {
            return .init(state: .unavailable, message: "未检测到 sshfs，请安装后重新检测。")
        }
        guard profile.authMethod == .privateKey, let bookmark = profile.privateKeyBookmark else {
            return .init(
                state: .failed,
                message: "密码型 SSHFS 需要受管 SSH_ASKPASS 通道；当前版本不会通过参数或环境变量传递密码。"
            )
        }

        let mountURL = URL(fileURLWithPath: mapping.managedMountPath, isDirectory: true).standardizedFileURL
        let managedRoot = URL(fileURLWithPath: "/Users/Shared/.SnakeMounts", isDirectory: true).standardizedFileURL.path + "/"
        guard mountURL.path.hasPrefix(managedRoot) else {
            return .init(state: .failed, message: "挂载点不在 Snake 受管目录中。")
        }

        var stale = false
        guard let keyURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale, keyURL.startAccessingSecurityScopedResource() else {
            return .init(state: .failed, message: "私钥访问授权已失效，请编辑会话并重新选择私钥。")
        }
        defer { keyURL.stopAccessingSecurityScopedResource() }

        do {
            try manager.createDirectory(at: mountURL, withIntermediateDirectories: true)
            let source = "\(profile.username)@\(profile.host):\(mapping.remotePath)"
            let options = [
                "reconnect",
                "ServerAliveInterval=30",
                "ServerAliveCountMax=3",
                "StrictHostKeyChecking=yes",
                "UserKnownHostsFile=\(knownHostsPath)",
                "IdentityFile=\(keyURL.path)",
                "IdentitiesOnly=yes"
            ].joined(separator: ",")
            let arguments = [source, mountURL.path, "-p", String(profile.port), "-o", options]
            let request = MountHelperRequest(
                executable: sshfs,
                arguments: arguments,
                mountPoint: mountURL.path,
                dryRun: false
            )
            let result = try runHelper(request)
            guard result.status == 0 else {
                return .init(state: .failed, message: result.error.isEmpty ? "sshfs 挂载失败。" : result.error)
            }
            try ensureUserLink(mapping.userAccessPath, pointsTo: mountURL.path)
            return .init(state: .mounted, message: nil)
        } catch {
            return .init(state: .failed, message: error.localizedDescription)
        }
    }

    private static var knownHostsPath: String {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Snake/known_hosts").path
    }

    static func unmount(mapping: MountMapping) -> MountOperationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["unmount", mapping.managedMountPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0
                ? .init(state: .idle, message: nil)
                : .init(state: .failed, message: error.isEmpty ? "安全卸载失败，挂载点可能正被占用。" : error)
        } catch {
            return .init(state: .failed, message: error.localizedDescription)
        }
    }

    static func reveal(mapping: MountMapping) {
        let expanded = (mapping.userAccessPath as NSString).expandingTildeInPath
        NSWorkspace.shared.open(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    static func mountedPaths() -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return Set(text.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: " on "),
                      let end = line[range.upperBound...].range(of: " (") else { return nil }
                return String(line[range.upperBound..<end.lowerBound])
            })
        } catch {
            return []
        }
    }

    private static func runHelper(_ request: MountHelperRequest) throws -> (status: Int32, error: String) {
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [
            executableDirectory?.appendingPathComponent("SnakeMountHelper"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/debug/SnakeMountHelper")
        ].compactMap { $0 }
        guard let helperURL = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MountOperationError.helperUnavailable
        }

        let process = Process()
        process.executableURL = helperURL
        let inputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardError = errorPipe
        try process.run()
        inputPipe.fileHandleForWriting.write(try JSONEncoder().encode(request))
        try inputPipe.fileHandleForWriting.close()
        process.waitUntilExit()
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, error)
    }

    private static func ensureUserLink(_ path: String, pointsTo destination: String) throws {
        let manager = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        let parent = (expanded as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if manager.fileExists(atPath: expanded) {
            let values = try URL(fileURLWithPath: expanded).resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink == true,
                  try manager.destinationOfSymbolicLink(atPath: expanded) == destination else {
                throw MountOperationError.userPathOccupied
            }
            return
        }
        try manager.createSymbolicLink(atPath: expanded, withDestinationPath: destination)
    }
}

private struct MountHelperRequest: Encodable {
    let executable: String
    let arguments: [String]
    let mountPoint: String
    let dryRun: Bool
}

private enum MountOperationError: LocalizedError {
    case helperUnavailable
    case userPathOccupied

    var errorDescription: String? {
        switch self {
        case .helperUnavailable: "未找到 SnakeMountHelper，请重新构建应用。"
        case .userPathOccupied: "本地访问目录已存在且不是指向受管挂载点的软链接。"
        }
    }
}
