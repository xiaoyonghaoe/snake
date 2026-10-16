import Foundation
import SnakeCoreBindings
import XCTest
@testable import SnakeApp

@MainActor
final class UploadRetryTests: XCTestCase {
    func testImmediateRetryWaitsForOldCancellationAndCanBeCancelledWhileQueued() async throws {
        for cancelRetry in [false, true] {
            let suite = "snake-upload-retry-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let store = ApplicationStore(databaseURL: root.appendingPathComponent("db"), userDefaults: defaults)
            let profile = SSHProfile(name: "retry", host: "retry.example", username: "user")
            let uploader = LocalUploadCoordinator(profile: profile)
            let local = root.appendingPathComponent("source")
            try Data("data".utf8).write(to: local)
            let id = store.registerRealUpload(url: local, to: profile, targetPath: "/target", totalBytes: 4)
            uploader.records = [SFTPUploadRecord(jobID: id, fileName: "source", remotePath: "/target",
                fileSize: 4, startedAt: .now, state: .running, localURL: local, overwrite: false)]
            _ = store.makeTransferControl(for: id)
            let gate = RetryTestGate()
            uploader.batchTask = Task {
                await gate.wait()
                // Mirrors the old attempt's late cancellation callback.
                store.cancel(jobID: id)
                uploader.update(jobID: id, state: .cancelled, finishedAt: .now)
            }
            let factoryCalls = RetryFactoryCalls()
            uploader.transferHandleFactory = {
                factoryCalls.increment()
                throw CoreError.InvalidInput(message: "fixture stops before opening SSH")
            }
            uploader.cancel(jobID: id, store: store)
            uploader.retry(jobID: id, store: store)
            // A duplicate retry must not enqueue another attempt.
            uploader.retry(jobID: id, store: store)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(factoryCalls.count, 0, "Retry must wait for old cleanup")
            if cancelRetry { uploader.cancel(jobID: id, store: store) }
            await gate.open()
            await uploader.batchTask?.value
            XCTAssertEqual(factoryCalls.count, cancelRetry ? 0 : 1)
            XCTAssertEqual(uploader.records.first?.state, cancelRetry ? .cancelled : .failed)
            XCTAssertFalse(uploader.isPreparing)
        }
    }
}

private actor RetryTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private final class RetryFactoryCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
