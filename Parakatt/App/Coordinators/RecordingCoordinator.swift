import Foundation

/// Push-to-talk + single-recording state.
///
/// Skeleton for now — AppState still owns recording state. The
/// follow-up PR migrates: isRecording, isProcessing, lastTranscription,
/// liveTranscription, currentAudioLevel, silenceDetected,
/// audioClippingDetected, livePreviewCommitted, livePreviewTentative,
/// plus the PTT chunk pipeline (audioBufferLock, pttChunkLock,
/// pttChunkTimer, pttAccumulatedText).
@MainActor
final class RecordingCoordinator: ObservableObject {
}
