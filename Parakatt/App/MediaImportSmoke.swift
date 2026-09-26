import Foundation
import ParakattCore

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
