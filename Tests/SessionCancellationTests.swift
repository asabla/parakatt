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
        let cancellations = Locked(wrappedValue: 0)
        XCTAssertTrue(job.start({}, onCancel: { cancellations.wrappedValue += 1 }))
        job.cancel()
        job.cancel()
        XCTAssertEqual(cancellations.wrappedValue, 1)
    }
    func testCompletedSessionHasNoLateCancellationCallback() {
        let job = SessionCancellation()
        XCTAssertTrue(job.start({}, onCancel: { XCTFail("Completed work must stay closed") }))
        job.finish()
        job.cancel()
    }
}
