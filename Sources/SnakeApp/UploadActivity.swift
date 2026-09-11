import Foundation

/// Transient feedback for all uploads accepted while this tab is busy.
/// File records stay authoritative; this also represents directory-only batches.
struct UploadActivity: Equatable {
    enum Result: Equatable { case idle, running, succeeded, failed, cancelled, skipped }
    struct Outcome {
        var succeeded = 0
        var failed = 0
        var cancelled = 0
        var skipped = 0
    }
    private(set) var id = UUID()
    private(set) var pendingCount = 0
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private(set) var succeeded = 0
    private(set) var failed = 0
    private(set) var cancelled = 0
    private(set) var skipped = 0

    mutating func begin(at date: Date = .now) {
        if pendingCount == 0 { self = UploadActivity(); startedAt = date }
        pendingCount += 1
    }

    mutating func finish(_ outcome: Outcome, at date: Date = .now) {
        guard pendingCount > 0 else { return }
        succeeded += outcome.succeeded
        failed += outcome.failed
        cancelled += outcome.cancelled
        skipped += outcome.skipped
        pendingCount -= 1
        if pendingCount == 0 { finishedAt = date }
    }

    var result: Result {
        if pendingCount > 0 { return .running }
        if failed > 0 { return .failed }
        if cancelled > 0 { return .cancelled }
        if succeeded > 0 { return .succeeded }
        return startedAt == nil ? .idle : .skipped
    }

    func showsSuccess(at date: Date) -> Bool {
        result == .succeeded && skipped == 0 && date.timeIntervalSince(finishedAt ?? .distantPast) < 4
    }

    var summary: String {
        switch result {
        case .idle: "暂无上传"
        case .running: "正在上传"
        case .succeeded: skipped > 0 ? "已上传 \(succeeded) 项，跳过 \(skipped) 项" : "已上传 \(succeeded) 项"
        case .failed: "已上传 \(succeeded) 项，\(failed) 项失败"
        case .cancelled: "上传已取消（完成 \(succeeded) 项）"
        case .skipped: "本次上传已跳过"
        }
    }
}
