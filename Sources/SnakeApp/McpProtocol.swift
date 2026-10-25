import CryptoKit
import Foundation
import SnakeCoreBindings

// Snake's MCP endpoint speaks the Streamable HTTP transport with plain JSON
// responses: every request is one POST to /mcp and gets one JSON reply. This
// file holds the network-free parts so they can be tested without sockets.

struct McpHTTPRequest: Equatable {
    var method: String
    var path: String
    /// Header names are lowercased.
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct McpHTTPResponse: Equatable {
    var status: Int
    var headers: [(String, String)] = []
    var body = Data()

    static func == (lhs: McpHTTPResponse, rhs: McpHTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body
            && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    static func json(_ status: Int, _ object: Any, headers: [(String, String)] = []) -> McpHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return McpHTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: body)
    }

    static func plain(_ status: Int, _ text: String, headers: [(String, String)] = []) -> McpHTTPResponse {
        McpHTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + headers, body: Data(text.utf8))
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}

enum McpHTTPParser {
    static let headerLimit = 16 * 1_024
    static let bodyLimit = 1_024 * 1_024

    enum Result: Equatable {
        case incomplete
        case complete(McpHTTPRequest)
        case invalid(McpHTTPResponse)
    }

    static func parse(_ buffer: Data) -> Result {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > headerLimit ? .invalid(.plain(431, "header too large")) : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= headerLimit,
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
            return .invalid(.plain(431, "header too large"))
        }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid(.plain(400, "bad request line")) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(.plain(400, "bad header")) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(.plain(400, "bad header")) }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        if headers["transfer-encoding"] != nil { return .invalid(.plain(400, "chunked bodies are not supported")) }
        let length: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), parsed >= 0 else { return .invalid(.plain(400, "bad content length")) }
            length = parsed
        } else {
            length = 0
        }
        guard length <= bodyLimit else { return .invalid(.plain(413, "request body too large")) }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let path = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        return .complete(McpHTTPRequest(
            method: String(parts[0]).uppercased(), path: path, headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + length)])
        ))
    }
}

// MARK: - Backend

struct McpGrant: Equatable, Sendable {
    let tokenID: String
    let tokenName: String
    let profileIDs: Set<UUID>
}

struct McpCommandRequest: Sendable {
    let profile: SSHProfile
    let command: String
    let cwd: String?
    let timeoutSeconds: Int
}

/// What the protocol layer needs from the app. Tests substitute a fake.
@MainActor
protocol McpBackend: AnyObject {
    /// Looks up an active token by its SHA-256 hex digest and records the use.
    func grant(tokenHash: String) -> McpGrant?
    func profiles() -> [SSHProfile]
    func groupName(for profile: SSHProfile) -> String?
    func run(_ request: McpCommandRequest) async throws -> CoreCommandOutput
    func recordAudit(_ record: CoreMcpAuditRecord)
    func finishAudit(id: String, result: CoreMcpAuditResult)
}

// MARK: - Handler

@MainActor
final class McpRequestHandler {
    nonisolated static let protocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    nonisolated static let maxCommandBytes = 16 * 1_024
    nonisolated static let maxOutputBytes = 256 * 1_024
    nonisolated static let defaultTimeout = 60
    nonisolated static let maxTimeout = 600
    nonisolated static let maxConcurrentCommands = 8
    private static let maxSessions = 256

    weak var backend: McpBackend?
    let port: Int
    private var clientNames: [String: String] = [:]
    private var sessionOrder: [String] = []
    private var runningCommands = 0
    var now: () -> Date = Date.init

    init(backend: McpBackend, port: Int) {
        self.backend = backend
        self.port = port
    }

    nonisolated static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func handle(_ request: McpHTTPRequest) async -> McpHTTPResponse {
        if let rejection = validateOrigin(request) { return rejection }
        guard request.path == "/mcp" else { return .plain(404, "not found") }
        switch request.method {
        case "POST":
            return await handlePost(request)
        case "DELETE":
            if let session = request.header("mcp-session-id") { forget(session: session) }
            return McpHTTPResponse(status: 204)
        default:
            // No server-initiated stream: replies always travel on the POST.
            return .plain(405, "method not allowed", headers: [("Allow", "POST, DELETE")])
        }
    }

    /// Browsers attach Origin; a page must not reach the server through DNS rebinding.
    private func validateOrigin(_ request: McpHTTPRequest) -> McpHTTPResponse? {
        let allowedHosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.header("host")?.lowercased(), allowedHosts.contains(host) else {
            return .plain(403, "host not allowed")
        }
        if let origin = request.header("origin")?.lowercased(),
           !allowedHosts.map({ "http://\($0)" }).contains(origin) {
            return .plain(403, "origin not allowed")
        }
        return nil
    }

    private func handlePost(_ request: McpHTTPRequest) async -> McpHTTPResponse {
        if let type = request.header("content-type"), !type.lowercased().contains("application/json") {
            return .plain(415, "content type must be application/json")
        }
        guard let payload = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(400, Self.error(id: NSNull(), code: -32700, message: "parse error"))
        }
        let session = request.header("mcp-session-id")
        let grant = bearerToken(request).flatMap { backend?.grant(tokenHash: Self.hash(token: $0)) }
        let messages = (payload as? [Any]) ?? [payload]
        guard !messages.isEmpty else {
            return .json(400, Self.error(id: NSNull(), code: -32600, message: "empty batch"))
        }
        guard let grant else {
            for case let message as [String: Any] in messages { recordDeniedCall(message, session: session, reason: "invalid token") }
            return .json(401, Self.error(id: (messages.first as? [String: Any])?["id"] ?? NSNull(), code: -32001,
                                         message: "missing, revoked or expired bearer token"),
                         headers: [("WWW-Authenticate", "Bearer realm=\"snake\"")])
        }
        var replies: [Any] = []
        var newSession: String?
        for message in messages {
            guard let message = message as? [String: Any], message["jsonrpc"] as? String == "2.0",
                  let method = message["method"] as? String else {
                replies.append(Self.error(id: NSNull(), code: -32600, message: "invalid request"))
                continue
            }
            // Notifications and responses carry no id and get no reply.
            guard let id = message["id"], !(id is NSNull) else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                let (reply, created) = initialize(id: id, params: params)
                newSession = created
                replies.append(reply)
            case "ping":
                replies.append(Self.result(id: id, [:]))
            case "tools/list":
                replies.append(Self.result(id: id, ["tools": Self.tools]))
            case "tools/call":
                replies.append(await callTool(id: id, params: params, grant: grant, session: newSession ?? session))
            default:
                replies.append(Self.error(id: id, code: -32601, message: "method not found: \(method)"))
            }
        }
        let headers = newSession.map { [("Mcp-Session-Id", $0)] } ?? []
        if replies.isEmpty { return McpHTTPResponse(status: 202, headers: headers) }
        return .json(200, payload is [Any] ? replies : replies[0], headers: headers)
    }

    private func bearerToken(_ request: McpHTTPRequest) -> String? {
        guard let value = request.header("authorization") else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    private func initialize(id: Any, params: [String: Any]) -> ([String: Any], String) {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        let info = params["clientInfo"] as? [String: Any]
        let client = [info?["name"] as? String, info?["version"] as? String].compactMap { $0 }.joined(separator: " ")
        let session = UUID().uuidString
        clientNames[session] = String(client.prefix(200))
        sessionOrder.append(session)
        if sessionOrder.count > Self.maxSessions { clientNames.removeValue(forKey: sessionOrder.removeFirst()) }
        let reply = Self.result(id: id, [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "snake", "title": "Snake SSH", "version": Self.appVersion],
            "instructions": "Run non-interactive commands on the Snake SSH sessions this token may use. "
                + "Call list_sessions first. Commands run in the remote /bin/sh and every call is audited."
        ])
        return (reply, session)
    }

    private func forget(session: String) {
        clientNames.removeValue(forKey: session)
        sessionOrder.removeAll { $0 == session }
    }

    private func clientName(_ session: String?) -> String { session.flatMap { clientNames[$0] } ?? "" }

    // MARK: Tools

    private func callTool(id: Any, params: [String: Any], grant: McpGrant, session: String?) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "list_sessions":
            let sessions = allowedProfiles(grant).map { profile -> [String: Any] in
                var entry: [String: Any] = [
                    "session_id": profile.id.uuidString.lowercased(), "name": profile.name,
                    "host": profile.host, "port": profile.port, "username": profile.username
                ]
                if let group = backend?.groupName(for: profile) { entry["group"] = group }
                return entry
            }
            return Self.toolResult(id: id, ["sessions": sessions], isError: false)
        case "run_command":
            return await runCommand(id: id, arguments: arguments, grant: grant, session: session)
        default:
            return Self.error(id: id, code: -32602, message: "unknown tool: \(name)")
        }
    }

    private func allowedProfiles(_ grant: McpGrant) -> [SSHProfile] {
        (backend?.profiles() ?? []).filter { grant.profileIDs.contains($0.id) }
    }

    private func runCommand(id: Any, arguments: [String: Any], grant: McpGrant, session: String?) async -> [String: Any] {
        let command = arguments["command"] as? String ?? ""
        let cwd = (arguments["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let sessionValue = arguments["session_id"] as? String ?? ""
        let profileID = UUID(uuidString: sessionValue)
        let knownProfile = profileID.flatMap { id in backend?.profiles().first { $0.id == id } }
        var record = CoreMcpAuditRecord(
            id: UUID().uuidString, tokenId: grant.tokenID, tokenName: grant.tokenName,
            profileId: knownProfile?.id.uuidString, profileLabel: knownProfile.map(Self.label) ?? sessionValue,
            clientName: clientName(session), command: String(command.prefix(Self.maxCommandBytes)), cwd: cwd,
            startedAt: milliseconds(now()), finishedAt: nil, durationMs: nil, status: "running",
            exitStatus: nil, errorMessage: nil, stdoutExcerpt: "", stderrExcerpt: "", stdoutBytes: 0, stderrBytes: 0
        )
        func deny(_ code: Int, _ message: String) -> [String: Any] {
            record.status = "denied"
            record.errorMessage = message
            record.finishedAt = record.startedAt
            record.durationMs = 0
            backend?.recordAudit(record)
            return Self.error(id: id, code: code, message: message)
        }

        guard let profileID, let profile = knownProfile else { return deny(-32602, "unknown session_id") }
        guard grant.profileIDs.contains(profileID) else { return deny(-32602, "session_id is not allowed for this token") }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return deny(-32602, "command is required") }
        guard command.utf8.count <= Self.maxCommandBytes else { return deny(-32602, "command exceeds 16 KiB") }
        if let cwd, !cwd.hasPrefix("/") { return deny(-32602, "cwd must be an absolute path") }
        let timeout: Int
        switch arguments["timeout_seconds"] {
        case nil: timeout = Self.defaultTimeout
        case let value as Int where (1...Self.maxTimeout).contains(value): timeout = value
        case let value as Double where value == value.rounded() && (1...Double(Self.maxTimeout)).contains(value): timeout = Int(value)
        default: return deny(-32602, "timeout_seconds must be an integer from 1 to \(Self.maxTimeout)")
        }
        guard runningCommands < Self.maxConcurrentCommands else {
            return deny(-32000, "too many commands are already running; retry later")
        }

        backend?.recordAudit(record)
        runningCommands += 1
        defer { runningCommands -= 1 }
        let started = now()
        let outcome: Swift.Result<CoreCommandOutput, Error>
        do {
            guard let backend else { throw CancellationError() }
            outcome = .success(try await backend.run(McpCommandRequest(
                profile: profile, command: command, cwd: cwd, timeoutSeconds: timeout
            )))
        } catch {
            outcome = .failure(error)
        }
        let finished = now()
        let duration = Int64(max(0, finished.timeIntervalSince(started) * 1_000))
        switch outcome {
        case .success(let output):
            let status = output.timedOut ? "timeout" : (output.exitStatus == 0 ? "succeeded" : "failed")
            backend?.finishAudit(id: record.id, result: CoreMcpAuditResult(
                finishedAt: milliseconds(finished), durationMs: duration, status: status,
                exitStatus: output.exitStatus, errorMessage: nil, stdout: output.stdout, stderr: output.stderr,
                stdoutBytes: Int64(clamping: output.stdoutTotalBytes), stderrBytes: Int64(clamping: output.stderrTotalBytes)
            ))
            var content: [String: Any] = [
                "audit_id": record.id.lowercased(), "status": status,
                "stdout": String(decoding: output.stdout, as: UTF8.self),
                "stderr": String(decoding: output.stderr, as: UTF8.self),
                "stdout_truncated": output.stdoutTotalBytes > UInt64(output.stdout.count),
                "stderr_truncated": output.stderrTotalBytes > UInt64(output.stderr.count),
                "duration_ms": duration
            ]
            content["exit_status"] = output.exitStatus.map { $0 as Any } ?? NSNull()
            return Self.toolResult(id: id, content, isError: status != "succeeded")
        case .failure(let error):
            let message = Self.describe(error)
            backend?.finishAudit(id: record.id, result: CoreMcpAuditResult(
                finishedAt: milliseconds(finished), durationMs: duration, status: "error",
                exitStatus: nil, errorMessage: message, stdout: Data(), stderr: Data(), stdoutBytes: 0, stderrBytes: 0
            ))
            return Self.toolResult(id: id, [
                "audit_id": record.id.lowercased(), "status": "error", "error": message, "duration_ms": duration
            ], isError: true)
        }
    }

    /// Calls that never authenticated are still worth reviewing.
    private func recordDeniedCall(_ message: [String: Any], session: String?, reason: String) {
        guard message["method"] as? String == "tools/call",
              let params = message["params"] as? [String: Any],
              params["name"] as? String == "run_command" else { return }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let sessionValue = arguments["session_id"] as? String ?? ""
        let profile = UUID(uuidString: sessionValue).flatMap { id in backend?.profiles().first { $0.id == id } }
        let started = milliseconds(now())
        backend?.recordAudit(CoreMcpAuditRecord(
            id: UUID().uuidString, tokenId: nil, tokenName: "", profileId: profile?.id.uuidString,
            profileLabel: profile.map(Self.label) ?? sessionValue, clientName: clientName(session),
            command: String((arguments["command"] as? String ?? "").prefix(Self.maxCommandBytes)),
            cwd: arguments["cwd"] as? String, startedAt: started, finishedAt: started, durationMs: 0,
            status: "denied", exitStatus: nil, errorMessage: reason, stdoutExcerpt: "", stderrExcerpt: "",
            stdoutBytes: 0, stderrBytes: 0
        ))
    }

    // MARK: JSON-RPC helpers

    nonisolated static func label(_ profile: SSHProfile) -> String { "\(profile.username)@\(profile.host):\(profile.port)" }

    private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1_000) }

    static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private static func toolResult(id: Any, _ content: [String: Any], isError: Bool) -> [String: Any] {
        let text = (try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return result(id: id, [
            "content": [["type": "text", "text": text]],
            "structuredContent": content,
            "isError": isError
        ])
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case let CoreError.HostKeyUnknown(host, port, _, _):
            return "host key for \(host):\(port) is not trusted yet; connect once from Snake to trust it"
        case let CoreError.HostKeyMismatch(host, port, _, _, _):
            return "host key for \(host):\(port) changed; confirm it in Snake before using MCP"
        case let CoreError.Authentication(message, stage):
            return "authentication failed" + ([stage, message.isEmpty ? nil : message].compactMap { $0 }.map { ": \($0)" }.joined())
        case let CoreError.Connection(message, stage):
            return "connection failed" + ([stage, message.isEmpty ? nil : message].compactMap { $0 }.map { ": \($0)" }.joined())
        default:
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static let tools: [[String: Any]] = [
        [
            "name": "list_sessions",
            "title": "List SSH sessions",
            "description": "List the Snake SSH sessions this token may run commands on.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false]
        ],
        [
            "name": "run_command",
            "title": "Run a remote command",
            "description": "Run one non-interactive command on a Snake SSH session over a fresh exec channel. "
                + "The command is interpreted by the remote /bin/sh (POSIX), stdin is empty, and no PTY is "
                + "allocated, so interactive programs will not work. Every call is recorded for audit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string", "description": "A session_id returned by list_sessions."],
                    "command": ["type": "string", "description": "Shell command, at most 16 KiB."],
                    "cwd": ["type": "string", "description": "Optional absolute working directory."],
                    "timeout_seconds": [
                        "type": "integer", "minimum": 1, "maximum": maxTimeout, "default": defaultTimeout,
                        "description": "The command is stopped when this many seconds pass."
                    ]
                ],
                "required": ["session_id", "command"],
                "additionalProperties": false
            ],
            "annotations": ["destructiveHint": true, "openWorldHint": true]
        ]
    ]
}
