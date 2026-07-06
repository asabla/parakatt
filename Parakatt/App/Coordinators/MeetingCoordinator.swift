import Foundation
import ParakattCore

/// Long-running meeting transcription state.
@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published var isMeetingActive = false
    @Published var isMeetingPaused = false
    @Published var meetingElapsedTime: TimeInterval = 0
    @Published var meetingTranscription: String?
    @Published var meetingLatestChunk: String?
    @Published var meetingSegments: [TimestampedSegment] = []
    /// Absolute-timestamp index (seconds) where the latest chunk's segments
    /// begin. Lets the live view highlight "what just arrived" without
    /// needing a separate copy of the latest chunk's segments.
    @Published var meetingLatestChunkStartSecs: Double?
    @Published var meetingAudioStatus: MeetingAudioStatus = .unknown
    /// Live peak amplitude of the mic capture during a meeting, 0...1.
    /// Driven from MeetingSessionService.onMicLevel. Smoothed client-side
    /// to avoid visual jitter on short silences.
    @Published var meetingMicLevel: Float = 0

    /// Seconds of audio required before the first chunk transcribes.
    /// Surfaced to the UI so it can draw a "until first batch" progress bar.
    var meetingFirstChunkSecs: Double { 30.0 }
    /// Seconds between subsequent chunk dispatches after the first.
    var meetingChunkIntervalSecs: Double { 28.0 }

    var onAudioWarning: ((String) -> Void)?

    /// When the system-audio side first started reporting silent/empty.
    /// Used to decide when to escalate to a user-visible warning.
    private var systemSilentSince: Date?
    /// Rolling signal-quality threshold (dBFS) below which a source counts
    /// as "silent". -60 dBFS matches the tap health threshold.
    private let meetingSilenceDbfsThreshold: Double = -60.0
    /// Seconds of continuous system-silent before we surface a user warning.
    private let meetingSilenceWarnAfterSecs: TimeInterval = 15

    func resetAudioStatus() {
        meetingAudioStatus = .unknown
        meetingMicLevel = 0
        systemSilentSince = nil
    }

    func updateMicLevel(peak: Float) {
        // Exponential moving average to smooth the bars without losing
        // responsiveness. Fast attack, slower release.
        let target = max(0, min(1, peak))
        let alpha: Float = target > meetingMicLevel ? 0.6 : 0.2
        meetingMicLevel = meetingMicLevel * (1 - alpha) + target * alpha
    }

    /// Apply a per-chunk RMS sample to the meeting audio-status state machine.
    /// Runs on the main thread (callback is already marshalled there).
    func updateAudioStatus(micDbfs: Double?, sysDbfs: Double?) {
        let micSilent = (micDbfs ?? -.infinity) < meetingSilenceDbfsThreshold
        let sysSilent = (sysDbfs ?? -.infinity) < meetingSilenceDbfsThreshold

        // If the existing status is a terminal "permissionDenied" / "error",
        // leave it — subsequent chunk health can't contradict those.
        if case .permissionDenied = meetingAudioStatus { return }
        if case .error = meetingAudioStatus { return }

        if micSilent && sysSilent {
            meetingAudioStatus = .bothSilent
            systemSilentSince = systemSilentSince ?? Date()
        } else if sysSilent {
            let since = systemSilentSince ?? Date()
            systemSilentSince = since
            meetingAudioStatus = .systemSilent(since: since)
            if Date().timeIntervalSince(since) >= meetingSilenceWarnAfterSecs {
                onAudioWarning?("No audio from other apps detected. If this is a meeting, confirm the other app is playing to the selected output device.")
            }
        } else {
            meetingAudioStatus = .healthy
            systemSilentSince = nil
        }
    }

    /// Apply a tap-level SystemAudioHealth sample. Note: the per-chunk RMS
    /// path (updateAudioStatus) is the source of truth for "is the transcript
    /// going to be mic-only?". This only escalates to .systemEmpty when the
    /// tap itself reports persistent empty buffers — that's a distinct failure
    /// mode (wrong output device, not just quiet audio).
    func applySystemAudioHealth(_ health: SystemAudioHealth) {
        if case .permissionDenied = meetingAudioStatus { return }
        if case .error = meetingAudioStatus { return }

        switch health {
        case .empty(let forSeconds) where forSeconds >= meetingSilenceWarnAfterSecs:
            meetingAudioStatus = .systemEmpty
            onAudioWarning?("System-audio tap is delivering empty buffers. This usually means the selected output device isn't the one your meeting app is using.")
        case .empty(let forSeconds) where forSeconds >= 2.0:
            // Intermediate state: tap isn't delivering yet but it's early
            // days. Let the user know we're mic-only for now without
            // escalating all the way to a hard error.
            let since = systemSilentSince ?? Date()
            systemSilentSince = since
            if case .systemEmpty = meetingAudioStatus { return }
            if case .bothSilent = meetingAudioStatus { return }
            meetingAudioStatus = .systemSilent(since: since)
        case .silent(let forSeconds) where forSeconds >= 2.0:
            let since = systemSilentSince ?? Date()
            systemSilentSince = since
            if case .systemEmpty = meetingAudioStatus { return }
            if case .bothSilent = meetingAudioStatus { return }
            meetingAudioStatus = .systemSilent(since: since)
        case .ok:
            systemSilentSince = nil
            meetingAudioStatus = .healthy
        default:
            break
        }
    }
}
