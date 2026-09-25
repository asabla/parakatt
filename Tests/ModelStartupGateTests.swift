import XCTest
@testable import ParakattApp

final class ModelStartupGateTests: XCTestCase {
    @MainActor
    func testRecordingAndStopWaitForTheModelWithoutLosingTheirWork() {
        let gate = ModelStartupGate()
        gate.update(.loading)
        var work: [String] = []
        gate.whenReady { error in XCTAssertNil(error); work.append("recorded chunk") }
        gate.whenReady { error in XCTAssertNil(error); work.append("final audio") }
        XCTAssertTrue(work.isEmpty)
        gate.update(.ready)
        XCTAssertEqual(work, ["recorded chunk", "final audio"])
        gate.update(.ready)
        XCTAssertEqual(work.count, 2)
    }
    @MainActor
    func testFailedLoadingReleasesWaitersWithAnError() {
        let gate = ModelStartupGate()
        gate.update(.loading)
        var failure: String?
        gate.whenReady { failure = $0 }
        gate.update(.failed("Model verification failed"))
        XCTAssertEqual(failure, "Model verification failed")
    }
    @MainActor
    func testReadyAndUnavailableStatesCompleteImmediately() {
        let gate = ModelStartupGate()
        var calls = 0
        gate.whenReady { XCTAssertNotNil($0); calls += 1 }
        gate.update(.ready)
        gate.whenReady { XCTAssertNil($0); calls += 1 }
        XCTAssertEqual(calls, 2)
    }
}
