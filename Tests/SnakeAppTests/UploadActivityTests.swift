import XCTest
@testable import SnakeApp

final class UploadActivityTests: XCTestCase {
    func testSmallUploadKeepsSuccessVisibleForFourSeconds() {
        var activity = UploadActivity()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(activity.result, .idle)
        activity.begin(at: start)
        XCTAssertEqual(activity.result, .running)
        activity.finish(.init(succeeded: 1), at: start.addingTimeInterval(0.01))
        XCTAssertTrue(activity.showsSuccess(at: start.addingTimeInterval(3.9)))
        XCTAssertFalse(activity.showsSuccess(at: start.addingTimeInterval(4.02)))
        XCTAssertEqual(activity.summary, "已上传 1 项")
        XCTAssertNotNil(activity.startedAt) // History remains after the animation.
    }

    func testQueuedBatchDoesNotShowPrematureSuccess() {
        var activity = UploadActivity()
        activity.begin()
        let id = activity.id
        activity.begin()
        activity.finish(.init(succeeded: 2))
        XCTAssertEqual(activity.result, .running)
        XCTAssertFalse(activity.showsSuccess(at: .now))
        XCTAssertNil(activity.finishedAt)
        activity.finish(.init(succeeded: 1))
        XCTAssertEqual(activity.id, id)
        XCTAssertEqual(activity.result, .succeeded)
        XCTAssertEqual(activity.succeeded, 3)
    }

    func testFailureCancellationAndSkipNeverShowGreenCompletion() {
        for outcome in [UploadActivity.Outcome(succeeded: 1, failed: 1),
                        .init(succeeded: 1, cancelled: 1), .init(skipped: 2)] {
            var activity = UploadActivity()
            activity.begin()
            activity.finish(outcome)
            XCTAssertFalse(activity.showsSuccess(at: .now))
            XCTAssertNotEqual(activity.result, .succeeded)
        }
        var partial = UploadActivity()
        partial.begin()
        partial.finish(.init(succeeded: 1, skipped: 1))
        XCTAssertFalse(partial.showsSuccess(at: .now))
        XCTAssertEqual(partial.summary, "已上传 1 项，跳过 1 项")
    }

    func testNewUploadResetsPreviousFailureAndOwnsNewFeedbackID() {
        var activity = UploadActivity()
        activity.begin()
        let oldID = activity.id
        activity.finish(.init(failed: 1))
        activity.begin()
        XCTAssertNotEqual(activity.id, oldID)
        XCTAssertEqual(activity.failed, 0)
        XCTAssertNil(activity.finishedAt)
        activity.finish(.init(succeeded: 1)) // Also covers empty directory success.
        XCTAssertTrue(activity.showsSuccess(at: .now))
        activity.finish(.init(failed: 1)) // An already-finished operation is ignored.
        XCTAssertEqual(activity.result, .succeeded)
    }
}
