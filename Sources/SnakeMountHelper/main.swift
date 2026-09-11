import Foundation

private struct MountRequest: Decodable {
    let executable: String
    let arguments: [String]
    let mountPoint: String
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
@main
enum SnakeMountHelper {
    static func main() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        do {
            let request = try JSONDecoder().decode(MountRequest.self, from: input)
            try validate(request)
            if request.dryRun {
                Foundation.exit(0)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: request.executable)
            process.arguments = request.arguments
            try process.run()
            process.waitUntilExit()
            Foundation.exit(process.terminationStatus)
        } catch {
            fputs("SnakeMountHelper: \(error.localizedDescription)\n", stderr)
            Foundation.exit(64)
        }
    }

    private static func validate(_ request: MountRequest) throws {
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
        guard !request.arguments.contains(where: { argument in
            argument.localizedCaseInsensitiveContains("password") ||
            argument.localizedCaseInsensitiveContains("passphrase") ||
            argument.contains("\n") || argument.contains("\0")
        }) else {
            throw HelperError.unsafeArgument
        }
        let allowedExact = Set(["reconnect", "StrictHostKeyChecking=yes", "IdentitiesOnly=yes"])
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
