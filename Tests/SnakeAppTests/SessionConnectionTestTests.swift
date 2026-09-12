import XCTest
@testable import SnakeApp

@MainActor
final class SessionConnectionTestTests: XCTestCase {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Probe did not settle")
    }

    func testHandshakeResultIsBoundToCleanedTarget() async {
        let result = SessionHandshakeResult(algorithm: "fixture-key", fingerprint: "SHA256:fixture")
        var observed: SessionConnectionTarget?
        let controller = SessionConnectionTestController { target in observed = target; return result }
        controller.start(host: " host.example \n", port: "2222")
        await settle { !controller.isTesting }
        let expected = SessionConnectionTarget(host: "host.example", port: 2222)
        XCTAssertEqual(observed, expected)
        XCTAssertEqual(controller.state, .success(expected, result))
        controller.reset()
        XCTAssertEqual(controller.state, .idle)
    }

    func testInvalidTargetsNeverStartProbe() {
        var calls = 0
        let controller = SessionConnectionTestController { _ in
            calls += 1
            return SessionHandshakeResult(algorithm: "", fingerprint: "")
        }
        for (host, port) in [("", "22"), ("host", "0"), ("host", "65536"), ("host", "bad")] {
            controller.start(host: host, port: port)
            guard case .failure(nil, _) = controller.state else { return XCTFail("Expected validation failure") }
        }
        XCTAssertEqual(calls, 0)
    }

    func testNewTargetAndDismissIgnoreLateResults() async {
        var completions: [String: CheckedContinuation<SessionHandshakeResult, Error>] = [:]
        let controller = SessionConnectionTestController { target in
            try await withCheckedThrowingContinuation { completions[target.host] = $0 }
        }
        let result = SessionHandshakeResult(algorithm: "fixture", fingerprint: "test")
        controller.start(host: "old", port: "22")
        await settle { completions["old"] != nil }
        controller.reset() // host/port edit
        controller.start(host: "new", port: "2222")
        await settle { completions["new"] != nil }
        completions["new"]?.resume(returning: result)
        await settle { !controller.isTesting }
        completions["old"]?.resume(returning: result)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state, .success(.init(host: "new", port: 2222), result))
        controller.start(host: "closing", port: "22")
        await settle { completions["closing"] != nil }
        controller.reset() // form dismissal
        completions["closing"]?.resume(throwing: TestFailure.offline)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.state, .idle)
    }

    func testFailureHasItsOwnTargetAndDoesNotBecomeSuccess() async {
        let controller = SessionConnectionTestController { _ in throw TestFailure.offline }
        controller.start(host: "unreachable", port: "22")
        await settle { !controller.isTesting }
        guard case .failure(let target, let message) = controller.state else { return XCTFail("Expected failure") }
        XCTAssertEqual(target, .init(host: "unreachable", port: 22))
        XCTAssertTrue(message.contains("SSH 握手"))
    }

    private enum TestFailure: Error { case offline }
}
