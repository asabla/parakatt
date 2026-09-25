import XCTest
import AVFoundation
@testable import ParakattApp

final class MicrophoneAuthorizationTests: XCTestCase {
    func testAuthorizedCaptureDoesNotRequestPermission() throws {
        try MicrophoneAuthorization.requireAccess(status: .authorized) { XCTFail("Unexpected permission prompt") }
    }
    func testUndecidedPermissionRequestsAccessButDoesNotStartCapture() {
        var requests = 0
        XCTAssertThrowsError(try MicrophoneAuthorization.requireAccess(status: .notDetermined) { requests += 1 }) { error in
            XCTAssertTrue(error.localizedDescription.contains("start recording again"))
        }
        XCTAssertEqual(requests, 1)
    }
    func testDeniedAndRestrictedCaptureDoNotPromptAgain() {
        for status in [AVAuthorizationStatus.denied, .restricted] {
            XCTAssertThrowsError(try MicrophoneAuthorization.requireAccess(status: status) { XCTFail("Unexpected permission prompt") })
        }
    }
    func testWarmEngineIsNotReusedAfterInputChanges() {
        XCTAssertFalse(AudioCaptureService.warmInputMatches(selectedUID: "builtin", activeUID: "headset", defaultUID: "headset"))
        XCTAssertFalse(AudioCaptureService.warmInputMatches(selectedUID: nil, activeUID: "headset", defaultUID: "builtin"))
        XCTAssertFalse(AudioCaptureService.warmInputMatches(selectedUID: nil, activeUID: nil, defaultUID: nil))
        XCTAssertTrue(AudioCaptureService.warmInputMatches(selectedUID: "builtin", activeUID: "builtin", defaultUID: "headset"))
    }

}
