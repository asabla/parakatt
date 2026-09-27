import SwiftUI
import AVKit

@MainActor
final class MediaPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var position: Double = 0
    @Published var loading = false
    @Published var error: String?
    @Published private(set) var preparation: MediaPlaybackProgress?
    @Published var follow = false
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var token = MediaCancellation()
    private var task: Task<Void, Never>?
    private var accessedURL: URL?
    func load(id: String, service: MediaImportService) {
        load { token, progress in try await service.playbackURL(id, token: token, progress: progress) }
    }
    // A preparation closure also permits deterministic tests of delayed and cancelled loads.
    func load(prepare: @escaping (MediaCancellation, @escaping (MediaPlaybackProgress) -> Void) async throws -> URL) {
        stop(); loading = true; error = nil; preparation = .checkingSource(0)
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
                if url.startAccessingSecurityScopedResource() { accessedURL = url }
                preparation = .checkingPlayback
                let player = try await MediaTools.readyPlayer(url, cancellation: token)
                try token.check()
                guard self.token === token else { return }
                self.player = player
                statusObserver = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor in
                        guard let self, self.token === token else { return }
                        self.stop(); self.error = "Video playback failed. Try loading the video again."
                    }
                }
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor in if self?.token === token, time.seconds.isFinite { self?.position = time.seconds } }
                }
                loading = false; preparation = nil
            } catch is CancellationError {
                if self.token === token { stop() }
            } catch {
                guard self.token === token else { return }
                stop()
                self.error = (error as? MediaImportError)?.message ?? "The video could not be prepared for playback. Check the source file and available disk space."
            }
        }
    }
    func seek(_ seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 16_000), toleranceBefore: .zero, toleranceAfter: .zero) }
    func stop() {
        token.cancel(); token = MediaCancellation(); task?.cancel(); task = nil; loading = false; preparation = nil
        statusObserver = nil; position = 0
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }; observer = nil; player?.replaceCurrentItem(with: nil); player = nil
        if let accessedURL { accessedURL.stopAccessingSecurityScopedResource() }; accessedURL = nil
    }
}
struct MediaPlaybackView: View {
    let id: String
    @ObservedObject var playback: MediaPlayback
    @ObservedObject var service: MediaImportService
    @State private var rate: Float = 1
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if playback.loading {
                HStack {
                    if let value = playback.preparation?.fraction { ProgressView(value: value).frame(width: 100) }
                    else { ProgressView().controlSize(.small) }
                    Text(playback.preparation?.label ?? "Preparing video for playback…")
                    Button("Cancel") { playback.stop() }
                }
                Text("A playback copy is created only when needed. The original video is kept.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let player = playback.player {
                VideoPlayer(player: player).frame(height: 220)
                HStack {
                    Picker("Speed", selection: $rate) { ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }.frame(width: 160)
                    Toggle("Follow playback", isOn: $playback.follow)
                }.onChange(of: rate) { player.defaultRate = rate; if player.rate != 0 { player.rate = rate } }
            } else {
                HStack {
                    Button("Load Video") { playback.load(id: id, service: service) }
                    Button("Locate File…") { service.locate(id) }
                    if let error = playback.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }
}
