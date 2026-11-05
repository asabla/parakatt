import XCTest
@testable import ParakattApp

final class HotkeyServiceTests: XCTestCase {
    @MainActor
    private final class Recording: HotkeyRecording {
        var isRecording = false
        private var generation = UUID()
        var hotkeyRecordingID: UUID? { isRecording ? generation : nil }
        var starts = 0
        var stops = 0
        var canStart = true
        func startRecording() { starts += 1; generation = UUID(); isRecording = canStart }
        func stopRecording() { stops += 1; isRecording = false }
    }

    @MainActor
    func testToggleRecoversAfterFailedStartAndExternalStop() {
        let recording = Recording()
        let hotkey = HotkeyService(appState: recording, mode: "toggle", registerEvents: false)
        recording.canStart = false
        hotkey.handleKeyDown()
        recording.canStart = true
        hotkey.handleKeyDown()
        XCTAssertTrue(recording.isRecording)
        recording.stopRecording()
        hotkey.handleKeyDown()
        XCTAssertTrue(recording.isRecording)
        hotkey.handleKeyDown()
        XCTAssertFalse(recording.isRecording)
        XCTAssertEqual(recording.starts, 3)
    }

    @MainActor
    func testImmediateModifierReleaseFollowsTheQueuedStart() async {
        let recording = Recording()
        let hotkey = HotkeyService(appState: recording, registerEvents: false)
        hotkey.enqueueKeyDown()
        hotkey.enqueueModifierChange([])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                XCTAssertEqual(recording.starts, 1)
                XCTAssertEqual(recording.stops, 1)
                XCTAssertFalse(recording.isRecording)
                continuation.resume()
            }
        }
    }

    @MainActor
    func testHoldStopsOnlyItsRecordingAndReconfigurationStopsAnActiveHold() {
        let recording = Recording()
        let hotkey = HotkeyService(appState: recording, registerEvents: false)
        recording.isRecording = true
        hotkey.handleKeyDown()
        hotkey.handleModifierChange([])
        XCTAssertTrue(recording.isRecording)
        recording.stopRecording()
        hotkey.handleKeyDown()
        hotkey.handleModifierChange([])
        XCTAssertFalse(recording.isRecording)
        hotkey.handleKeyDown()
        hotkey.reconfigure(key: .space, modifiers: [.option], mode: "toggle")
        XCTAssertFalse(recording.isRecording)
        hotkey.reconfigure(key: .space, modifiers: [.option], mode: "hold")
        hotkey.handleKeyDown()
        recording.stopRecording()
        recording.startRecording()
        hotkey.handleModifierChange([])
        XCTAssertTrue(recording.isRecording, "Releasing an old hold must preserve a later recording")
    }
}
