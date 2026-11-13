import SwiftUI
import XCTest
@testable import ParakattApp

final class RecordingOverlayTests: XCTestCase {
    @MainActor
    private func view(recording: Bool, text: String?, minimumHeight: CGFloat = 44) -> RecordingOverlayView {
        RecordingOverlayView(isRecording: recording, isProcessing: !recording, liveText: text,
            committedText: "Preview words", tentativeText: "still tentative", audioLevel: 0,
            silenceDetected: false, clippingDetected: false, inputDeviceName: "Microphone",
            modelStatus: "Ready", minimumHeight: minimumHeight, onStop: {})
    }

    @MainActor
    func testFinishingRetainsPreviewLayoutAndHeight() {
        let preview = String(repeating: "Preview words remain visible while cleanup finishes. ", count: 8)
        let recording = NSHostingView(rootView: view(recording: true, text: preview))
        let finishing = NSHostingView(rootView: view(recording: false, text: preview))
        XCTAssertEqual(recording.fittingSize.width, 400, accuracy: 1)
        XCTAssertGreaterThan(finishing.fittingSize.height, 100)
        let retainedHeight = max(recording.fittingSize.height, finishing.fittingSize.height)
        finishing.rootView = view(recording: false, text: "Final text.", minimumHeight: retainedHeight)
        XCTAssertGreaterThanOrEqual(finishing.fittingSize.height, retainedHeight)
    }

    @MainActor
    func testOldDismissalCannotHideAReshownOverlay() async throws {
        let state = AppState(bridge: nil)
        let controller = RecordingOverlayController(appState: state)
        defer { state.recording.isRecording = false; state.shutdown(); withExtendedLifetime(controller) {} }
        state.recording.isRecording = true
        try await Task.sleep(nanoseconds: 100_000_000)
        let panel = try XCTUnwrap(NSApp.windows.first { $0.identifier?.rawValue == "recordingOverlay" })
        state.recording.isRecording = false
        // Restart after dismissal begins but before its animation completes.
        try await Task.sleep(nanoseconds: 220_000_000)
        state.recording.isRecording = true
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.01)
        let topEdge = panel.frame.maxY
        state.recording.isProcessing = true
        state.recording.isRecording = false
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame.maxY, topEdge, accuracy: 1)
        state.recording.isProcessing = false
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(panel.isVisible)
    }
}
