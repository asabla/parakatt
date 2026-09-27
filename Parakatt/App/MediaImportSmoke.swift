import Foundation
import ParakattCore
import VLCKit

/// Runs only under the existing explicit maintenance mode with isolated data.
func mediaImportSmoke(core: CoreBridge, source: URL) throws -> [String: Any] {
    let token = MediaCancellation()
    var versions: [String: String] = [:]
    for (name, argument) in [("yt-dlp", "--version"), ("deno", "--version"), ("ffmpeg", "-version"), ("ffprobe", "-version")] {
        let bytes = try MediaTools.run(name, [argument], cancellation: token)
        versions[name] = String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines).first ?? ""
    }
    let info = try MediaTools.probe(source, cancellation: token)
    var job = try core.createImport(kind: "file", input: source.path, title: "Media validation", mode: "dictation")
    job.attachment.path = source.path; job.attachment.durationSecs = (info.duration * 16_000).rounded() / 16_000
    job.attachment.fingerprint = try MediaTools.fingerprint(source, cancellation: token)
    job.attachment.audioTrack = info.tracks.first(where: \.isDefault)?.id ?? 0
    job = try core.attachMedia(job.id, job.attachment)
    job = try core.importState(job.id, "transcribing")
    var maxSamples = 0
    while job.processedUntil + 0.00001 < job.attachment.durationSecs {
        let offset = job.nextChunk == 0 ? 0 : max(0, job.processedUntil - 2)
        let samples = try MediaTools.samples(source, track: job.attachment.audioTrack, start: offset, duration: min(30, job.attachment.durationSecs - offset), cancellation: token)
        maxSamples = max(maxSamples, samples.count)
        job = try core.importChunk(job.id, samples: samples, offset: offset)
    }
    job = try core.importState(job.id, "completed")
    let result = try core.getTranscription(id: job.id)
    let segments = try core.getTranscriptionSegments(id: job.id)
    return ["state": job.state, "duration_secs": job.attachment.durationSecs, "chunks": job.nextChunk, "max_audio_samples": maxSamples, "characters": result.text.count, "segments": segments.count, "srt_bytes": TranscriptExport.subtitles(segments: segments, duration: job.attachment.durationSecs, vtt: false).utf8.count, "tools": versions]
}

/// Uses the same preparation and player state as History, with isolated metadata.
@MainActor
func mediaPlaybackSmoke(core: CoreBridge, source: URL, root: URL) async throws -> [String: Any] {
    let info = try MediaTools.probe(source, cancellation: MediaCancellation())
    let hash = try MediaTools.fingerprint(source, cancellation: MediaCancellation())
    let service = MediaImportService(bridge: core, root: root.appendingPathComponent("media"))
    var job = try core.createImport(kind: "file", input: source.path, title: "Playback validation", mode: "dictation")
    job.attachment.path = source.path; job.attachment.fingerprint = hash
    job.attachment.durationSecs = info.duration; job.attachment.audioTrack = info.tracks.first(where: \.isDefault)?.id ?? 0
    _ = try core.attachMedia(job.id, job.attachment)
    let headless = ProcessInfo.processInfo.environment["PARAKATT_SMOKE_HEADLESS"] == "1"
    let playback = MediaPlayback(headless: headless)
    defer { playback.stop(); service.shutdown() }
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 360), styleMask: .borderless, backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    func waitForPlayer() async throws -> VLCMediaPlayer {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while playback.loading {
            if let view = playback.videoView, window.contentView !== view { window.contentView = view; window.orderFront(nil) }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaImportError("Playback validation timed out") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let player = playback.player else { throw MediaImportError(playback.error ?? "Player not ready") }
        return player
    }
    playback.volume = 0
    playback.load(id: job.id, service: service)
    let player = try await waitForPlayer()
    guard player.media?.url?.standardizedFileURL == source.standardizedFileURL else { throw MediaImportError("Playback did not use the original source") }
    func frameCount() -> Int32 {
        guard let stats = player.media?.statistics else { return 0 }
        return headless ? stats.decodedVideo : stats.displayedPictures
    }
    var frames = 0
    for position in [0, info.duration / 2, max(0, info.duration - 3)] {
        let before = frameCount()
        playback.seek(position)
        player.play()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var rendered = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            let seconds = (player.time.value?.doubleValue ?? 0) / 1000
            if seconds > position + 0.1, seconds < position + 3, frameCount() > before {
                rendered = true; break
            }
        }
        player.pause()
        guard rendered else { throw MediaImportError(headless ? "No decoded video frame after seeking" : "No displayed video frame after seeking") }
        frames += 1
    }
    playback.stop()
    playback.load(id: job.id, service: service)
    _ = try await waitForPlayer()
    let owned = try service.directory(job.id)
    let noCopy = !FileManager.default.fileExists(atPath: owned.appendingPathComponent("review.mp4").path)
    guard noCopy, try MediaTools.fingerprint(source, cancellation: MediaCancellation()) == hash else { throw MediaImportError("Direct playback or source integrity check failed") }
    return ["state": "ready", "duration_secs": info.duration, "seek_frames": frames, "video_output": headless ? "headless" : "window", "direct_playback": true, "playback_copy_created": false, "source_unchanged": true]
}
