import Foundation
import ParakattCore
import AVFoundation
import Combine

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
    let playback = MediaPlayback()
    defer { playback.stop(); service.shutdown() }
    var stages: [MediaPlaybackProgress] = []
    var lastPercent = -10
    let subscription = playback.$preparation.compactMap { $0 }.sink { value in
        stages.append(value)
        if case .creatingCopy(let fraction) = value, Int(fraction * 100) >= lastPercent + 10 {
            lastPercent = Int(fraction * 100)
            NSLog("[Parakatt] Playback validation conversion: %d%%", lastPercent)
        }
    }
    defer { subscription.cancel() }
    func waitForPlayer() async throws -> AVPlayer {
        let deadline = ProcessInfo.processInfo.systemUptime + 1800
        while playback.loading {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw MediaImportError("Playback validation timed out") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let player = playback.player, player.currentItem?.status == .readyToPlay else { throw MediaImportError(playback.error ?? "Player not ready") }
        return player
    }
    playback.load(id: job.id, service: service)
    let player = try await waitForPlayer()
    player.isMuted = true
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    player.currentItem?.add(output)
    var frames = 0
    for position in [0, info.duration / 2, max(0, info.duration - 3)] {
        guard await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) else { throw MediaImportError("Playback seek failed") }
        player.play()
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var rendered = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            guard player.currentItem?.status == .readyToPlay else { throw MediaImportError("Player failed after seeking") }
            if player.currentTime().seconds > position + 0.1, output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) != nil { rendered = true; break }
        }
        player.pause()
        guard rendered else { throw MediaImportError("No decoded video frame after seeking") }
        frames += 1
    }
    let conversionUpdates = stages.filter { if case .creatingCopy = $0 { return true }; return false }.count
    playback.stop(); stages.removeAll()
    playback.load(id: job.id, service: service)
    _ = try await waitForPlayer()
    let reused = !stages.contains { if case .creatingCopy = $0 { return true }; return false }
    guard reused, try MediaTools.fingerprint(source, cancellation: MediaCancellation()) == hash else { throw MediaImportError("Playback cache or source integrity check failed") }
    return ["state": "ready", "duration_secs": info.duration, "conversion_updates": conversionUpdates, "seek_frames": frames, "cache_reused": reused, "source_unchanged": true]
}
