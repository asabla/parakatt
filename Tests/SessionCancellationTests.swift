import XCTest
@testable import ParakattApp

final class SessionCancellationTests: XCTestCase {
    func testCancelBeforeWorkerStartsPreventsSessionCreation() {
        let job = SessionCancellation()
        job.cancel()
        XCTAssertFalse(job.start({ XCTFail("Cancelled work must not start") }, onCancel: {}))
    }
    func testCancelAbortsAcceptedSessionExactlyOnce() {
        let job = SessionCancellation()
        var cancellations = 0
        XCTAssertTrue(job.start({}, onCancel: { cancellations += 1 }))
        job.cancel()
        job.cancel()
        XCTAssertEqual(cancellations, 1)
    }
    func testCompletedSessionHasNoLateCancellationCallback() {
        let job = SessionCancellation()
        XCTAssertTrue(job.start({}, onCancel: { XCTFail("Completed work must stay closed") }))
        job.finish()
        job.cancel()
    }
}
