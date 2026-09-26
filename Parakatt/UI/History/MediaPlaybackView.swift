import SwiftUI
import AVKit

@MainActor
final class MediaPlayback: ObservableObject {
    @Published var player: AVPlayer?
    @Published var position: Double = 0
    @Published var loading = false
    @Published var error: String?
    @Published var follow = false
    private var observer: Any?
    private var token = MediaCancellation()
    private var task: Task<Void, Never>?
    private var accessedURL: URL?
    func load(id: String, service: MediaImportService) {
        stop(); loading = true; error = nil; token = MediaCancellation()
        let token = self.token
        task = Task {
            do {
                let url = try await service.playbackURL(id, token: token)
                try token.check()
                if url.startAccessingSecurityScopedResource() { accessedURL = url }
                let player = AVPlayer(url: url); self.player = player
                observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
                    Task { @MainActor in if self?.token === token, time.seconds.isFinite { self?.position = time.seconds } }
                }
                loading = false
            } catch is CancellationError { if self.token === token { loading = false } }
            catch { guard self.token === token else { return }; self.error = "The video could not be prepared for playback. Check the source file and available disk space."; loading = false }
        }
    }
    func seek(_ seconds: Double) { player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 16_000), toleranceBefore: .zero, toleranceAfter: .zero) }
    func stop() {
        token.cancel(); task?.cancel(); task = nil; loading = false
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }; observer = nil; player = nil
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
            if let player = playback.player {
                VideoPlayer(player: player).frame(height: 220)
                HStack {
                    Picker("Speed", selection: $rate) { ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { Text(String(format: "%g×", $0)).tag($0) } }.frame(width: 160)
                    Toggle("Follow playback", isOn: $playback.follow)
                }.onChange(of: rate) { player.defaultRate = rate; if player.rate != 0 { player.rate = rate } }
            } else if playback.loading {
                HStack { ProgressView().controlSize(.small); Text("Preparing video for playback…"); Button("Cancel") { playback.stop(); playback.loading = false } }
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
