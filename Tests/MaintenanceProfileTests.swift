import XCTest
import SwiftUI
import Combine
import SQLite3
import os
import ParakattCore
@testable import ParakattApp

/// Opt-in, deterministic UI workload for Instruments. It captures no microphone audio.
final class MaintenanceProfileTests: XCTestCase {
    @MainActor
    func testRecordingStateDoesNotInvalidateUnrelatedViews() {
        let state = AppState()
        var forwarded = 0
        let subscription = state.objectWillChange.sink { forwarded += 1 }
        for index in 0..<100 {
            state.recording.currentAudioLevel = Float(index % 10) / 10
            state.recording.isRecording = index % 2 == 0
            state.meeting.meetingMicLevel = Float(index % 10) / 10
        }
        XCTAssertEqual(forwarded, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testProfileRecordingHistoryAndTranscriptScroll() throws {
        guard let output = ProcessInfo.processInfo.environment["PARAKATT_UI_PROFILE"] else {
            throw XCTSkip("Set PARAKATT_UI_PROFILE to a JSON output path for the Instruments workload")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path, activeMode: "dictation")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcriptions.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN", nil, nil, nil), SQLITE_OK)
        for index in 0..<1000 {
            let sql = "INSERT INTO transcriptions(id,created_at,duration_secs,source,mode,text) VALUES('fixture-\(index)','2026-09-25T00:00:00Z',60,'meeting','dictation','Searchable meeting fixture \(index)')"
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, nil), SQLITE_OK)
        let state = AppState(bridge: bridge)
        let overlay = RecordingOverlayController(appState: state)
        defer { withExtendedLifetime(overlay) {} }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: TranscriptionHistoryView().environmentObject(state))
        window.makeKeyAndOrderFront(nil)
        let log = OSLog(subsystem: "com.parakatt.maintenance", category: .pointsOfInterest)
        var gaps: [Double] = []
        var previous = CFAbsoluteTimeGetCurrent()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            gaps.append(now - previous)
            previous = now
        }
        defer { timer.invalidate() }
        func runLoop(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        runLoop(0.5)
        os_signpost(.begin, log: log, name: "RecordingState20Hz")
        var controlTimes: [Double] = []
        for index in 0..<100 {
            let start = CFAbsoluteTimeGetCurrent()
            state.recording.isRecording = true
            state.recording.currentAudioLevel = Float(index % 10) / 10
            state.recording.livePreviewTentative = "Recognized fixture \(index)"
            controlTimes.append(CFAbsoluteTimeGetCurrent() - start)
            runLoop(0.05)
        }
        state.recording.isRecording = false
        os_signpost(.end, log: log, name: "RecordingState20Hz")
        os_signpost(.begin, log: log, name: "HistorySearch")
        var searches: [Double] = []
        for index in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            let done = expectation(description: "history query")
            state.queryHistory(search: "fixture \(index)", source: nil) { _ in
                searches.append(CFAbsoluteTimeGetCurrent() - start)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
        os_signpost(.end, log: log, name: "HistorySearch")
        var segments: [TimestampedSegment] = []
        for index in 0..<5000 {
            let text = "Recognized English and Swedish meeting text, segment \(index)."
            let speaker: String? = index % 2 == 0 ? "Me" : nil
            segments.append(TimestampedSegment(text: text, startSecs: Double(index), endSecs: Double(index + 1), speaker: speaker))
        }
        let item = StoredTranscription(id: "long", createdAt: "2026-09-25T00:00:00Z", durationSecs: 5000, source: "meeting", mode: "clean", audioSource: "mixed", appContext: nil, title: "Long fixture", text: "Processed text remains separate.")
        // Start in timeline mode for this deterministic profiling workload.
        window.contentView = NSHostingView(rootView: TranscriptionDetailView(item: item, segments: segments, recognizedText: nil, processingStatus: "completed", hasSpeakerLabels: true, onTitleChanged: { _ in }, onDelete: {}, initiallyShowRecognized: true))
        runLoop(0.5)
        func scrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        let scroll = try XCTUnwrap(window.contentView.flatMap { scrollView($0) })
        os_signpost(.begin, log: log, name: "LongTranscriptScroll")
        for index in 0..<100 {
            let height = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: height * CGFloat(index) / 99))
            scroll.reflectScrolledClipView(scroll.contentView)
            runLoop(0.03)
        }
        os_signpost(.end, log: log, name: "LongTranscriptScroll")
        let report: [String: Any] = ["fixture_rows": 1000, "timeline_segments": 5000, "recording_state_update_secs": controlTimes, "history_query_secs": searches, "main_run_loop_gaps_secs": gaps, "gaps_over_50ms": gaps.filter { $0 > 0.05 }.count, "limitations": "Synthetic UI workload. Run-loop gaps are a responsiveness proxy, not GPU frame times or microphone-control latency. Use the Instruments trace for attribution."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
