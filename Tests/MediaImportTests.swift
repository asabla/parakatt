import XCTest
import Network
import AVFoundation
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
    func testDecoderPreservesDelayAndChunkSampleCounts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("delayed.mov")
        let token = MediaCancellation()
        _ = try MediaTools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=4", "-itsoffset", "1", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-c:v", "mpeg4", "-c:a", "pcm_s16le", "-t", "4", url.path], cancellation: token)
        let info = try MediaTools.probe(url, cancellation: token)
        XCTAssertEqual(info.tracks.count, 1); XCTAssertEqual(info.duration, 4, accuracy: 0.01)
        let first = try MediaTools.samples(url, track: 0, start: 0, duration: 2, cancellation: token)
        XCTAssertEqual(first.count, 32000)
        XCTAssertLessThan(first.prefix(15000).map { abs($0) }.max() ?? 1, 0.001)
        XCTAssertGreaterThan(first.suffix(12000).map { abs($0) }.max() ?? 0, 0.01)
        let second = try MediaTools.samples(url, track: 0, start: 2, duration: 2, cancellation: token)
        XCTAssertEqual(second.count, 32000)
        XCTAssertGreaterThan(second.prefix(12000).map { abs($0) }.max() ?? 0, 0.01)
        XCTAssertLessThan(second.suffix(12000).map { abs($0) }.max() ?? 1, 0.001)
        let hash = try MediaTools.fingerprint(url, cancellation: token)
        XCTAssertEqual(hash.count, 64)
    }
    func testMatroskaFallbackAndReviewCopyPreserveTimeline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let review = directory.appendingPathComponent("review.mp4")
        let token = MediaCancellation()
        _ = try MediaTools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=4", "-itsoffset", "1", "-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-c:v", "mpeg4", "-c:a", "flac", "-t", "4", source.path], cancellation: token)
        let samples = try MediaTools.samples(source, track: 0, start: 0, duration: 2, cancellation: token)
        XCTAssertEqual(samples.count, 32000)
        XCTAssertLessThan(samples.prefix(15000).map { abs($0) }.max() ?? 1, 0.001)
        XCTAssertGreaterThan(samples.suffix(12000).map { abs($0) }.max() ?? 0, 0.01)
        try MediaTools.reviewCopy(source, track: 0, destination: review, cancellation: token)
        let playable = try await AVURLAsset(url: review).load(.isPlayable)
        XCTAssertTrue(playable)
        XCTAssertEqual(try MediaTools.probe(review, cancellation: token).duration, 4, accuracy: 0.15)
        let reviewSamples = try MediaTools.samples(review, track: 0, start: 0, duration: 2, cancellation: token)
        XCTAssertLessThan(reviewSamples.prefix(15000).map { abs($0) }.max() ?? 1, 0.005)
        XCTAssertGreaterThan(reviewSamples.suffix(12000).map { abs($0) }.max() ?? 0, 0.01)
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
    func testPlaybackCancellationCacheAndCorruptCopyRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        _ = try MediaTools.run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=4", "-f", "lavfi", "-i", "sine=duration=4", "-c:v", "mpeg4", "-c:a", "flac", source.path], cancellation: MediaCancellation())
        let hash = try MediaTools.fingerprint(source, cancellation: MediaCancellation())
        let core = try CoreBridge(modelsDir: directory.appendingPathComponent("models").path, configDir: directory.appendingPathComponent("config").path)
        let service = MediaImportService(bridge: core, root: directory.appendingPathComponent("media"))
        var job = try core.createImport(kind: "file", input: source.path, title: "Playback test", mode: "dictation")
        job.attachment.path = source.path; job.attachment.fingerprint = hash; job.attachment.durationSecs = 4
        _ = try core.attachMedia(job.id, job.attachment)
        let cancelled = MediaCancellation()
        do {
            _ = try await service.playbackURL(job.id, token: cancelled) { if case .creatingCopy = $0 { cancelled.cancel() } }
            XCTFail("Cancelled conversion must not publish a copy")
        } catch is CancellationError { }
        let owned = try service.directory(job.id)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: owned.path).isEmpty)
        let progress = PlaybackProgressRecorder()
        let copy = try await service.playbackURL(job.id, token: MediaCancellation(), progress: progress.record)
        XCTAssertTrue(progress.values.contains { if case .creatingCopy = $0 { return true }; return false })
        XCTAssertTrue(progress.values.contains(.checkingPlayback))
        XCTAssertTrue(progress.values.contains { if case .creatingCopy(let value) = $0 { return value > 0 }; return $0 == .finishingCopy })
        let cached = PlaybackProgressRecorder()
        let reused = try await service.playbackURL(job.id, token: MediaCancellation(), progress: cached.record)
        XCTAssertEqual(reused, copy)
        XCTAssertFalse(cached.values.contains { if case .creatingCopy = $0 { return true }; return false })
        try Data("broken cached copy".utf8).write(to: copy)
        let repaired = try await service.playbackURL(job.id, token: MediaCancellation())
        let player = try await MediaTools.readyPlayer(repaired, cancellation: MediaCancellation())
        XCTAssertEqual(player.currentItem?.status, .readyToPlay)
        player.replaceCurrentItem(with: nil)
        XCTAssertEqual(try MediaTools.fingerprint(source, cancellation: MediaCancellation()), hash)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: owned.path), ["review.mp4"])
        do {
            _ = try await MediaTools.readyPlayer(repaired, cancellation: MediaCancellation(), timeout: 0)
            XCTFail("Player readiness must have a deadline")
        } catch { XCTAssertTrue(error.localizedDescription.contains("did not become ready")) }
        var native = try core.createImport(kind: "file", input: repaired.path, title: "Native playback", mode: "dictation")
        native.attachment.path = repaired.path; native.attachment.durationSecs = 4
        native.attachment.fingerprint = try MediaTools.fingerprint(repaired, cancellation: MediaCancellation())
        _ = try core.attachMedia(native.id, native.attachment)
        let nativeURL = try await service.playbackURL(native.id, token: MediaCancellation())
        XCTAssertEqual(nativeURL, repaired, "A compatible source must not require another conversion")
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
        oldProgress?(.creatingCopy(0.9))
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

private final class PlaybackProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MediaPlaybackProgress] = []
    var values: [MediaPlaybackProgress] { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ value: MediaPlaybackProgress) { lock.lock(); stored.append(value); lock.unlock() }
}

private final class MediaHTTPFixture {
    let listener: NWListener
    private let queue = DispatchQueue(label: "Parakatt.media-http-test")
    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
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
