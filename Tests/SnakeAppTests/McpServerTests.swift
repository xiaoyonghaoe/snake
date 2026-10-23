import Foundation
import SnakeCoreBindings
import XCTest
@testable import SnakeApp

@MainActor
private final class FakeBackend: McpBackend {
    var grants: [String: McpGrant] = [:]
    var sessionProfiles: [SSHProfile] = []
    var records: [CoreMcpAuditRecord] = []
    var results: [String: CoreMcpAuditResult] = [:]
    var runs: [McpCommandRequest] = []
    var output = CoreCommandOutput(exitStatus: 0, stdout: Data("hi\n".utf8), stderr: Data(),
                                   stdoutTotalBytes: 3, stderrTotalBytes: 0, timedOut: false, durationMs: 5)
    var failure: Error?

    func grant(tokenHash: String) -> McpGrant? { grants[tokenHash] }
    func profiles() -> [SSHProfile] { sessionProfiles }
    func groupName(for profile: SSHProfile) -> String? { profile.groupID == nil ? nil : "生产" }
    func run(_ request: McpCommandRequest) async throws -> CoreCommandOutput {
        runs.append(request)
        if let failure { throw failure }
        return output
    }
    func recordAudit(_ record: CoreMcpAuditRecord) { records.append(record) }
    func finishAudit(id: String, result: CoreMcpAuditResult) { results[id] = result }
}

@MainActor
final class McpServerTests: XCTestCase {
    private let token = "snk_test-token"
    private let allowed = SSHProfile(name: "prod", host: "10.0.0.8", username: "root")
    private let other = SSHProfile(name: "other", host: "10.0.0.9", username: "root")
    private var backend: FakeBackend!
    private var handler: McpRequestHandler!

    override func setUp() async throws {
        backend = FakeBackend()
        backend.sessionProfiles = [allowed, other]
        backend.grants[McpRequestHandler.hash(token: token)] = McpGrant(tokenID: "t1", tokenName: "agent", profileIDs: [allowed.id])
        handler = McpRequestHandler(backend: backend, port: 47821)
    }

    private func request(_ body: Any, token: String? = "snk_test-token", headers: [String: String] = [:]) -> McpHTTPRequest {
        var all = ["host": "127.0.0.1:47821", "content-type": "application/json"]
        if let token { all["authorization"] = "Bearer \(token)" }
        all.merge(headers) { $1 }
        return McpHTTPRequest(method: "POST", path: "/mcp", headers: all,
                              body: try! JSONSerialization.data(withJSONObject: body))
    }

    private func call(_ name: String, _ arguments: [String: Any], token: String? = "snk_test-token") async -> (McpHTTPResponse, [String: Any]) {
        let response = await handler.handle(request(
            ["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": name, "arguments": arguments]],
            token: token
        ))
        return (response, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:])
    }

    private func structured(_ reply: [String: Any]) -> [String: Any] {
        ((reply["result"] as? [String: Any])?["structuredContent"] as? [String: Any]) ?? [:]
    }

    func testHTTPParserHandlesFragmentsLimitsAndBadInput() {
        let raw = Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for split in 0..<raw.count {
            XCTAssertEqual(McpHTTPParser.parse(raw.prefix(split)), .incomplete, "split \(split)")
        }
        guard case .complete(let parsed) = McpHTTPParser.parse(raw) else { return XCTFail("not parsed") }
        XCTAssertEqual(parsed.path, "/mcp")
        XCTAssertEqual(parsed.header("HOST"), "127.0.0.1:1")
        XCTAssertEqual(parsed.body, Data("{}".utf8))

        let huge = Data("POST /mcp HTTP/1.1\r\nContent-Length: \(McpHTTPParser.bodyLimit + 1)\r\n\r\n".utf8)
        guard case .invalid(let tooLarge) = McpHTTPParser.parse(huge) else { return XCTFail("accepted huge body") }
        XCTAssertEqual(tooLarge.status, 413)
        guard case .invalid(let chunked) = McpHTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else {
            return XCTFail("accepted chunked body")
        }
        XCTAssertEqual(chunked.status, 400)
        guard case .invalid(let header) = McpHTTPParser.parse(Data(repeating: 65, count: McpHTTPParser.headerLimit + 1)) else {
            return XCTFail("accepted endless header")
        }
        XCTAssertEqual(header.status, 431)
    }

    func testRejectsForeignHostsOriginsAndMethods() async {
        var foreign = request(["jsonrpc": "2.0", "id": 1, "method": "ping"])
        foreign.headers["host"] = "attacker.example:47821"
        let hostResponse = await handler.handle(foreign)
        XCTAssertEqual(hostResponse.status, 403)
        let originResponse = await handler.handle(request(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["origin": "https://evil.example"]))
        XCTAssertEqual(originResponse.status, 403)
        let localOrigin = await handler.handle(request(["jsonrpc": "2.0", "id": 1, "method": "ping"], headers: ["origin": "http://localhost:47821"]))
        XCTAssertEqual(localOrigin.status, 200)
        let get = await handler.handle(McpHTTPRequest(method: "GET", path: "/mcp", headers: ["host": "127.0.0.1:47821"], body: Data()))
        XCTAssertEqual(get.status, 405)
        let wrongPath = await handler.handle(McpHTTPRequest(method: "POST", path: "/", headers: ["host": "127.0.0.1:47821"], body: Data()))
        XCTAssertEqual(wrongPath.status, 404)
    }

    func testInitializeNegotiatesVersionAndIssuesSession() async throws {
        let response = await handler.handle(request(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
            "protocolVersion": "2025-03-26", "clientInfo": ["name": "claude-code", "version": "2.0"]
        ]]))
        XCTAssertEqual(response.status, 200)
        let session = try XCTUnwrap(response.header("Mcp-Session-Id"))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-03-26")

        let notification = await handler.handle(request(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(notification.status, 202)

        _ = await handler.handle(request(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
            "name": "run_command", "arguments": ["session_id": allowed.id.uuidString, "command": "uptime"]
        ]], headers: ["mcp-session-id": session]))
        XCTAssertEqual(backend.records.last?.clientName, "claude-code 2.0", "audit keeps the client name")
    }

    func testToolsListDescribesBothTools() async throws {
        let response = await handler.handle(request(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["list_sessions", "run_command"])
    }

    func testInvalidTokenIsRejectedAndRunAttemptAudited() async {
        let (response, reply) = await call("run_command", ["session_id": allowed.id.uuidString, "command": "rm -rf /"], token: "snk_wrong")
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(response.header("WWW-Authenticate"), "Bearer realm=\"snake\"")
        XCTAssertNotNil(reply["error"])
        XCTAssertEqual(backend.records.map(\.status), ["denied"])
        XCTAssertNil(backend.records[0].tokenId)
        XCTAssertEqual(backend.records[0].command, "rm -rf /")
        XCTAssertTrue(backend.runs.isEmpty)

        let missing = await handler.handle(request(["jsonrpc": "2.0", "id": 1, "method": "tools/list"], token: nil))
        XCTAssertEqual(missing.status, 401)
    }

    func testListSessionsOnlyReturnsBoundSessions() async {
        let (_, reply) = await call("list_sessions", [:])
        let sessions = structured(reply)["sessions"] as? [[String: Any]] ?? []
        XCTAssertEqual(sessions.compactMap { $0["session_id"] as? String }, [allowed.id.uuidString.lowercased()])
    }

    func testRunCommandEnforcesBindingAndValidatesArguments() async {
        for arguments: [String: Any] in [
            ["session_id": other.id.uuidString, "command": "id"],
            ["session_id": UUID().uuidString, "command": "id"],
            ["session_id": allowed.id.uuidString, "command": "   "],
            ["session_id": allowed.id.uuidString, "command": "ls", "cwd": "relative"],
            ["session_id": allowed.id.uuidString, "command": "ls", "timeout_seconds": 0],
            ["session_id": allowed.id.uuidString, "command": "ls", "timeout_seconds": 601],
            ["session_id": allowed.id.uuidString, "command": String(repeating: "x", count: 16 * 1_024 + 1)]
        ] {
            let (response, reply) = await call("run_command", arguments)
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? Int, -32602, "\(arguments.keys)")
        }
        XCTAssertTrue(backend.runs.isEmpty)
        XCTAssertEqual(Set(backend.records.map(\.status)), ["denied"])
        XCTAssertEqual(backend.records.count, 7)
        XCTAssertEqual(backend.records[0].profileLabel, "root@10.0.0.9:22", "denied calls name the target")
    }

    func testRunCommandReturnsOutputAndRecordsStartAndFinish() async throws {
        backend.output = CoreCommandOutput(exitStatus: 2, stdout: Data("partial".utf8), stderr: Data("boom".utf8),
                                           stdoutTotalBytes: 900_000, stderrTotalBytes: 4, timedOut: false, durationMs: 9)
        let (_, reply) = await call("run_command", [
            "session_id": allowed.id.uuidString, "command": "make", "cwd": "/srv", "timeout_seconds": 5
        ])
        let content = structured(reply)
        XCTAssertEqual(content["status"] as? String, "failed")
        XCTAssertEqual(content["exit_status"] as? Int, 2)
        XCTAssertEqual(content["stdout_truncated"] as? Bool, true)
        XCTAssertEqual(content["stderr"] as? String, "boom")
        XCTAssertEqual((reply["result"] as? [String: Any])?["isError"] as? Bool, true)
        let run = try XCTUnwrap(backend.runs.first)
        XCTAssertEqual([run.command, run.cwd], ["make", "/srv"])
        XCTAssertEqual(run.timeoutSeconds, 5)

        let record = try XCTUnwrap(backend.records.first)
        XCTAssertEqual([record.status, record.tokenName, record.profileLabel], ["running", "agent", "root@10.0.0.8:22"])
        XCTAssertEqual(content["audit_id"] as? String, record.id.lowercased())
        let result = try XCTUnwrap(backend.results[record.id])
        XCTAssertEqual(result.status, "failed")
        XCTAssertEqual(result.stdoutBytes, 900_000)
    }

    func testTimeoutsAndConnectionErrorsAreReportedAsToolErrors() async {
        backend.output = CoreCommandOutput(exitStatus: nil, stdout: Data(), stderr: Data(),
                                           stdoutTotalBytes: 0, stderrTotalBytes: 0, timedOut: true, durationMs: 1_000)
        let (_, timeout) = await call("run_command", ["session_id": allowed.id.uuidString, "command": "sleep 9"])
        XCTAssertEqual(structured(timeout)["status"] as? String, "timeout")

        backend.failure = CoreError.HostKeyUnknown(host: "10.0.0.8", port: 22, algorithm: "ED25519", fingerprint: "x")
        let (_, failure) = await call("run_command", ["session_id": allowed.id.uuidString, "command": "id"])
        XCTAssertEqual(structured(failure)["status"] as? String, "error")
        XCTAssertTrue((structured(failure)["error"] as? String ?? "").contains("not trusted"))
        XCTAssertEqual(backend.results.values.map(\.status).sorted(), ["error", "timeout"])
    }

    func testControllerStoresTokensAndEnforcesRevocationAndExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snake-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "com.snake.tests.mcp.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = try CorePersistence(databaseURL: root.appendingPathComponent("db.sqlite3"))
        try persistence.save(allowed)
        let controller = McpController(persistence: persistence, defaults: defaults,
                                       profiles: { [allowed] in [allowed] }, groupName: { _ in nil })
        XCTAssertEqual(controller.serverState, .stopped)

        let secret = try McpController.generateSecret()
        XCTAssertTrue(secret.hasPrefix("snk_"))
        XCTAssertEqual(secret.count, 4 + 43)
        XCTAssertNotEqual(secret, try McpController.generateSecret())

        // Token creation writes the encrypted copy; use a plain row here so the
        // test does not touch the user's credential store.
        let id = UUID()
        try persistence.createMcpToken(CoreMcpToken(
            id: id.uuidString, name: "agent", tokenPrefix: String(secret.prefix(12)),
            createdAt: 1, expiresAt: nil, lastUsedAt: nil, revokedAt: nil, profileIds: [allowed.id.uuidString]
        ), hash: McpRequestHandler.hash(token: secret))
        controller.reloadTokens()
        XCTAssertEqual(controller.tokens.map(\.profileIDs), [[allowed.id]])

        let hash = McpRequestHandler.hash(token: secret)
        XCTAssertEqual(controller.grant(tokenHash: hash)?.profileIDs, [allowed.id])
        XCTAssertNotNil(controller.tokens.first, "lookup records the last use")
        controller.reloadTokens()
        XCTAssertNotNil(controller.tokens.first?.lastUsedAt)

        try controller.setRevoked(true, tokenID: id)
        XCTAssertNil(controller.grant(tokenHash: hash))
        XCTAssertEqual(controller.tokens.first?.state(), .revoked)
        try controller.setRevoked(false, tokenID: id)
        try controller.updateToken(id: id, name: "agent", profileIDs: [allowed.id], expiresAt: .now.addingTimeInterval(-1))
        XCTAssertNil(controller.grant(tokenHash: hash))
        XCTAssertEqual(controller.tokens.first?.state(), .expired)

        controller.retentionDays = 0
        controller.maxRecords = 1
        for index in 0..<3 {
            controller.recordAudit(CoreMcpAuditRecord(
                id: UUID().uuidString, tokenId: id.uuidString, tokenName: "agent", profileId: nil, profileLabel: "x",
                clientName: "", command: "echo \(index)", cwd: nil, startedAt: Int64(index), finishedAt: Int64(index),
                durationMs: 0, status: "succeeded", exitStatus: 0, errorMessage: nil, stdoutExcerpt: "",
                stderrExcerpt: "", stdoutBytes: 0, stderrBytes: 0
            ))
        }
        controller.pruneAudit()
        XCTAssertEqual(controller.auditRecords(filter: .matching(), limit: 10).map(\.command), ["echo 2"])
        XCTAssertEqual(try controller.deleteAudit(filter: .matching(tokenID: id.uuidString)), 1)
    }
}
