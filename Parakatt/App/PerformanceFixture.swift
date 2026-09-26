import AppKit
import SwiftUI
import SQLite3
import ParakattCore
import os
import Darwin

/// Opt-in workload in the actual app process. Uses only synthetic data, isolated
/// storage, and simulated meter updates. Never starts capture or contacts an LLM.
@MainActor
func runPerformanceFixtureIfRequested() -> Bool {
    guard let output = ProcessInfo.processInfo.environment["PARAKATT_UI_WORKLOAD"] ?? (Bundle.main.object(forInfoDictionaryKey: "ParakattPerformanceOutput") as? String) else { return false }
    Task { @MainActor in
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            if let gate = ProcessInfo.processInfo.environment["PARAKATT_PROFILE_GATE"] {
                let deadline = Date().addingTimeInterval(60)
                while !FileManager.default.fileExists(atPath: gate) {
                    guard Date() < deadline else { throw FixtureError.profilerTimeout }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.path)
            var database: OpaquePointer?
            guard sqlite3_open(directory.appendingPathComponent("transcriptions.db").path, &database) == SQLITE_OK else { throw FixtureError.database }
            defer { sqlite3_close(database) }
            sqlite3_exec(database, "BEGIN", nil, nil, nil)
            for index in 0..<1000 {
                guard sqlite3_exec(database, "INSERT INTO transcriptions(id,created_at,duration_secs,source,mode,title,text) VALUES('fixture-\(index)','2026-09-26T00:00:00Z',60,'meeting','dictation','Synthetic meeting \(index)','Searchable fixture \(index)')", nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
            }
            sqlite3_exec(database, "COMMIT", nil, nil, nil)
            let state = AppState(bridge: bridge)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Parakatt performance fixture — synthetic data"
            window.contentView = NSHostingView(rootView: TranscriptionHistoryView(selectedId: "fixture-0").environmentObject(state))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let overlay = RecordingOverlayController(appState: state)
            defer { window.close(); withExtendedLifetime(overlay) {} }
            var memory: [String: UInt64] = ["history_start": fixtureResidentBytes()]
            var gaps: [Double] = []
            var previous = CFAbsoluteTimeGetCurrent()
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
                let now = CFAbsoluteTimeGetCurrent()
                gaps.append(now - previous)
                previous = now
            }
            defer { timer.invalidate() }
            let log = OSLog(subsystem: "com.parakatt.performance", category: .pointsOfInterest)
            try await Task.sleep(nanoseconds: 500_000_000)
            os_signpost(.begin, log: log, name: "HistorySearch")
            var searches: [Double] = []
            for index in 0..<20 {
                let start = CFAbsoluteTimeGetCurrent()
                await withCheckedContinuation { continuation in
                    state.queryHistory(search: "fixture \(index)", source: nil) { _ in
                        searches.append(CFAbsoluteTimeGetCurrent() - start)
                        continuation.resume()
                    }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            memory["history_end"] = fixtureResidentBytes()
            os_signpost(.end, log: log, name: "HistorySearch")
            os_signpost(.begin, log: log, name: "RecordingOverlay")
            state.recording.inputDeviceName = "Simulated input"
            state.recording.modelStatus = "Synthetic workload"
            state.recording.isRecording = true
            for index in 0..<100 {
                state.recording.currentAudioLevel = Float(index % 10) / 10
                state.recording.livePreviewCommitted = "Synthetic recognized text, section \(index)."
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            state.recording.isRecording = false
            memory["overlay_end"] = fixtureResidentBytes()
            os_signpost(.end, log: log, name: "RecordingOverlay")
            var segments: [TimestampedSegment] = []
            for index in 0..<5000 {
                segments.append(TimestampedSegment(text: "English and Swedish fixture text. Det här är en svensk mening, avsnitt \(index).", startSecs: Double(index), endSecs: Double(index+1), speaker: index % 2 == 0 ? "Me" : "Remote speaker"))
            }
            let item = StoredTranscription(id: "timeline", createdAt: "2026-09-26T00:00:00Z", durationSecs: 5000, source: "meeting", mode: "dictation", audioSource: "mixed", appContext: nil, title: "Synthetic long transcript", text: "Synthetic text.")
            window.contentView = NSHostingView(rootView: TranscriptionDetailView(item: item, segments: segments, recognizedText: nil, processingStatus: "completed", hasSpeakerLabels: true, onTitleChanged: { _ in }, onDelete: {}, initiallyShowRecognized: true).environmentObject(state).frame(minWidth: 760, minHeight: 480))
            try await Task.sleep(nanoseconds: 500_000_000)
            @MainActor func findScroll(_ view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap { findScroll($0) }.first
            }
            guard let scroll = window.contentView.flatMap({ findScroll($0) }) else { throw FixtureError.scrollView }
            os_signpost(.begin, log: log, name: "LongTranscriptScroll")
            for index in 0..<100 {
                let height = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: height * CGFloat(index) / 99))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            memory["scroll_end"] = fixtureResidentBytes()
            os_signpost(.end, log: log, name: "LongTranscriptScroll")
            let report: [String: Any] = ["completed": true, "process": "Parakatt", "os": ProcessInfo.processInfo.operatingSystemVersionString, "resident_bytes": memory, "fixture_rows": 1000, "timeline_segments": 5000, "history_query_seconds": searches, "main_run_loop_gaps_seconds": gaps, "gaps_over_50ms": gaps.filter { $0 > 0.05 }.count, "limitations": "Real app process, synthetic data. Run-loop intervals are not compositor frame times. No live audio, inference, or LLM requests."]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        } catch {
            let report: [String: Any] = ["completed": false, "error": error.localizedDescription]
            try? JSONSerialization.data(withJSONObject: report).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
        NSApp.terminate(nil)
    }
    return true
}
private enum FixtureError: Error { case database, scrollView, profilerTimeout }

private func fixtureResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
}
