import XCTest
@testable import SnakeApp

/// Covers the per-host transfer connection budget: the ceiling itself, FIFO waiting,
/// release on every exit path, and the settings entry that drives it.
final class HostTransferBudgetTests: XCTestCase {
    private let hostA = TransferHost(host: "example.com", port: 22)
    private let hostB = TransferHost(host: "other.example.com", port: 22)

    // MARK: - Ceiling

    func testReservationsNeverExceedTheLimit() async {
        let budget = HostTransferBudget(limit: 4)
        let probe = ConcurrencyProbe()
        let host = hostA

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try? await budget.reserve(host: host, connections: 1) {
                        probe.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        probe.leave()
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(probe.maximum, 4)
        XCTAssertEqual(budget.activeConnections(for: hostA), 0)
    }

    func testMultiConnectionReservationsFitInsideTheLimit() async {
        let budget = HostTransferBudget(limit: 6)
        let probe = ConcurrencyProbe()
        let host = hostA

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await budget.reserve(host: host, connections: 2) {
                        probe.enter()
                        try? await Task.sleep(for: .milliseconds(5))
                        probe.leave()
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(probe.maximum, 3, "6 条预算最多容纳 3 个各占 2 条的作业")
        XCTAssertEqual(budget.activeConnections(for: hostA), 0)
    }

    func testHostsAreBudgetedIndependently() async throws {
        let budget = HostTransferBudget(limit: 2)
        let other = ConcurrencyProbe()
        let first = hostA
        let second = hostB

        try await budget.reserve(host: first, connections: 2) {
            // hostA 已占满；hostB 必须立刻可用。
            try await budget.reserve(host: second, connections: 2) {
                other.enter()
            }
            XCTAssertEqual(other.maximum, 1)
        }
        XCTAssertEqual(budget.activeConnections(for: second), 0)
    }

    func testOversizedJobIsAdmittedWhileTheHostIsIdle() async throws {
        let budget = HostTransferBudget(limit: 2)
        // 上限 1 时单次传输仍需 2 条（外层 + 1 分片）：必须能独立放行而不是永久等待。
        let ran = try await budget.reserve(host: hostA, connections: 5) { true }
        XCTAssertTrue(ran)
        XCTAssertEqual(budget.activeConnections(for: hostA), 0)
    }

    // MARK: - Waiting

    func testWaitersAreAdmittedInArrivalOrder() async {
        let budget = HostTransferBudget(limit: 1)
        let order = ConcurrencyProbe()
        let host = hostA

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                // 先占住唯一的一条。
                try? await budget.reserve(host: host, connections: 1) {
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
            for tag in 1...3 {
                try? await Task.sleep(for: .milliseconds(20))
                group.addTask {
                    try? await budget.reserve(host: host, connections: 1) {
                        order.enter(tag)
                        try? await Task.sleep(for: .milliseconds(5))
                        order.leave()
                    }
                }
            }
        }

        XCTAssertEqual(order.marks, [1, 2, 3], "等待者按到达顺序放行")
    }

    func testWaitingForOneHostDoesNotBlockAnother() async throws {
        let budget = HostTransferBudget(limit: 1)
        let first = hostA
        let second = hostB
        try await budget.reserve(host: first, connections: 1) {
            // hostA 占满时 hostB 立即通过。
            try await budget.reserve(host: second, connections: 1) {}
        }
    }

    // MARK: - Release

    func testPermitsAreReleasedWhenTheBodyThrows() async {
        struct Boom: Error {}
        let budget = HostTransferBudget(limit: 2)

        do {
            try await budget.reserve(host: hostA, connections: 2) { throw Boom() }
            XCTFail("应当抛出")
        } catch {}

        XCTAssertEqual(budget.activeConnections(for: hostA), 0)
        // 预算已归还，下一次预留立即成功。
        let ran = try? await budget.reserve(host: hostA, connections: 2) { true }
        XCTAssertEqual(ran, true)
    }

    func testLoweringTheLimitKeepsCountersConsistent() async throws {
        let budget = HostTransferBudget(limit: 4)
        try await budget.reserve(host: hostA, connections: 4) {
            budget.setLimit(2)
            XCTAssertEqual(budget.perHostLimit, 2)
        }
        XCTAssertEqual(budget.activeConnections(for: hostA), 0)
        let ran = try await budget.reserve(host: hostA, connections: 2) { true }
        XCTAssertTrue(ran)
    }

    func testLimitIsClampedToTheAllowedRange() {
        XCTAssertEqual(HostTransferBudget(limit: 0).perHostLimit, HostTransferBudget.allowedLimits.lowerBound)
        XCTAssertEqual(HostTransferBudget(limit: 99).perHostLimit, HostTransferBudget.allowedLimits.upperBound)
        XCTAssertEqual(HostTransferBudget.clamp(7), 7)
    }

    // MARK: - Shard planning

    func testWorkerCountLeavesRoomForTheOuterHandle() {
        XCTAssertEqual(HostTransferPlan.workerCount(requested: 8, hostLimit: 8), 7)
        XCTAssertEqual(HostTransferPlan.workerCount(requested: 4, hostLimit: 16), 4)
        XCTAssertEqual(HostTransferPlan.workerCount(requested: 4, hostLimit: 2), 1)
        XCTAssertEqual(HostTransferPlan.workerCount(requested: 8, hostLimit: 1), 1)
        XCTAssertEqual(HostTransferPlan.workerCount(requested: 0, hostLimit: 8), 1)
    }

    func testUploadPlanMatchesItsReservation() {
        XCTAssertEqual(LocalUploadCoordinator.plannedWorkerCount(size: 10, thresholdBytes: 50, concurrency: 4), 1)
        XCTAssertEqual(LocalUploadCoordinator.plannedWorkerCount(size: 100, thresholdBytes: 50, concurrency: 4), 4)
        XCTAssertEqual(LocalUploadCoordinator.plannedWorkerCount(size: 2, thresholdBytes: 50, concurrency: 4), 1)
    }

    // MARK: - Host identity

    func testHostIdentityNormalizesCaseAndWhitespace() {
        XCTAssertEqual(
            TransferHost(host: " DB.Example.COM ", port: 22),
            TransferHost(host: "db.example.com", port: 22)
        )
        XCTAssertNotEqual(
            TransferHost(host: "db.example.com", port: 22),
            TransferHost(host: "db.example.com", port: 2222)
        )
    }

    // MARK: - Settings

    @MainActor
    func testHostLimitSettingClampsAndPersists() throws {
        let suite = "snake-host-budget-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            HostTransferBudget.shared.setLimit(HostTransferBudget.defaultLimit)
        }
        let database = root.appendingPathComponent("test.sqlite3")

        let store = ApplicationStore(databaseURL: database, userDefaults: defaults)
        XCTAssertEqual(store.hostConcurrencyLimit, HostTransferBudget.defaultLimit)

        store.hostConcurrencyLimit = 1
        XCTAssertEqual(store.hostConcurrencyLimit, 2)
        store.hostConcurrencyLimit = 99
        XCTAssertEqual(store.hostConcurrencyLimit, 16)

        store.hostConcurrencyLimit = 6
        XCTAssertEqual(ApplicationStore(databaseURL: database, userDefaults: defaults).hostConcurrencyLimit, 6)
        XCTAssertEqual(HostTransferBudget.shared.perHostLimit, 6)

        defaults.set(0, forKey: "com.snake.transfer.host-concurrency")
        XCTAssertEqual(
            ApplicationStore(databaseURL: database, userDefaults: defaults).hostConcurrencyLimit,
            HostTransferBudget.defaultLimit,
            "越界的历史值回退默认"
        )
    }
}

/// Tracks how many holders are inside a critical section at once, plus arrival order.
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0
    private var sequence: [Int] = []

    func enter(_ tag: Int = 0) {
        lock.lock()
        current += 1
        peak = max(peak, current)
        if tag != 0 { sequence.append(tag) }
        lock.unlock()
    }

    func leave() {
        lock.lock()
        current -= 1
        lock.unlock()
    }

    var maximum: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var marks: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }
}
