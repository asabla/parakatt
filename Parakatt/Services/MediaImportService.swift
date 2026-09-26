import AppKit
import AVFoundation
import Combine
import Foundation
import ParakattCore

@MainActor
final class MediaImportService: ObservableObject {
    @Published private(set) var jobs: [ImportJob] = []
    @Published private(set) var activeID: String?
    @Published private(set) var transferProgress: Double?
    @Published var error: String?
    @Published var trackChoice: TrackChoice?
    struct TrackChoice: Identifiable { let id: String; let tracks: [MediaTrack] }
    private var trackContinuation: CheckedContinuation<Int32, Error>?
    private var task: Task<Void, Never>?
    private var cancellation = MediaCancellation()
    private var shuttingDown = false
    private var playbackCancellations: [UUID: MediaCancellation] = [:]
    private let bridge: CoreBridge
    let root: URL
    var canTranscribe: () -> Bool = { true }
    var modelReady: () -> Bool = { true }
    var onChange: () -> Void = {}
    init(bridge: CoreBridge, root: URL) {
        self.bridge = bridge; self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for job in try bridge.importJobs() where !["completed", "paused", "failed", "interrupted"].contains(job.state) {
                _ = try bridge.importState(job.id, "interrupted", message: "Import interrupted. Resume when ready.")
            }
            refresh()
        } catch { self.error = "The import queue could not be opened." }
    }
    func refresh() {
        do { jobs = try bridge.importJobs(); onChange() }
        catch { self.error = "The import queue could not be read." }
    }
    func directory(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw MediaImportError("Invalid media identifier.") }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    func addFile(_ url: URL, mode: String) {
        do {
            guard ["mp4", "mov", "mkv", "webm"].contains(url.pathExtension.lowercased()) else { throw MediaImportError("Select an MP4, MOV, MKV, or WebM video.") }
            var job = try bridge.createImport(kind: "file", input: url.path, title: url.deletingPathExtension().lastPathComponent, mode: mode)
            job.attachment.path = url.path; job.attachment.bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            _ = try bridge.attachMedia(job.id, job.attachment); refresh(); startNext()
        } catch { self.error = error.localizedDescription }
    }
    func addLink(_ value: String, mode: String) {
        do {
            let (kind, url) = try MediaLink.classify(value)
            _ = try bridge.createImport(kind: kind, input: url.absoluteString, title: kind == "youtube" ? "YouTube video" : (url.lastPathComponent.isEmpty ? "Linked video" : url.lastPathComponent), mode: mode)
            refresh(); startNext()
        } catch { self.error = error.localizedDescription }
    }
    func resume(_ id: String) {
        do { _ = try bridge.importState(id, "queued"); refresh(); startNext() }
        catch { self.error = "The import could not be resumed." }
    }
    func pause(_ id: String) {
        if activeID == id {
            cancellation.cancel(); task?.cancel()
            trackContinuation?.resume(throwing: CancellationError()); trackContinuation = nil; trackChoice = nil
        }
        do { _ = try bridge.importState(id, "paused", message: "Paused. Committed text has been kept."); refresh() }
        catch { self.error = "The import could not be paused." }
    }
    func chooseTrack(_ track: Int32) { trackContinuation?.resume(returning: track); trackContinuation = nil; trackChoice = nil }
    func shutdown() {
        shuttingDown = true
        cancellation.cancel(immediately: true); task?.cancel()
        for token in playbackCancellations.values { token.cancel(immediately: true) }
        trackContinuation?.resume(throwing: CancellationError()); trackContinuation = nil; trackChoice = nil
        if let activeID {
            _ = try? bridge.importState(activeID, "interrupted", message: "Import interrupted. Resume when ready.")
        }
        activeID = nil; transferProgress = nil
        refresh()
    }
    private func startNext() {
        guard !shuttingDown, task == nil, let job = jobs.first(where: { $0.state == "queued" }) else { return }
        activeID = job.id; transferProgress = nil; cancellation = MediaCancellation()
        let token = cancellation
        task = Task { [weak self] in
            guard let self else { return }
            await run(job, token: token)
            task = nil; activeID = nil; transferProgress = nil; refresh(); startNext()
        }
    }
    private func work<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try body() }.value
    }
    private func state(_ id: String, _ value: String, _ message: String = "") throws {
        guard !shuttingDown else { throw CancellationError() }
        _ = try bridge.importState(id, value, message: message); refresh()
    }
    private func run(_ initial: ImportJob, token: MediaCancellation) async {
        let id = initial.id
        do {
            try token.check()
            guard modelReady() else { throw MediaImportError("Set up the speech model in Settings, then resume the import.") }
            let directory = try directory(id)
            var job = try bridge.importJob(id)
            let url: URL
            if job.kind == "file" { url = try sourceURL(job) }
            else if !job.attachment.path.isEmpty, FileManager.default.fileExists(atPath: job.attachment.path) { url = try sourceURL(job) }
            else {
                guard job.nextChunk == 0 else { throw MediaImportError("The downloaded source is missing. Locate the same video to resume, or start a new import.") }
                try state(id, "downloading")
                guard let remote = URL(string: job.input) else { throw MediaImportError("The saved media link is invalid.") }
                let progress: (Double?) -> Void = { [weak self] value in Task { @MainActor in if self?.activeID == id { self?.transferProgress = value } } }
                url = try await work {
                    if job.kind == "youtube" { return try MediaLink.downloadYouTube(remote, directory: directory, cancellation: token, progress: progress) }
                    let target = directory.appendingPathComponent("source.media")
                    try MediaDownload(destination: target, cancellation: token, progress: progress).fetch(remote)
                    return target
                }
            }
            if job.nextChunk == 0, job.attachment.path != url.path { job.attachment.path = url.path; job = try bridge.attachMedia(id, job.attachment) }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try state(id, "preparing", "Checking media and source identity…")
            guard job.checkpointVersion == 1 else { throw MediaImportError("The source changed during a previous attempt. Start a new import.") }
            let originalAttributes = try sourceIdentity(url)
            let info = try await work { try MediaTools.probe(url, cancellation: token) }
            let fingerprint = try await work { try MediaTools.fingerprint(url, cancellation: token) }
            try token.check()
            var track = job.attachment.audioTrack
            if job.attachment.fingerprint.isEmpty {
                track = info.tracks.first(where: \.isDefault)?.id ?? info.tracks[0].id
                if info.tracks.count > 1 {
                    track = try await withCheckedThrowingContinuation { continuation in
                        trackContinuation = continuation; trackChoice = TrackChoice(id: id, tracks: info.tracks)
                    }
                }
            }
            job.attachment.path = url.path; job.attachment.fingerprint = fingerprint; job.attachment.audioTrack = track
            job.attachment.durationSecs = (info.duration * 16_000).rounded() / 16_000
            job = try bridge.attachMedia(id, job.attachment)
            try state(id, "transcribing")
            let bridge = self.bridge
            while true {
                try token.check()
                while !canTranscribe() {
                    try await Task.sleep(nanoseconds: 300_000_000); try token.check()
                }
                try await work { try bridge.processImportText(id) }
                job = try bridge.importJob(id)
                if job.processedUntil + 0.00001 >= job.attachment.durationSecs { break }
                let offset = job.nextChunk == 0 ? 0 : max(0, job.processedUntil - 2)
                let length = min(30, job.attachment.durationSecs - offset)
                guard try sourceIdentity(url) == originalAttributes else { try bridge.invalidateImportSource(id); throw MediaImportError("The source changed during transcription. Start a new import.") }
                let samples = try await work { try MediaTools.samples(url, track: track, start: offset, duration: length, cancellation: token) }
                try token.check()
                while !canTranscribe() { try await Task.sleep(nanoseconds: 300_000_000); try token.check() }
                guard try sourceIdentity(url) == originalAttributes else { try bridge.invalidateImportSource(id); throw MediaImportError("The source changed during transcription. Start a new import.") }
                _ = try await work { try bridge.importChunk(id, samples: samples, offset: offset) }
                refresh()
            }
            try token.check()
            let finalFingerprint = try await work { try MediaTools.fingerprint(url, cancellation: token) }
            guard finalFingerprint == fingerprint else { try bridge.invalidateImportSource(id); throw MediaImportError("The source changed during transcription. Start a new import with the unchanged video.") }
            try state(id, "completed")
        } catch is CancellationError {
            guard !shuttingDown else { return }
            if (try? bridge.importJob(id)) != nil { try? state(id, "paused", "Paused. Committed text has been kept.") }
        } catch {
            guard !shuttingDown else { return }
            if token.isCancelled, !(error is MediaImportError) {
                if (try? bridge.importJob(id)) != nil { try? state(id, "paused", "Paused. Committed text has been kept.") }; return
            }
            let message = (error as? MediaImportError)?.message ?? (error is CoreError ? error.localizedDescription : "The import could not continue. Check the source and try again.")
            if (try? bridge.importJob(id)) != nil { try? state(id, "failed", message) }
        }
    }
    private func sourceIdentity(_ url: URL) throws -> String {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return "\(values[.systemFileNumber] ?? ""):\(values[.size] ?? ""):\(values[.modificationDate] ?? "")"
    }
    func sourceURL(_ job: ImportJob) throws -> URL {
        if job.kind == "file", !job.attachment.bookmark.isEmpty {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: Data(job.attachment.bookmark), options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale), FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let url = URL(fileURLWithPath: job.attachment.path)
        guard !job.attachment.path.isEmpty, FileManager.default.fileExists(atPath: url.path) else { throw MediaImportError("The source video is missing. Use Locate File to select it again.") }
        // Download paths are restricted to the app-owned job directory, including after restore.
        if job.kind != "file" {
            let parent = try directory(job.id).resolvingSymlinksInPath().path + "/"
            guard url.resolvingSymlinksInPath().path.hasPrefix(parent) else { throw MediaImportError("Locate the source video again after restoring this backup.") }
        }
        return url
    }
    func locate(_ id: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                var job = try bridge.importJob(id); let token = MediaCancellation()
                let fingerprint = try await work { try MediaTools.fingerprint(url, cancellation: token) }
                guard job.attachment.fingerprint.isEmpty || fingerprint == job.attachment.fingerprint else { throw MediaImportError("This is a different video. Select the original source or start a new import.") }
                if job.kind == "file" {
                    job.attachment.path = url.path; job.attachment.bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                } else {
                    let destination = try directory(id).appendingPathComponent("source.media")
                    try await work { try MediaTools.freeSpace(destination.deletingLastPathComponent()); if url != destination { if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }; try FileManager.default.copyItem(at: url, to: destination) } }
                    job.attachment.path = destination.path
                }
                _ = try bridge.attachMedia(id, job.attachment); refresh()
            } catch { self.error = error.localizedDescription }
        }
    }
    func removeMedia(_ id: String) {
        guard activeID != id else { error = "Pause this import before removing its media."; return }
        do {
            let directory = try directory(id)
            try FileManager.default.removeItem(at: directory)
            refresh()
        } catch { self.error = "The downloaded media could not be removed." }
    }
    func discard(_ id: String) {
        let pending = activeID == id ? task : nil
        if pending != nil { pause(id) }
        Task {
            await pending?.value
            do { try bridge.deleteTranscription(id: id); try FileManager.default.removeItem(at: directory(id)); refresh() }
            catch { self.error = "The import could not be removed." }
        }
    }
    func attachment(_ id: String) -> ImportJob? { try? bridge.importJob(id) }
    func playbackURL(_ id: String, token: MediaCancellation) async throws -> URL {
        guard !shuttingDown else { throw CancellationError() }
        let requestID = UUID()
        playbackCancellations[requestID] = token
        defer { playbackCancellations.removeValue(forKey: requestID) }
        try token.check()
        var job = try bridge.importJob(id)
        let url = try sourceURL(job)
        let directory = try directory(id)
        let expected = job.attachment.fingerprint
        let actual = try await work { try MediaTools.fingerprint(url, cancellation: token) }
        guard !expected.isEmpty, expected == actual else { throw MediaImportError("The source changed. Locate the original video for synchronized playback.") }
        let proxy = directory.appendingPathComponent("review.mp4")
        if FileManager.default.fileExists(atPath: proxy.path) { return proxy }
        let track = job.attachment.audioTrack
        let playable = try await AVURLAsset(url: url).load(.isPlayable)
        // A review copy also fixes playback to the selected non-default audio track.
        if playable && track == 0 { return url }
        let partial = directory.appendingPathComponent("review.partial.mp4")
        defer { try? FileManager.default.removeItem(at: partial) }
        try await work { try MediaTools.reviewCopy(url, track: track, destination: partial, cancellation: token) }
        try token.check(); try FileManager.default.moveItem(at: partial, to: proxy)
        job.attachment.reviewPath = proxy.path; _ = try bridge.attachMedia(id, job.attachment)
        return proxy
    }
}
