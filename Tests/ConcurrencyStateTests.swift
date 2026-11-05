import XCTest
@testable import ParakattApp

final class ConcurrencyStateTests: XCTestCase {
    func testCompoundMutationsAreAtomic() {
        let counter = Locked(wrappedValue: 0)
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            counter.wrappedValue += 1
        }
        XCTAssertEqual(counter.wrappedValue, 10_000)
    }

    func testConcurrentCancellationCallsTheAcceptedCallbackOnce() {
        let cancellation = SessionCancellation()
        let count = Locked(wrappedValue: 0)
        XCTAssertTrue(cancellation.start({}, onCancel: { count.wrappedValue += 1 }))
        DispatchQueue.concurrentPerform(iterations: 100) { _ in cancellation.cancel() }
        XCTAssertEqual(count.wrappedValue, 1)
    }

    func testConcurrentReservationsDoNotExceedCapacity() {
        let capacity = WorkCapacity(limit: 3)
        let admitted = Locked(wrappedValue: 0)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if capacity.reserve() { admitted.wrappedValue += 1 }
        }
        XCTAssertEqual(admitted.wrappedValue, 3)
        for _ in 0..<3 { capacity.release() }
        XCTAssertFalse(capacity.hasPendingWork)
        XCTAssertFalse(capacity.reserve(-1))
        XCTAssertFalse(capacity.reserve(4))
    }
}
