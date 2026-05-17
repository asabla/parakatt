import Foundation

/// Push-to-talk + single-recording UI state.
///
/// Owns the @Published surface that drives the recording overlay,
/// menu bar, and live-preview UI. The PTT pipeline itself
/// (audioBuffer, chunk timer, chunk lock, accumulated text) stays
/// on AppState for now — a later refactor can move the pipeline
/// here once the boundary is proven by these published fields.
@MainActor
final class RecordingCoordinator: ObservableObject {
    /// True while the user is actively recording (held or toggled on).
    @Published var isRecording = false
    /// True while a chunk is being transcribed / inserted (UI shows spinner).
    @Published var isProcessing = false
    /// Last full transcription result, shown in the menu bar and history.
    @Published var lastTranscription: String?
    /// Best-current text during recording — composed from committed +
    /// tentative slices for streaming mode, or per-chunk accumulated
    /// text for the buffered v3 path.
    @Published var liveTranscription: String?

    /// Current input level (0…1), driven by audio tap callbacks.
    @Published var currentAudioLevel: Float = 0
    /// True if the input has been below the silence threshold long
    /// enough that the user probably forgot to unmute.
    @Published var silenceDetected = false
    /// True if the input is consistently clipping — surfaces a "lower
    /// your mic gain" hint in the overlay.
    @Published var audioClippingDetected = false

    /// Latest committed text from the LocalAgreement-2 stream.
    /// Stable, never revised by the live preview path.
    @Published var livePreviewCommitted: String = ""
    /// Latest tentative tail from the LocalAgreement-2 stream.
    /// Renders in lighter style; expected to flicker.
    @Published var livePreviewTentative: String = ""
}
