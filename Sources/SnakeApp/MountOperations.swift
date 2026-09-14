import AppKit
import Foundation
import Darwin

struct MountOperationResult: Sendable {
    let state: MountState
    let message: String?
}

enum MountOperations {
    private static let processes = MountProcessRegistry()

    static func mount(mapping: MountMapping, profile: SSHProfile) -> MountOperationResult {
        let manager = FileManager.default
        guard manager.fileExists(atPath: "/Library/Filesystems/macfuse.fs") else {
            return .init(state: .unavailable, message: L10n.text("未检测到 macFUSE，请安装后重新检测。"))
        }
        guard let sshfs = ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs"]
            .first(where: manager.isExecutableFile(atPath:)) else {
            return .init(state: .unavailable, message: L10n.text("未检测到 sshfs，请安装后重新检测。"))
        }
        guard profile.authMethod == .privateKey, let bookmark = profile.privateKeyBookmark else {
            return .init(
                state: .failed,
                message: L10n.text("密码型 SSHFS 需要受管 SSH_ASKPASS 通道；当前版本不会通过参数或环境变量传递密码。")
            )
        }

        let mountURL = URL(fileURLWithPath: mapping.managedMountPath, isDirectory: true).standardizedFileURL
        let managedRoot = URL(fileURLWithPath: "/Users/Shared/.SnakeMounts", isDirectory: true).standardizedFileURL.path + "/"
        guard mountURL.path.hasPrefix(managedRoot) else {
            return .init(state: .failed, message: L10n.text("挂载点不在 Snake 受管目录中。"))
        }

        var stale = false
        guard let keyURL = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale, keyURL.startAccessingSecurityScopedResource() else {
            return .init(state: .failed, message: L10n.text("私钥访问授权已失效，请编辑会话并重新选择私钥。"))
        }
        defer { keyURL.stopAccessingSecurityScopedResource() }

        do {
            let mounted = try checkedMountedPaths()
            if mounted.contains(mountURL.path) {
                guard processes.contains(mountURL.path) else {
                    return .init(state: .failed, message: L10n.text("目标目录已被其他挂载占用，请先安全卸载。"))
                }
                try ensureUserLink(mapping.userAccessPath, pointsTo: mountURL.path)
                return .init(state: .external, message: nil)
            }
            try ManagedMountPath.validateTarget(mountURL.path, mounted: mounted)
            try manager.createDirectory(at: mountURL, withIntermediateDirectories: true)
            let source = "\(profile.username)@\(profile.host):\(mapping.remotePath)"
            let options = sshOptions(knownHostsPath: knownHostsPath, privateKeyPath: keyURL.path)
            let arguments = [source, mountURL.path, "-p", String(profile.port), "-o", options]
            let request = MountHelperRequest(
                executable: sshfs,
                arguments: arguments,
                mountPoint: mountURL.path,
                volumeName: volumeName(mappingName: mapping.name, connectionName: profile.name),
                dryRun: false
            )
            let result = try runHelper(request)
            guard result.status == 0 else {
                return .init(state: .failed, message: result.error.isEmpty ? L10n.text("sshfs 挂载失败。") : result.error)
            }
            do {
                try ensureUserLink(mapping.userAccessPath, pointsTo: mountURL.path)
            } catch {
                let cleanup = unmount(mapping: mapping)
                return .init(state: cleanup.state == .idle ? .failed : .external,
                             message: L10n.format("Finder 入口创建失败：%@", error.localizedDescription) +
                                (cleanup.state == .idle ? L10n.text("；已撤销挂载。") : L10n.text("；磁盘仍已挂载，请安全卸载后修改本地入口。")))
            }
            return .init(state: .mounted, message: nil)
        } catch {
            return .init(state: .failed, message: error.localizedDescription)
        }
    }

    static func volumeName(mappingName: String, connectionName: String) -> String {
        "\(mappingName) · \(connectionName)".replacingOccurrences(of: "/", with: "∕")
    }

    static func sshOptions(knownHostsPath: String, privateKeyPath: String) -> String {
        // Process protects argv boundaries, but OpenSSH parses each -o value again.
        // Keep the quotes in the argument so spaces remain part of the filename.
        func quotedPath(_ path: String) -> String {
            "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        return [
            "reconnect",
            "ServerAliveInterval=30",
            "ServerAliveCountMax=3",
            "StrictHostKeyChecking=yes",
            "UserKnownHostsFile=\(quotedPath(knownHostsPath))",
            "IdentityFile=\(quotedPath(privateKeyPath))",
            "IdentitiesOnly=yes"
        ].joined(separator: ",")
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
        guard isManagedMountPath(mapping.managedMountPath) else {
            return .init(state: .failed, message: L10n.text("挂载点不在 Snake 受管目录中。"))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = [mapping.managedMountPath]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            process.waitUntilExit()
            return process.terminationStatus == 0 && !mountedPaths().contains(mapping.managedMountPath)
                ? .init(state: .idle, message: nil)
                : .init(state: .failed, message: error.isEmpty ? L10n.text("安全卸载失败，挂载点可能正被占用。") : error)
        } catch {
            return .init(state: .failed, message: error.localizedDescription)
        }
    }

    @MainActor
    static func reveal(mapping: MountMapping) async throws {
        let mounted = try await Task.detached(priority: .utility) { try checkedMountedPaths() }.value
        guard mounted.contains(mapping.managedMountPath) else { throw MountOperationError.notMounted }
        let directory = URL(fileURLWithPath: mapping.managedMountPath, isDirectory: true)
        let workspace = NSWorkspace.shared
        // Honor macOS's chosen file viewer, including QSpace Pro. Send the actual
        // directory instead of a symlink that third-party viewers may open as a file.
        let viewerID = UserDefaults.standard.string(forKey: "NSFileViewer")
            ?? (UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["NSFileViewer"] as? String)
        let appURL = viewerID.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
            ?? workspace.urlForApplication(toOpen: directory)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.finder")
        guard let appURL else { throw CocoaError(.fileNoSuchFile) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await workspace.open([directory], withApplicationAt: appURL, configuration: configuration)
    }

    static func removeMappingEntry(_ mapping: MountMapping) -> MountOperationResult {
        do {
            guard isManagedMountPath(mapping.managedMountPath) else {
                return .init(state: .failed, message: L10n.text("挂载点不在 Snake 受管目录中。"))
            }
            if try checkedMountedPaths().contains(mapping.managedMountPath) {
                let result = unmount(mapping: mapping)
                guard result.state == .idle else { return result }
            }
            guard try !checkedMountedPaths().contains(mapping.managedMountPath) else {
                return .init(state: .failed, message: L10n.text("目录仍已挂载，未删除映射。"))
            }
            let entry = URL(fileURLWithPath: (mapping.userAccessPath as NSString).expandingTildeInPath)
            if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path) {
                let target = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                    : entry.deletingLastPathComponent().appendingPathComponent(destination)
                if target.standardizedFileURL.path == URL(fileURLWithPath: mapping.managedMountPath).standardizedFileURL.path {
                    // unlink removes only the link itself, never traverses directories.
                    guard unlink(entry.path) == 0 || errno == ENOENT else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
            return .init(state: .idle, message: nil)
        } catch {
            return .init(state: .failed, message: error.localizedDescription)
        }
    }

    static func mountedPaths() -> Set<String> {
        (try? checkedMountedPaths()) ?? []
    }

    static func isManagedMountPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix("/Users/Shared/.SnakeMounts/")
    }

    static func checkedMountedPaths() throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
        return Set(text.split(separator: "\n").compactMap { line in
            guard let range = line.range(of: " on "),
                  let end = line[range.upperBound...].range(of: " (") else { return nil }
            return String(line[range.upperBound..<end.lowerBound])
        })
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
        let logsURL = URL(fileURLWithPath: knownHostsPath).deletingLastPathComponent().appendingPathComponent("MountLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        let logURL = logsURL.appendingPathComponent("\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        process.standardInput = inputPipe
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { finished in
            processes.remove(finished, for: request.mountPoint)
        }
        try process.run()
        processes.insert(process, for: request.mountPoint)
        do {
            inputPipe.fileHandleForWriting.write(try JSONEncoder().encode(request))
            try inputPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
        if waitForMount(process: process, isMounted: { mountedPaths().contains(request.mountPoint) }) {
            return (0, "")
        }
        let wasRunning = process.isRunning
        if wasRunning { process.terminate() }
        let details = (try? String(contentsOf: logURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = wasRunning ? L10n.text("等待挂载超时，已停止挂载进程。") : L10n.text("挂载进程已退出，系统未建立挂载。")
        return (1, L10n.format("%@%@\n日志：%@", summary, details.isEmpty ? "" : "\n" + details, logURL.path))
    }

    static func waitForMount(process: Process, timeout: TimeInterval = 20, isMounted: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if isMounted(), process.isRunning { return true }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
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

private struct MountHelperRequest: Encodable, Sendable {
    let executable: String
    let arguments: [String]
    let mountPoint: String
    let volumeName: String
    let dryRun: Bool
}

private final class MountProcessRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Process] = [:]

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running[path]?.isRunning == true
    }

    func insert(_ process: Process, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning { running[path] = process }
    }

    func remove(_ process: Process, for path: String) {
        lock.lock()
        defer { lock.unlock() }
        if running[path] === process { running.removeValue(forKey: path) }
    }
}

private enum MountOperationError: LocalizedError {
    case helperUnavailable
    case userPathOccupied
    case notMounted

    var errorDescription: String? {
        switch self {
        case .helperUnavailable: L10n.text("未找到 SnakeMountHelper，请重新构建应用。")
        case .userPathOccupied: L10n.text("本地访问目录已存在且不是指向受管挂载点的软链接。")
        case .notMounted: L10n.text("目录尚未挂载，请先挂载后再打开。")
        }
    }
}
