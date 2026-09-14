import Foundation

/// Identifies the server a transfer connects to.
///
/// The budget is keyed by `host:port` rather than by session: two sessions that
/// point at the same server put load on the same machine, so they share one budget.
struct TransferHost: Hashable, Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.port = port
    }

    init(profile: SSHProfile) {
        self.init(host: profile.host, port: profile.port)
    }
}

/// Process-wide budget for the short-lived connections a transfer opens against one host.
///
/// The per-transfer setting only bounds a single download or upload, so several tabs
/// used to multiply into `tabs × shards` simultaneous connections to the same server.
/// This budget adds the missing per-host ceiling.
///
/// A job reserves every connection it will use in one go and releases them when it
/// finishes, so a job never waits while holding budget — the classic deadlock cannot
/// happen. A job larger than the whole limit is still admitted while the host is idle,
/// which keeps a very small limit from stalling the queue forever.
final class HostTransferBudget: @unchecked Sendable {
    static let shared = HostTransferBudget()
    static let defaultLimit = 8
    static let allowedLimits = 2...16

    private final class Waiter {
        let connections: Int
        let continuation: CheckedContinuation<Void, Never>

        init(connections: Int, continuation: CheckedContinuation<Void, Never>) {
            self.connections = connections
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private var limit: Int
    private var active: [TransferHost: Int] = [:]
    private var waiters: [TransferHost: [Waiter]] = [:]

    init(limit: Int = HostTransferBudget.defaultLimit) {
        self.limit = Self.clamp(limit)
    }

    static func clamp(_ value: Int) -> Int {
        min(max(value, allowedLimits.lowerBound), allowedLimits.upperBound)
    }

    var perHostLimit: Int {
        lock.lock()
        defer { lock.unlock() }
        return limit
    }

    func setLimit(_ value: Int) {
        lock.lock()
        limit = Self.clamp(value)
        let hosts = Array(waiters.keys)
        lock.unlock()
        for host in hosts { admitWaiters(host) }
    }

    /// Number of connection slots currently held for `host` (test probe).
    func activeConnections(for host: TransferHost) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return active[host] ?? 0
    }

    /// Runs `body` while holding `connections` slots for `host`.
    ///
    /// Every exit path releases, including a thrown error.
    func reserve<T: Sendable>(
        host: TransferHost,
        connections: Int,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let count = max(1, connections)
        await acquire(host: host, connections: count)
        do {
            let value = try await body()
            release(host: host, connections: count)
            return value
        } catch {
            release(host: host, connections: count)
            throw error
        }
    }

    /// Runs `body` while holding a single slot, for one short-lived connection.
    func withConnection<T: Sendable>(
        host: TransferHost,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await reserve(host: host, connections: 1, body)
    }

    // MARK: - Internals (locking is kept in synchronous helpers: Swift 6 rejects
    // `NSLock.lock()` inside an async context.)

    /// Must be called with `lock` held.
    private func fits(connections: Int, active current: Int) -> Bool {
        // An idle host admits an oversized job alone rather than deadlocking.
        (current == 0 && connections > limit) || current + connections <= limit
    }

    private func acquire(host: TransferHost, connections: Int) async {
        if tryAcquire(host: host, connections: connections) { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue(host: host, connections: connections, continuation: continuation)
        }
    }

    private func tryAcquire(host: TransferHost, connections: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let current = active[host] ?? 0
        guard fits(connections: connections, active: current) else { return false }
        active[host] = current + connections
        return true
    }

    private func enqueue(host: TransferHost, connections: Int, continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let current = active[host] ?? 0
        let admitted = fits(connections: connections, active: current)
        if admitted {
            active[host] = current + connections
        } else {
            waiters[host, default: []].append(Waiter(connections: connections, continuation: continuation))
        }
        lock.unlock()
        // Resumed outside the lock: the woken task may immediately touch the budget.
        if admitted { continuation.resume() }
    }

    private func release(host: TransferHost, connections: Int) {
        lock.lock()
        active[host] = max(0, (active[host] ?? 0) - connections)
        lock.unlock()
        admitWaiters(host)
    }

    /// Admits queued jobs in arrival order while they fit the limit.
    private func admitWaiters(_ host: TransferHost) {
        var admitted: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        var queue = waiters[host] ?? []
        while let next = queue.first {
            let current = active[host] ?? 0
            guard fits(connections: next.connections, active: current) else { break }
            active[host] = current + next.connections
            admitted.append(next.continuation)
            queue.removeFirst()
        }
        waiters[host] = queue.isEmpty ? nil : queue
        lock.unlock()
        for continuation in admitted { continuation.resume() }
    }
}

/// How many connections one transfer may open against a host.
enum HostTransferPlan {
    /// Shards a single transfer may use.
    ///
    /// A transfer keeps one extra connection alive for metadata and verification on
    /// top of its shards, so the shard count leaves room for it inside the host limit.
    static func workerCount(requested: Int, hostLimit: Int) -> Int {
        let hostCeiling = max(1, hostLimit - 1)
        return max(1, min(max(1, requested), hostCeiling))
    }
}
