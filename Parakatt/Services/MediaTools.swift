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

enum MediaPlaybackProgress: Equatable, Sendable {
    case checkingSource(Double), checkingPlayback
    var label: String {
        switch self {
        case .checkingSource: return "Checking source video…"
        case .checkingPlayback: return "Opening video player…"
        }
    }
    var fraction: Double? {
        switch self {
        case .checkingSource(let value): return value
        default: return nil
        }
    }
}

/// Only an advancing media timestamp counts as conversion progress.
final class MediaToolProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var timestamp: Double = -1
    private var lastAdvance = ProcessInfo.processInfo.systemUptime
    func update(_ line: String) {
        guard line.hasPrefix("out_time_us="), let value = Double(line.dropFirst(12)), value.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        if value > timestamp { timestamp = value; lastAdvance = ProcessInfo.processInfo.systemUptime }
    }
    func stalled(after timeout: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastAdvance > timeout
    }
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
    /// A pipe read returns available bytes immediately; FileHandle.read(upToCount:)
    /// can wait to fill its buffer and hide live progress from a long-running tool.
    private static func drain(_ handle: FileHandle, consume: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 { consume(Data(buffer.prefix(count))) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
    }
    /// stdout and stderr are drained concurrently, with bounded retained output.
    static func run(_ name: String, _ arguments: [String], cancellation: MediaCancellation, limit: Int = 4 * 1024 * 1024, workingDirectory: URL? = nil, stallTimeout: TimeInterval? = nil, progress: ((String) -> Void)? = nil) throws -> Data {
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
        let activity = MediaToolProgress()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            var line = Data()
            drain(output.fileHandleForReading) { data in
                if progress == nil && stallTimeout == nil {
                    if capture.bytes.count + data.count <= limit { capture.bytes.append(data) } else { capture.overflow = true }
                }
                if progress != nil || stallTimeout != nil {
                    line.append(data)
                    while let end = line.firstIndex(of: 10) {
                        let value = String(decoding: line[..<end], as: UTF8.self)
                        activity.update(value); progress?(value); line.removeSubrange(...end)
                    }
                    if line.count > 16_384 { line.removeAll(keepingCapacity: true) }
                }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            // Do not log remote titles, URL query strings, or decoder paths.
            drain(errors.fileHandleForReading) { _ in }
            group.leave()
        }
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 1, repeating: 1)
        let diskFailure = MediaCancellation()
        let timeoutFailure = MediaCancellation()
        let stallFailure = MediaCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + (workingDirectory == nil ? 120 : 86_400)
        watchdog.setEventHandler {
            if ProcessInfo.processInfo.systemUptime > deadline { timeoutFailure.cancel(); cancellation.cancel() }
            if let stallTimeout, activity.stalled(after: stallTimeout) { stallFailure.cancel(); cancellation.cancel() }
            if let workingDirectory, (try? freeSpace(workingDirectory)) == nil { diskFailure.cancel(); cancellation.cancel() }
        }
        watchdog.resume()
        process.waitUntilExit(); group.wait(); watchdog.cancel()
        if diskFailure.isCancelled { throw MediaImportError("There is not enough free disk space. Free space and resume the import.") }
        if stallFailure.isCancelled { throw MediaImportError("Playback preparation stopped making progress. Try loading the video again.") }
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
    static func fingerprint(_ url: URL, cancellation: MediaCancellation, progress: ((Double) -> Void)? = nil) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
        var read = 0.0, lastReport = 0.0
        progress?(0)
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            try cancellation.check(); hash.update(data: data); read += Double(data.count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport > 0.2 { progress?(size > 0 ? min(1, read / size) : 0); lastReport = now }
        }
        try cancellation.check(); progress?(1)
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
}
