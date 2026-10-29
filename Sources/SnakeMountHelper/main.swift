import Foundation
import Darwin

private struct MountRequest: Decodable {
    let executable: String
    let arguments: [String]
    let mountPoint: String
    let volumeName: String
    let askpassSocket: String?
    let dryRun: Bool
}

private enum HelperError: LocalizedError {
    case invalidRequest
    case unsupportedExecutable
    case unmanagedMountPoint
    case unsafeArgument

    var errorDescription: String? {
        switch self {
        case .invalidRequest: "挂载请求格式无效。"
        case .unsupportedExecutable: "sshfs 可执行文件不在允许列表中。"
        case .unmanagedMountPoint: "挂载点不在 Snake 受管目录中。"
        case .unsafeArgument: "挂载参数包含不安全内容。"
        }
    }
}

/// The signed helper receives only a validated, non-secret mount request from the app.
/// Secret material is intentionally never accepted through arguments or environment variables.
///
/// For a password (or key passphrase) the request names an askpass socket. The helper
/// then points `SSH_ASKPASS` at itself; ssh runs it again in askpass mode, and that
/// process fetches the secret from the app, which only answers descendants of this
/// mount's sshfs that run this binary.
@main
enum SnakeMountHelper {
    static let askpassSocketVariable = "SNAKE_ASKPASS_SOCKET"

    static func main() {
        if let socket = ProcessInfo.processInfo.environment[askpassSocketVariable] {
            runAskpass(socketPath: socket)
        }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        do {
            let request = try JSONDecoder().decode(MountRequest.self, from: input)
            try validate(request)
            if request.dryRun {
                Foundation.exit(0)
            }
            // Lead a new process group: sshfs double-forks ssh away from itself, but
            // ssh and its askpass child stay in this group, which the app checks,
            // and the app can end the whole group if the mount fails.
            guard setpgid(0, 0) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            unsetenv("SSH_ASKPASS")
            unsetenv("SSH_ASKPASS_REQUIRE")
            unsetenv(askpassSocketVariable)
            if let socket = request.askpassSocket {
                guard let selfPath = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                    throw HelperError.invalidRequest
                }
                setenv("SSH_ASKPASS", selfPath, 1)
                setenv("SSH_ASKPASS_REQUIRE", "force", 1)
                setenv(askpassSocketVariable, socket, 1)
            }

            // Keep one foreground process that the app can observe and terminate.
            // FUSE parses commas/backslashes itself, not shell quoting.
            let volumeName = request.volumeName.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ",", with: "\\,")
            let arguments = [request.executable, "-f"] + request.arguments + ["-o", "volname=\(volumeName)"]
            let pointers = arguments.map { strdup($0) } + [nil]
            defer { pointers.forEach { free($0) } }
            pointers.withUnsafeBufferPointer { buffer in
                _ = execv(request.executable, buffer.baseAddress!)
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        } catch {
            fputs("SnakeMountHelper: \(error.localizedDescription)\n", stderr)
            Foundation.exit(64)
        }
    }

    /// Askpass mode: ssh passes the prompt as argv[1] and reads the answer from stdout.
    private static func runAskpass(socketPath: String) -> Never {
        let prompt = CommandLine.arguments.dropFirst().first?.lowercased() ?? ""
        // Only answer credential prompts, never e.g. a host-key confirmation.
        guard prompt.contains("password") || prompt.contains("passphrase"),
              isTrustedSocket(socketPath) else { Foundation.exit(1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { Foundation.exit(1) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Foundation.exit(1) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { Foundation.exit(1) }
        var answer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while answer.count < 64 * 1024 {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            answer.append(contentsOf: chunk[0..<count])
        }
        close(fd)
        for index in chunk.indices { chunk[index] = 0 }
        // An empty reply means the app refused this process.
        guard !answer.isEmpty else { Foundation.exit(1) }
        var written = 0
        while written < answer.count {
            let count = answer.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress! + written, answer.count - written) }
            guard count > 0 else { break }
            written += count
        }
        for index in answer.indices { answer[index] = 0 }
        Foundation.exit(written == answer.count ? 0 : 1)
    }

    /// The broker socket lives in this user's private temporary directory.
    private static func isTrustedSocket(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              url.lastPathComponent == "s",
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("snake-askpass-") else { return false }
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK && info.st_uid == getuid()
    }

    private static func validate(_ request: MountRequest) throws {
        if let socket = request.askpassSocket, !isTrustedSocket(socket) {
            throw HelperError.unsafeArgument
        }
        guard !request.volumeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.volumeName.utf8.count <= 255,
              !request.volumeName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !request.volumeName.contains("/") else {
            throw HelperError.unsafeArgument
        }
        let permittedExecutables = ["/opt/homebrew/bin/sshfs", "/usr/local/bin/sshfs"]
        guard permittedExecutables.contains(request.executable) else {
            throw HelperError.unsupportedExecutable
        }
        let root = URL(fileURLWithPath: "/Users/Shared/.SnakeMounts", isDirectory: true)
            .standardizedFileURL.path + "/"
        let mountPoint = URL(fileURLWithPath: request.mountPoint, isDirectory: true)
            .standardizedFileURL.path
        guard mountPoint.hasPrefix(root) else {
            throw HelperError.unmanagedMountPoint
        }
        guard request.arguments.count == 6,
              request.arguments[1] == mountPoint,
              request.arguments[2] == "-p",
              let port = UInt16(request.arguments[3]), port > 0,
              request.arguments[4] == "-o",
              request.arguments[0].contains("@"),
              request.arguments[0].contains(":") else {
            throw HelperError.unsafeArgument
        }
        // The one permitted option naming passwords limits ssh to a single try.
        let passwordPromptLimit = "NumberOfPasswordPrompts=1"
        guard !request.arguments.contains(where: { candidate in
            let argument = candidate.replacingOccurrences(of: passwordPromptLimit, with: "")
            return argument.localizedCaseInsensitiveContains("password") ||
            argument.localizedCaseInsensitiveContains("passphrase") ||
            argument.contains("\n") || argument.contains("\0")
        }) else {
            throw HelperError.unsafeArgument
        }
        let allowedExact = Set(["reconnect", "StrictHostKeyChecking=yes", "IdentitiesOnly=yes", "PubkeyAuthentication=no", passwordPromptLimit])
        let allowedPrefixes = [
            "ServerAliveInterval=",
            "ServerAliveCountMax=",
            "IdentityFile=",
            "UserKnownHostsFile="
        ]
        let options = request.arguments[5].split(separator: ",").map(String.init)
        guard !options.isEmpty,
              options.allSatisfy({ option in
                  allowedExact.contains(option) || allowedPrefixes.contains(where: option.hasPrefix)
              }),
              !options.contains(where: {
                  $0.localizedCaseInsensitiveContains("ssh_command") ||
                  $0.localizedCaseInsensitiveContains("allow_other")
              }) else {
            throw HelperError.unsafeArgument
        }
    }
}
