import XCTest
import Network
import AVFoundation
import VLCKit
import SQLite3
import ParakattCore
@testable import ParakattApp

final class MediaImportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MediaTools.testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target/media-tools")
    }
    override func tearDown() { MediaTools.testDirectory = nil; super.tearDown() }
    func testLinkPolicyAndYouTubeCanonicalization() throws {
        let (kind, url) = try MediaLink.classify("https://youtu.be/abcdefghijk?t=12&list=123")
        XCTAssertEqual(kind, "youtube"); XCTAssertEqual(url.absoluteString, "https://www.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(try MediaLink.classify("https://example.com/file.mp4?token=secret").0, "direct")
        for value in ["file:///tmp/video.mp4", "https://user:password@example.com/video.mp4", "https://youtube.com/playlist?list=test", "javascript:alert(1)"] { XCTAssertThrowsError(try MediaLink.classify(value)) }
    }
    func testYouTubeBrowserArgumentsRequireExplicitSelection() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertEqual(YouTubeBrowser.anonymous.cookieArguments(home: home), ["--no-cookies-from-browser"])
        let paths: [(YouTubeBrowser, String)] = [(.chrome, "Library/Application Support/Google/Chrome"), (.firefox, "Library/Application Support/Firefox/Profiles"), (.edge, "Library/Application Support/Microsoft Edge"), (.brave, "Library/Application Support/BraveSoftware/Brave-Browser"), (.safari, "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")]
        for (browser, path) in paths {
            XCTAssertEqual(browser.cookieArguments(home: home), ["--cookies-from-browser", "\(browser.rawValue):\(home.appendingPathComponent(path).path)"])
        }
        let legacy = home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data().write(to: legacy)
        XCTAssertEqual(YouTubeBrowser.safari.cookieArguments(home: home), ["--cookies-from-browser", "safari:\(legacy.path)"])
        let arguments = try MediaLink.youtubeArguments(directory: home)
        XCTAssertTrue(arguments.contains("--no-cookies-from-browser"))
        XCTAssertTrue(arguments.contains("--no-cookies"))
        XCTAssertFalse(arguments.contains("--cookies-from-browser"))
    }

    func testYouTubeDownloadUsesSelectedBrowserForBothRequests() throws {
        let fixture = try youtubeToolFixture("""
        for argument in "$@"; do
          if [ "$argument" = '--skip-download' ]; then
            printf '%s\\n' "$@" > metadata.args
            printf '%s\\n' '{"duration":12,"is_live":false}'
            exit 0
          fi
        done
        printf '%s\\n' "$@" > download.args
        printf '%s' 'fixture media' > download.mkv
        printf '%s\\n' 'bytes=12 total=12'
        """)
        defer { try? FileManager.default.removeItem(at: fixture); MediaTools.testDirectory = nil }
        let url = try XCTUnwrap(URL(string: "https://youtu.be/5N12hTixkBg?t=30"))
        let result = try MediaLink.downloadYouTube(url, directory: fixture, cancellation: MediaCancellation(), browser: .chrome, progress: { _ in })
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "fixture media")
        for name in ["metadata.args", "download.args"] {
            let arguments = try String(contentsOf: fixture.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
            XCTAssertTrue(arguments.contains("--cookies-from-browser"))
            XCTAssertTrue(arguments.contains("--no-cookies"), "Do not save a cookie jar")
            XCTAssertFalse(arguments.contains("--no-cookies-from-browser"))
            XCTAssertTrue(arguments.contains("https://www.youtube.com/watch?v=5N12hTixkBg"))
            XCTAssertFalse(arguments.contains(url.absoluteString))
        }
        XCTAssertThrowsError(try MediaLink.downloadYouTube(URL(fileURLWithPath: "/tmp/private"), directory: fixture, cancellation: MediaCancellation(), browser: .chrome, progress: { _ in }))
    }

    func testYouTubeFailureDrainsLargeStderrAndRemovesPrivateTemporaryFiles() throws {
        let fixture = try youtubeToolFixture("""
        printf '%s' "$TMPDIR" > temp-path
        /usr/bin/stat -f '%Lp' "$TMPDIR" > temp-mode
        /usr/bin/touch "$TMPDIR/temporary.sqlite"
        /usr/bin/head -c 131072 /dev/zero >&2
        printf '%s\\n' 'ERROR: [youtube] secret-title https://example.com/?token=secret: Sign in to confirm you’re not a bot.' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture); MediaTools.testDirectory = nil }
        XCTAssertThrowsError(try MediaTools.run("yt-dlp", [], cancellation: MediaCancellation(), workingDirectory: fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Retry with Browser"))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
            XCTAssertFalse(error.localizedDescription.contains("https://"))
        }
        let temporary = try String(contentsOf: fixture.appendingPathComponent("temp-path"), encoding: .utf8)
        XCTAssertFalse(temporary.hasPrefix(fixture.path + "/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary))
        XCTAssertEqual(try String(contentsOf: fixture.appendingPathComponent("temp-mode"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "700")
        for (raw, expected) in [("ERROR: failed to load cookies: secret-path", "browser session could not be read"), ("HTTP Error 429: Too Many Requests", "limited download requests"), ("Video unavailable: private video secret-title", "unavailable or restricted"), ("Unexpected failure: secret-path", "could not be downloaded")] {
            let message = MediaLink.downloadFailure(Data(raw.utf8)).message
            XCTAssertTrue(message.contains(expected))
            XCTAssertFalse(message.contains("secret"))
        }
    }

    func testBundledDownloaderReadsOnlySelectedSyntheticBrowserSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = directory.appendingPathComponent("Library/Application Support/Firefox/Profiles/test.default")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(profile.appendingPathComponent("cookies.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = "CREATE TABLE moz_cookies(host TEXT, name TEXT, value TEXT, path TEXT, expiry INTEGER, isSecure INTEGER); INSERT INTO moz_cookies VALUES('127.0.0.1','parakatt_fixture','synthetic_session','/',4102444800,0);"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let received = Locked(wrappedValue: false)
        let server = try MediaHTTPFixture { request in
            if request.lowercased().contains("cookie: parakatt_fixture=synthetic_session") { received.wrappedValue = true }
        }
        defer { server.stop() }
        let arguments = ["--ignore-config", "--no-plugin-dirs", "--no-update", "--no-remote-components", "--no-cookies", "--no-cache-dir", "--skip-download", "--dump-single-json"]
        let url = server.url("video.mp4").absoluteString
        _ = try MediaTools.run("yt-dlp", arguments + YouTubeBrowser.anonymous.cookieArguments(home: directory) + ["--", url], cancellation: MediaCancellation(), workingDirectory: directory)
        XCTAssertFalse(received.wrappedValue, "Anonymous imports must not load a browser session")
        _ = try MediaTools.run("yt-dlp", arguments + YouTubeBrowser.firefox.cookieArguments(home: directory) + ["--", url], cancellation: MediaCancellation(), workingDirectory: directory)
        XCTAssertTrue(received.wrappedValue, "The real helper must load the explicitly selected fixture profile despite its isolated HOME")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["Library"], "The helper must not save a cookie jar or temporary browser database in import media")
    }

    @MainActor
    func testYouTubeBrowserConsentDoesNotCarryToOtherJobsOrResume() async throws {
        let fixture = try youtubeToolFixture("""
        printf '%s\\n' "$@" > attempt.args
        printf '%s\\n' 'ERROR: [youtube] Sign in to confirm you are not a bot.' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture); MediaTools.testDirectory = nil }
        let core = try CoreBridge(modelsDir: fixture.appendingPathComponent("models").path, configDir: fixture.appendingPathComponent("config").path)
        let service = MediaImportService(bridge: core, root: fixture.appendingPathComponent("media"))
        defer { service.shutdown() }
        service.addLink("https://youtu.be/5N12hTixkBg", mode: "dictation", browser: .firefox)
        let first = try XCTUnwrap(service.activeID)
        service.addLink("https://youtu.be/abcdefghijk", mode: "dictation")
        let second = try XCTUnwrap(service.jobs.first { $0.id != first }?.id)
        try await waitForImports(service)
        func arguments(_ id: String) throws -> String { try String(contentsOf: service.directory(id).appendingPathComponent("attempt.args"), encoding: .utf8) }
        XCTAssertTrue(try arguments(first).contains("--cookies-from-browser\nfirefox:"))
        XCTAssertTrue(try arguments(second).contains("--no-cookies-from-browser"))
        XCTAssertEqual(try core.importJob(first).state, "failed")
        service.resume(first)
        try await waitForImports(service)
        XCTAssertTrue(try arguments(first).contains("--no-cookies-from-browser"))
        service.resume(first, browser: .chrome)
        try await waitForImports(service)
        XCTAssertTrue(try arguments(first).contains("--cookies-from-browser\nchrome:"))
        service.shutdown()
        let restored = MediaImportService(bridge: core, root: fixture.appendingPathComponent("media"))
        defer { restored.shutdown() }
        restored.resume(first)
        try await waitForImports(restored)
        XCTAssertTrue(try arguments(first).contains("--no-cookies-from-browser"))
    }

    private func youtubeToolFixture(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["yt-dlp", "deno"] {
            let url = directory.appendingPathComponent(name)
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        MediaTools.testDirectory = directory
        return directory
    }

    @MainActor
    private func waitForImports(_ service: MediaImportService) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while service.activeID != nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNil(service.activeID, "Fixture imports must finish without network access")
    }
    func testSubtitlesUseSpeechTimingAndEscapeMarkup() {
        let segments = [TimestampedSegment(text: "Hej <värld> & alla", startSecs: 3661.234, endSecs: 3663.5, speaker: nil), TimestampedSegment(text: "Overlap", startSecs: 3663, endSecs: 3664, speaker: nil), TimestampedSegment(text: "Invalid", startSecs: .nan, endSecs: 4, speaker: nil)]
        let srt = TranscriptExport.subtitles(segments: segments, duration: 4000, vtt: false)
        XCTAssertTrue(srt.contains("01:01:01,234 --> 01:01:03,500"))
        XCTAssertTrue(srt.contains("Hej &lt;värld&gt; &amp; alla"))
        XCTAssertTrue(srt.contains("01:01:03,500 --> 01:01:04,000"))
        XCTAssertFalse(srt.contains("Invalid"))
        let vtt = TranscriptExport.subtitles(segments: segments, duration: 4000, vtt: true)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n")); XCTAssertTrue(vtt.contains("01:01:01.234"))
        XCTAssertEqual(TranscriptExport.subtitles(segments: [], duration: 30, vtt: false), "")
    }
    func testDecoderPreservesDelayAndChunkSampleCounts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delayed.mov")
        let token = MediaCancellation()
        _ = try MediaTools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=4", "-itsoffset", "1", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-t", "4", url.path], cancellation: token)
        let info = try MediaTools.probe(url, cancellation: token)
        XCTAssertEqual(info.tracks.count, 1); XCTAssertEqual(info.duration, 4, accuracy: 0.01)
        let first = try await MediaTools.samples(url, track: 0, start: 0, duration: 2, cancellation: token)
        XCTAssertEqual(first.count, 32000)
        XCTAssertLessThan(first.prefix(15000).map { abs($0) }.max() ?? 1, 0.001)
        XCTAssertGreaterThan(first.suffix(12000).map { abs($0) }.max() ?? 0, 0.01)
        let second = try await MediaTools.samples(url, track: 0, start: 2, duration: 2, cancellation: token)
        XCTAssertEqual(second.count, 32000)
        XCTAssertGreaterThan(second.prefix(12000).map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertLessThan(second.suffix(12000).map { abs($0) }.max() ?? 1, 0.001)
        let hash = try MediaTools.fingerprint(url, cancellation: token)
        XCTAssertEqual(hash.count, 64)
    }
    func testMatroskaFallbackPreservesTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let token = MediaCancellation()
        _ = try MediaTools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=4", "-itsoffset", "1", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-c:v", "mpeg4", "-c:a", "flac", "-t", "4", source.path], cancellation: token)
        let samples = try await MediaTools.samples(source, track: 0, start: 0, duration: 2, cancellation: token)
        XCTAssertEqual(samples.count, 32000)
        XCTAssertLessThan(samples.prefix(15000).map { abs($0) }.max() ?? 1, 0.001)
        XCTAssertGreaterThan(samples.suffix(12000).map { abs($0) }.max() ?? 0, 0.01)

    }

    @MainActor
    func testShutdownKeepsInterruptionAndDoesNotStartNextJob() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let core = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.appendingPathComponent("config").path)
        let service = MediaImportService(bridge: core, root: directory.appendingPathComponent("media"))
        service.addLink("https://example.com/first.mp4", mode: "dictation")
        let activeID = try XCTUnwrap(service.activeID)
        service.addLink("https://example.com/second.mp4", mode: "dictation")
        service.shutdown()
        // Let the cancelled queue task finish. It must not overwrite interruption or advance.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(service.activeID)
        XCTAssertEqual(try core.importJob(activeID).state, "interrupted")
        XCTAssertEqual(try core.importJobs().filter { $0.state == "queued" }.count, 1)
        let restored = MediaImportService(bridge: core, root: directory.appendingPathComponent("media"))
        XCTAssertTrue(restored.jobs.allSatisfy { $0.state == "interrupted" })
    }

    @MainActor
    func testRemovingImportMediaPreservesExternalSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("external.mp4")
        try Data("original".utf8).write(to: original)
        let core = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.appendingPathComponent("config").path)
        let service = MediaImportService(bridge: core, root: directory.appendingPathComponent("media"))
        var job = try core.createImport(kind: "file", input: original.path, title: "External", mode: "dictation")
        job.attachment.path = original.path
        _ = try core.attachMedia(job.id, job.attachment)
        let owned = try service.directory(job.id)
        try Data("copy".utf8).write(to: owned.appendingPathComponent("review.mp4"))
        service.removeMedia(job.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path))
        XCTAssertEqual(try service.sourceURL(job), original)
    }

    func testDirectDownloadRedirectUnknownLengthAndInvalidContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try MediaHTTPFixture()
        defer { server.stop() }
        let target = directory.appendingPathComponent("video")
        let token = MediaCancellation()
        try MediaDownload(destination: target, cancellation: token, progress: { _ in }).fetch(server.url("redirect"))
        XCTAssertEqual(try Data(contentsOf: target), Data("fixture-media".utf8))
        XCTAssertThrowsError(try MediaDownload(destination: target, cancellation: token, progress: { _ in }).fetch(server.url("html")))
        XCTAssertThrowsError(try MediaDownload(destination: target, cancellation: token, progress: { _ in }).fetch(server.url("expired")))
        XCTAssertEqual(try Data(contentsOf: target), Data("fixture-media".utf8))
    }

    func testCancellationStopsToolsAndBoundsOutput() throws {
        let token = MediaCancellation()
        token.cancel()
        XCTAssertThrowsError(try MediaTools.run("ffmpeg", ["-version"], cancellation: token))
        XCTAssertThrowsError(try MediaTools.run("ffmpeg", ["-version"], cancellation: MediaCancellation(), limit: 10))
        let running = MediaCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { running.cancel() }
        XCTAssertThrowsError(try MediaTools.run("ffmpeg", ["-v", "error", "-re", "-f", "lavfi", "-i", "sine=duration=120", "-f", "null", "-"], cancellation: running))
    }

    func testPlaybackConversionStallIsReported() throws {
        XCTAssertThrowsError(try MediaTools.run("ffmpeg", ["-v", "error", "-re", "-f", "lavfi", "-i", "sine=duration=120", "-f", "null", "-"], cancellation: MediaCancellation(), stallTimeout: 0.1)) { error in
            XCTAssertTrue((error as? MediaImportError)?.message.contains("stopped making progress") == true)
        }
    }

    func testConversionProgressArrivesBeforeProcessExit() throws {
        let token = MediaCancellation()
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try MediaTools.run("ffmpeg", ["-v", "error", "-nostats", "-progress", "pipe:1", "-stats_period", "0.1", "-re", "-f", "lavfi", "-i", "sine=duration=8", "-f", "null", "-"], cancellation: token, progress: { line in
            if line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)), value > 0 { token.cancel() }
        }))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4, "Progress must stream while the process is running")
    }

    @MainActor
    func testPlaybackUsesOriginalAndSelectedAudioTrack() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        _ = try MediaTools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=4", "-f", "lavfi", "-i", "sine=duration=4", "-f", "lavfi", "-i", "sine=frequency=880:duration=4", "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "mpeg4", "-c:a", "flac", source.path], cancellation: MediaCancellation())
        let hash = try MediaTools.fingerprint(source, cancellation: MediaCancellation())
        let core = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.appendingPathComponent("config").path)
        let service = MediaImportService(bridge: core, root: directory.appendingPathComponent("media"))
        defer { service.shutdown() }
        var job = try core.createImport(kind: "file", input: source.path, title: "Playback test", mode: "dictation")
        job.attachment.path = source.path; job.attachment.fingerprint = hash; job.attachment.durationSecs = 4; job.attachment.audioTrack = 1
        _ = try core.attachMedia(job.id, job.attachment)
        let cancelled = MediaCancellation(); cancelled.cancel()
        do {
            _ = try await service.playbackURL(job.id, token: cancelled)
            XCTFail("Cancelled preparation must not load a player")
        } catch is CancellationError { }
        let owned = try service.directory(job.id)
        let oldCopy = owned.appendingPathComponent("review.mp4")
        try Data("old or corrupt playback copy".utf8).write(to: oldCopy)
        let original = try await service.playbackURL(job.id, token: MediaCancellation())
        XCTAssertEqual(original, source, "Playback must ignore old review copies")
        let headless = ProcessInfo.processInfo.environment["PARAKATT_TEST_HEADLESS_PLAYBACK"] == "1"
        NSLog("[Parakatt] Playback test output: %@", headless ? "headless" : "window")
        let playback = MediaPlayback(headless: headless)
        defer { playback.stop() }
        playback.volume = 0
        // Match History by attaching the video output to an AppKit window.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        playback.load(id: job.id, service: service)
        while playback.loading {
            if let view = playback.videoView, window.contentView !== view { window.contentView = view; window.orderFront(nil) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(playback.error)
        let player = try XCTUnwrap(playback.player)
        let tracks = (player.audioTrackIndexes as? [NSNumber] ?? []).map(\.int32Value).filter { $0 >= 0 }
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(player.currentAudioTrackIndex, tracks[1])
        XCTAssertEqual(player.media?.url, source)
        // The dummy audio sink discards sound and has no hardware mute control.
        if !headless { XCTAssertEqual(player.audio?.isMuted, true, "Loading the first frame must stay silent") }
        playback.rate = 1.5
        XCTAssertEqual(player.rate, 1.5, accuracy: 0.01)
        playback.seek(2)
        playback.togglePlay()
        if !headless { XCTAssertEqual(player.audio?.isMuted, false) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while playback.position < 2, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThanOrEqual(playback.position, 2)
        playback.stop()
        XCTAssertEqual(try MediaTools.fingerprint(source, cancellation: MediaCancellation()), hash)
        XCTAssertEqual(try Data(contentsOf: oldCopy), Data("old or corrupt playback copy".utf8))
        playback.load(timeout: 0) { _, _ in source }
        while playback.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(playback.error?.contains("did not become ready") == true)
        XCTAssertNil(playback.player)
        try Data("changed source".utf8).write(to: source)
        do { _ = try await service.playbackURL(job.id, token: MediaCancellation()); XCTFail("Changed sources must fail validation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("source changed")) }
    }

    @MainActor
    func testObsoletePlaybackCannotOverwriteNewLoad() async throws {
        let playback = MediaPlayback()
        var first: CheckedContinuation<URL, Error>?
        var second: CheckedContinuation<URL, Error>?
        var oldProgress: ((MediaPlaybackProgress) -> Void)?
        playback.load { _, progress in
            oldProgress = progress
            return try await withCheckedThrowingContinuation { first = $0 }
        }
        while first == nil { await Task.yield() }
        playback.load { _, _ in try await withCheckedThrowingContinuation { second = $0 } }
        while second == nil { await Task.yield() }
        oldProgress?(.checkingSource(0.9))
        first?.resume(throwing: MediaImportError("Obsolete error"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(playback.loading)
        XCTAssertNil(playback.error)
        XCTAssertEqual(playback.preparation, .checkingSource(0))
        playback.stop()
        second?.resume(returning: URL(fileURLWithPath: "/does-not-exist"))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(playback.loading)
        XCTAssertNil(playback.player)
        XCTAssertNil(playback.error)
        playback.load { _, _ in throw MediaImportError("The source changed. Locate the original video.") }
        for _ in 0..<100 where playback.loading { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(playback.loading)
        XCTAssertEqual(playback.error, "The source changed. Locate the original video.")
    }
}


private final class MediaHTTPFixture {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Parakatt.media-http-test")
    init(onRequest: @escaping @Sendable (String) -> Void = { _ in }) throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                onRequest(request)
                let response: String
                if request.contains("GET /redirect ") { response = "HTTP/1.1 302 Found\r\nLocation: /media\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
                else if request.contains("GET /html ") { response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<html>Not media</html>" }
                else if request.contains("GET /expired ") { response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
                else { response = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nConnection: close\r\n\r\nfixture-media" }
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else { throw MediaImportError("Test server did not start") }
    }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")! }
    func stop() { listener.newConnectionHandler = nil; listener.cancel() }
}
