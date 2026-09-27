import SwiftUI
import VLCKit

@MainActor
final class MediaPlayback: ObservableObject {
    @Published private(set) var player: VLCMediaPlayer?
    @Published var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    @Published var loading = false
    @Published var error: String?
    @Published private(set) var preparation: MediaPlaybackProgress?
    @Published var follow = false
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    @Published var volume: Double = 1 { didSet { player?.audio?.volume = Int32(volume * 100) } }
    private(set) var videoView: VLCVideoView?
    private var token = MediaCancellation()
    private var task: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var accessedURL: URL?

    func load(id: String, service: MediaImportService) {
        let attachment = service.attachment(id)?.attachment
        load(track: attachment?.audioTrack ?? 0, duration: attachment?.durationSecs ?? 0) { token, progress in
            try await service.playbackURL(id, token: token, progress: progress)
        }
    }

    // The closure lets tests control preparation without changing the player lifecycle.
    func load(track: Int32 = 0, duration: Double = 0, timeout: TimeInterval = 20,
              prepare: @escaping (MediaCancellation, @escaping (MediaPlaybackProgress) -> Void) async throws -> URL) {
        stop(); loading = true; error = nil; preparation = .checkingSource(0)
        self.duration = duration
        let token = self.token
        task = Task {
            defer { if self.token === token { task = nil } }
            do {
                let url = try await prepare(token, { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.token === token, !token.isCancelled, self.loading else { return }
                        self.preparation = progress
                    }
                })
                try token.check(); try Task.checkCancellation()
                guard self.token === token else { return }
                guard url.isFileURL else { throw MediaImportError("Download the video before loading playback.") }
                if url.startAccessingSecurityScopedResource() { accessedURL = url }
                preparation = .checkingPlayback
                let view = VLCVideoView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
                view.backColor = .black
                let player = VLCMediaPlayer(options: ["--ignore-config", "--no-video-title-show", "--no-osd", "--no-sub-autodetect-file", "--no-metadata-network-access", "--no-snapshot-preview", "--quiet"])
                player.drawable = view
                let media = VLCMedia(url: url)
                // VLC's audio-track option is an ordinal, as is the import's audio track.
                media.addOption(":audio-track=\(track)")
                media.addOption(":sub-track=-1")
                player.media = media
                videoView = view; self.player = player
                player.audio?.isMuted = true
                player.play()
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                while true {
                    try token.check(); try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw MediaImportError("The video player did not become ready. Check the source file and try again.")
                    }
                    guard player.state != .error, player.state != .ended else {
                        throw MediaImportError("The video player could not open this video.")
                    }
                    if player.hasVideoOut, media.statistics.decodedVideo > 0 {
                        let indexes = (player.audioTrackIndexes as? [NSNumber] ?? []).map(\.int32Value).filter { $0 >= 0 }
                        guard track >= 0, Int(track) < indexes.count else {
                            throw MediaImportError("The imported audio track is not available in this video.")
                        }
                        player.currentAudioTrackIndex = indexes[Int(track)]
                        break
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                player.pause()
                player.time = VLCTime(number: 0)
                player.rate = rate
                player.audio?.volume = Int32(volume * 100)
                player.audio?.isMuted = false
                if self.duration <= 0 { self.duration = (media.length.value?.doubleValue ?? 0) / 1000 }
                loading = false; preparation = nil
                monitor = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard let self, self.token === token, !Task.isCancelled else { return }
                        if player.state == .error {
                            self.stop(); self.error = "Video playback failed. Check the source file and try again."; return
                        }
                        self.playing = player.isPlaying
                        let seconds = (player.time.value?.doubleValue ?? 0) / 1000
                        if seconds.isFinite { self.position = max(0, min(self.duration, seconds)) }
                    }
                }
            } catch is CancellationError {
                if self.token === token { stop() }
            } catch {
                guard self.token === token else { return }
                stop()
                self.error = (error as? MediaImportError)?.message ?? "The video could not be opened. Check the source file and try again."
            }
        }
    }

    func togglePlay() {
        guard let player, !loading else { return }
        if player.isPlaying { player.pause(); playing = false }
        else {
            if position >= duration - 0.25 { seek(0) }
            player.play(); player.rate = rate; playing = true
        }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, let player, player.isSeekable else { return }
        position = max(0, min(duration, seconds))
        player.time = VLCTime(number: NSNumber(value: position * 1000))
    }
    func stop() {
        token.cancel(); token = MediaCancellation(); task?.cancel(); task = nil
        monitor?.cancel(); monitor = nil; loading = false; preparation = nil
        position = 0; duration = 0; playing = false
        let oldPlayer = player, oldView = videoView, oldURL = accessedURL
        player = nil; videoView = nil; accessedURL = nil
        oldPlayer?.audio?.isMuted = true
        oldPlayer?.stop()
        // VLCKit stops asynchronously. Retain the player, drawable and file access until
        // decoding stops; releasing them earlier can crash or close a source still in use.
        Task { @MainActor in
            if let oldPlayer {
                repeat { try? await Task.sleep(nanoseconds: 50_000_000) } while oldPlayer.state != .stopped
                oldPlayer.drawable = nil; oldPlayer.media = nil
            }
            withExtendedLifetime(oldView) { oldURL?.stopAccessingSecurityScopedResource() }
        }
    }
}

private struct MediaVideoSurface: NSViewRepresentable {
    let view: VLCVideoView
    func makeNSView(context: Context) -> VLCVideoView { view }
    func updateNSView(_ nsView: VLCVideoView, context: Context) { }
}

struct MediaPlaybackView: View {
    let id: String
    @ObservedObject var playback: MediaPlayback
    @ObservedObject var service: MediaImportService
    @State private var seeking = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Keep the drawable mounted during loading so readiness includes video output.
            if playback.player != nil, let view = playback.videoView {
                MediaVideoSurface(view: view).frame(height: 220)
            }
            if playback.loading {
                HStack {
                    if let value = playback.preparation?.fraction { ProgressView(value: value).frame(width: 100) }
                    else { ProgressView().controlSize(.small) }
                    Text(playback.preparation?.label ?? "Opening video…")
                    Button("Cancel") { playback.stop() }
                }
            } else if playback.player != nil {
                HStack {
                    Button(playback.playing ? "Pause" : "Play") { playback.togglePlay() }.frame(width: 55)
                    Slider(value: Binding(get: { seeking ? seekPosition : playback.position }, set: { seekPosition = $0; if !seeking { playback.seek($0) } }), in: 0...max(0.01, playback.duration), onEditingChanged: { editing in
                        seeking = editing
                        if !editing { playback.seek(seekPosition) }
                    }).accessibilityLabel("Video position")
                    Text("\(time(playback.position)) / \(time(playback.duration))").monospacedDigit().font(.caption)
                }
                HStack {
                    Picker("Speed", selection: $playback.rate) {
                        ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }.frame(width: 150)
                    Slider(value: $playback.volume, in: 0...1) { Text("Volume") }.frame(width: 120)
                    Toggle("Follow playback", isOn: $playback.follow)
                    Spacer()
                    Button("Close Video") { playback.stop() }
                }
            } else {
                HStack {
                    Button("Load Video") { playback.load(id: id, service: service) }
                    Button("Locate File…") { service.locate(id) }
                    if let error = playback.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
}
