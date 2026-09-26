import Foundation
import CryptoKit
import AVFoundation
import ParakattCore
import Darwin

struct MediaImportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
final class MediaCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    private var download: URLSessionTask?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws { if isCancelled { throw CancellationError() } }
    func register(_ value: Process?) throws {
        lock.lock(); defer { lock.unlock() }
        if stopped { throw CancellationError() }; process = value
    }
    func registerDownload(_ value: URLSessionTask?) { lock.lock(); download = value; let stop = stopped; lock.unlock(); if stop { value?.cancel() } }
    func cancel(immediately: Bool = false) {
        lock.lock(); stopped = true; let child = process; let task = download; lock.unlock()
        task?.cancel()
        guard let child, child.isRunning else { return }
        let pid = child.processIdentifier
        // Foundation normally creates a process group. Never signal our own group.
        if immediately {
            if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            return
        }
        if getpgid(pid) == pid { kill(-pid, SIGTERM) } else { child.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if child.isRunning {
                if getpgid(pid) == pid { kill(-pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
    }
}
struct MediaTrack: Identifiable, Sendable {
    let id: Int32
    let label: String
    let isDefault: Bool
}
struct MediaInfo: Sendable {
    let duration: Double
    let tracks: [MediaTrack]
}

enum MediaTools {
    #if DEBUG
    static var testDirectory: URL?
    #endif
    static var directory: URL {
        #if DEBUG
        if let testDirectory { return testDirectory }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MediaTools", isDirectory: true)
    }
    static func executable(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw MediaImportError("The application is missing its media tools. Install a complete Parakatt release.")
        }
        return url
    }
    static func freeSpace(_ directory: URL, required: Int64 = 256 * 1024 * 1024) throws {
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        guard let bytes = attributes[.systemFreeSize] as? NSNumber, bytes.int64Value > required else {
            throw MediaImportError("There is not enough free disk space. Free space and resume the import.")
        }
    }
    /// stdout and stderr are drained concurrently, with bounded retained output.
    static func run(_ name: String, _ arguments: [String], cancellation: MediaCancellation, limit: Int = 4 * 1024 * 1024, workingDirectory: URL? = nil, progress: ((String) -> Void)? = nil) throws -> Data {
        try cancellation.check()
        let process = Process(); process.executableURL = try executable(name); process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin", "HOME": (workingDirectory ?? FileManager.default.temporaryDirectory).path, "LANG": "en_US.UTF-8", "TMPDIR": (workingDirectory ?? FileManager.default.temporaryDirectory).path, "DENO_NO_UPDATE_CHECK": "1"]
        let output = Pipe(), errors = Pipe(); process.standardOutput = output; process.standardError = errors
        try cancellation.register(process)
        defer { try? cancellation.register(nil) }
        try process.run()
        if cancellation.isCancelled { cancellation.cancel() }
        let group = DispatchGroup()
        final class Capture: @unchecked Sendable { var bytes = Data(); var overflow = false }
        let capture = Capture()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var line = Data()
            while let data = try? output.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                if capture.bytes.count + data.count <= limit { capture.bytes.append(data) } else { capture.overflow = true }
                if let progress {
                    line.append(data)
                    while let end = line.firstIndex(of: 10) {
                        progress(String(decoding: line[..<end], as: UTF8.self)); line.removeSubrange(...end)
                    }
                    if line.count > 16_384 { line.removeAll(keepingCapacity: true) }
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            // Do not log remote titles, URL query strings, or decoder paths.
            while let data = try? errors.fileHandleForReading.read(upToCount: 8192), !data.isEmpty { }
            group.leave()
        }
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        let diskFailure = MediaCancellation()
        let timeoutFailure = MediaCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + (workingDirectory == nil ? 120 : 86_400)
        watchdog.setEventHandler {
            if ProcessInfo.processInfo.systemUptime > deadline { timeoutFailure.cancel(); cancellation.cancel() }
            if let workingDirectory, (try? freeSpace(workingDirectory)) == nil { diskFailure.cancel(); cancellation.cancel() }
        }
        watchdog.resume()
        process.waitUntilExit(); group.wait(); watchdog.cancel()
        if diskFailure.isCancelled { throw MediaImportError("There is not enough free disk space. Free space and resume the import.") }
        if timeoutFailure.isCancelled { throw MediaImportError("The media operation did not finish. Check the source and resume the import.") }
        try cancellation.check()
        guard process.terminationStatus == 0 else { throw MediaImportError(name == "yt-dlp" ? "The video could not be downloaded. Check that it is public and available. A Parakatt update may be required." : "The media could not be read or converted. Check that the file is complete and uses a supported format.") }
        guard !capture.overflow else { throw MediaImportError("The media tool returned more data than expected.") }
        return capture.bytes
    }
    static func probe(_ url: URL, cancellation: MediaCancellation) throws -> MediaInfo {
        let data = try run("ffprobe", ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path], cancellation: cancellation)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let format = object?["format"] as? [String: Any]
        guard let duration = Double(format?["duration"] as? String ?? ""), duration.isFinite, duration > 0 else { throw MediaImportError("The video has no finite duration. Live streams are not supported.") }
        let streams = object?["streams"] as? [[String: Any]] ?? []
        guard streams.contains(where: { $0["codec_type"] as? String == "video" }) else { throw MediaImportError("Select a file with a video track.") }
        let tracks = streams.filter { $0["codec_type"] as? String == "audio" }.enumerated().map { index, stream in
            let tags = stream["tags"] as? [String: Any] ?? [:]
            let label = ["Audio \(index + 1)", tags["language"] as? String, tags["title"] as? String].compactMap { $0 }.joined(separator: " · ")
            return MediaTrack(id: Int32(index), label: label, isDefault: (stream["disposition"] as? [String: Int])?["default"] == 1)
        }
        guard !tracks.isEmpty else { throw MediaImportError("The video has no audio track.") }
        return MediaInfo(duration: duration, tracks: tracks)
    }
    static func fingerprint(_ url: URL, cancellation: MediaCancellation) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try cancellation.check(); hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func samples(_ url: URL, track: Int32, start: Double, duration: Double, cancellation: MediaCancellation) throws -> [Float] {
        try cancellation.check()
        do { return try nativeSamples(url, track: track, start: start, duration: duration, cancellation: cancellation) }
        catch is CancellationError { throw CancellationError() }
        catch { }
        let data = try run("ffmpeg", ["-nostdin", "-v", "error", "-ss", String(start), "-i", url.path, "-map", "0:a:\(track)", "-vn", "-t", String(duration), "-af", "aresample=16000:async=1:first_pts=0", "-ac", "1", "-ar", "16000", "-f", "f32le", "pipe:1"], cancellation: cancellation)
        let count = Int((duration * 16_000).rounded())
        var samples = data.withUnsafeBytes { bytes in stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) } }
        if samples.count < count { samples.append(contentsOf: repeatElement(0, count: count - samples.count)) }
        return Array(samples.prefix(count))
    }
    private static func nativeSamples(_ url: URL, track: Int32, start: Double, duration: Double, cancellation: MediaCancellation) throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = asset.tracks(withMediaType: .audio)
        guard tracks.indices.contains(Int(track)) else { throw MediaImportError("Audio track is unavailable.") }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000), duration: CMTime(seconds: duration, preferredTimescale: 16_000))
        let output = AVAssetReaderTrackOutput(track: tracks[Int(track)], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaImportError("Native audio decoding is unavailable.") }
        reader.add(output); guard reader.startReading() else { throw MediaImportError("Native audio decoding failed.") }
        defer { reader.cancelReading() }
        var samples = [Float](repeating: 0, count: Int((duration * 16_000).rounded()))
        while let buffer = output.copyNextSampleBuffer() {
            try cancellation.check()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { throw MediaImportError("Invalid decoded audio.") }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw MediaImportError("Invalid decoded audio.") }
            let offset = Int(((CMSampleBufferGetPresentationTimeStamp(buffer).seconds - start) * 16_000).rounded())
            data.withUnsafeBytes { bytes in
                for i in 0..<(length / 4) where samples.indices.contains(offset + i) { samples[offset + i] = bytes.loadUnaligned(fromByteOffset: i * 4, as: Float.self) }
            }
        }
        guard reader.status == .completed else { throw MediaImportError("Native audio decoding failed.") }
        return samples
    }
    static func reviewCopy(_ url: URL, track: Int32, destination: URL, cancellation: MediaCancellation) throws {
        try freeSpace(destination.deletingLastPathComponent())
        _ = try run("ffmpeg", ["-nostdin", "-v", "error", "-y", "-i", url.path, "-map", "0:v:0", "-map", "0:a:\(track)", "-vf", "scale=w='min(1920,iw)':h='min(1080,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2", "-c:v", "h264_videotoolbox", "-allow_sw", "1", "-b:v", "8M", "-c:a", "aac", "-movflags", "+faststart", destination.path], cancellation: cancellation, workingDirectory: destination.deletingLastPathComponent())
    }
}
