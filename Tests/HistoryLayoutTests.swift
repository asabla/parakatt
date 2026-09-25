import XCTest
import SwiftUI
import SQLite3
import ParakattCore
@testable import ParakattApp

final class HistoryLayoutTests: XCTestCase {
    /// Render the real split view in a titled window, including asynchronous history loading.
    /// Set TEST_RUNNER_PARAKATT_LAYOUT_SNAPSHOTS when running xcodebuild to save PNGs.
    @MainActor
    func testHistoryFitsSupportedWindowSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path,
                                    configDir: directory.path, activeMode: "dictation")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("transcriptions.db").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let title = "Planning session with a long title that must leave room for the edit button"
        let paragraph = "This is a sample transcript. The full text must stay below the header and remain readable when the window is resized. Swedish: Det här är en svensk mening."
        let transcript = Array(repeating: paragraph, count: 12).joined(separator: "\n\n")
        let sql = "INSERT INTO transcriptions(id,created_at,duration_secs,source,mode,title,text) VALUES('layout','2026-09-25T12:44:00Z',5023,'meeting','clean','\(title)','\(transcript)')"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let state = AppState(bridge: bridge)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Transcription History"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: TranscriptionHistoryView(selectedId: "layout").environmentObject(state))
        window.contentView = host
        window.orderFront(nil)

        for (name, size, appearance) in [
            ("standard-dark", NSSize(width: 1040, height: 700), NSAppearance.Name.darkAqua),
            ("compact-dark", NSSize(width: 760, height: 480), NSAppearance.Name.darkAqua),
            ("wide-light", NSSize(width: 1440, height: 900), NSAppearance.Name.aqua),
        ] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(size)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            XCTAssertNil(window.toolbar, "A navigation toolbar must not cover the detail header")
            XCTAssertLessThanOrEqual(host.fittingSize.width, size.width)
            XCTAssertLessThanOrEqual(host.fittingSize.height, size.height)

            if let output = ProcessInfo.processInfo.environment["PARAKATT_LAYOUT_SNAPSHOTS"] {
                let destination = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: destination.appendingPathComponent("\(name).png"))
            }
        }
    }

    @MainActor
    func testTimelineFitsNarrowDetailPane() throws {
        let item = StoredTranscription(id: "timeline", createdAt: "2026-09-25T12:44:00Z", durationSecs: 3602,
                                       source: "meeting", mode: "clean", audioSource: "mixed", appContext: nil,
                                       title: "Meeting with a long title that wraps onto a second line", text: "Processed text.")
        var segments: [TimestampedSegment] = []
        for index in 0..<20 {
            let segment = TimestampedSegment(text: "Recognized English and Swedish speech. Det här är en längre svensk mening som ska vara läsbar även i ett smalt fönster.",
                               startSecs: Double(index * 10), endSecs: Double(index * 10 + 9),
                               speaker: index % 2 == 0 ? "A long speaker name" : "Me")
            segments.append(segment)
        }
        let host = NSHostingView(rootView: TranscriptionDetailView(
            item: item, segments: segments, recognizedText: "Recognized speech.", processingStatus: "degraded",
            hasSpeakerLabels: true, onTitleChanged: { _ in }, onDelete: {}, initiallyShowRecognized: true)
            .frame(width: 420, height: 600)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 600),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        func findScrollView(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScrollView($0) }.first
        }
        let scroll = try XCTUnwrap(findScrollView(host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 1,
                                 "Timeline text must wrap rather than extend outside the viewport")
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height,
                             "Long transcripts must scroll within the available content area")
        if let output = ProcessInfo.processInfo.environment["PARAKATT_LAYOUT_SNAPSHOTS"] {
            let destination = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: destination.appendingPathComponent("timeline-dark.png"))
        }
    }

}
