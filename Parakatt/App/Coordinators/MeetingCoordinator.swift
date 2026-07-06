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

    @available(macOS 14.2, *)
    private var session: MeetingSessionService? {
        get { _session as? MeetingSessionService }
        set { _session = newValue }
    }
    private var _session: AnyObject?
    private var elapsedTimer: Timer?

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

    func prepareForStart() {
        isMeetingActive = true
        isMeetingPaused = false
        meetingTranscription = nil
        meetingLatestChunk = nil
        meetingLatestChunkStartSecs = nil
        meetingSegments = []
        meetingElapsedTime = 0
        resetAudioStatus()
    }

    func applyChunk(newText: String, accumulatedText: String, segments: [TimestampedSegment]) {
        meetingLatestChunk = newText
        meetingTranscription = accumulatedText
        if !segments.isEmpty {
            // Segments carry absolute-to-session timestamps already.
            // Track where the latest chunk starts so the live view can
            // highlight the new arrivals.
            let chunkStart = segments.first?.startSecs
            meetingSegments.append(contentsOf: segments)
            meetingLatestChunkStartSecs = chunkStart
        }
    }

    func markFinished(transcription: String) {
        isMeetingActive = false
        stopElapsedTimer()
        meetingTranscription = transcription
        meetingLatestChunk = nil
        meetingLatestChunkStartSecs = nil
        isMeetingPaused = false
        resetAudioStatus()
    }

    func markFailed(message: String) {
        isMeetingActive = false
        stopElapsedTimer()
        meetingAudioStatus = .error(message)
    }

    func markStartFailed() {
        isMeetingActive = false
        stopElapsedTimer()
    }

    func markPermissionDenied() {
        meetingAudioStatus = .permissionDenied
    }

    func markStartError(_ message: String) {
        meetingAudioStatus = .error(message)
    }

    func markCancelled() {
        isMeetingActive = false
        isMeetingPaused = false
        stopElapsedTimer()
        meetingTranscription = nil
        meetingLatestChunk = nil
        meetingLatestChunkStartSecs = nil
        meetingSegments = []
        resetAudioStatus()
    }

    @available(macOS 14.2, *)
    func setSession(_ session: MeetingSessionService) {
        self.session = session
    }

    @available(macOS 14.2, *)
    func configureSession(
        _ session: MeetingSessionService,
        onFinished: @escaping (TranscriptionResult) -> Void,
        onError: @escaping (String) -> Void
    ) {
        setSession(session)

        session.onChunkTranscribed = { [weak self] newText, accumulated, segments in
            self?.applyChunk(newText: newText, accumulatedText: accumulated, segments: segments)
        }

        session.onChunkHealth = { [weak self] micDbfs, sysDbfs in
            self?.updateAudioStatus(micDbfs: micDbfs, sysDbfs: sysDbfs)
        }

        session.onSystemAudioHealth = { [weak self] health in
            self?.applySystemAudioHealth(health)
        }

        session.onMicLevel = { [weak self] peak in
            self?.updateMicLevel(peak: peak)
        }

        session.onSessionFinished = { [weak self] result in
            self?.markFinished(transcription: result.text)
            onFinished(result)
        }

        session.onError = { [weak self] message in
            self?.markFailed(message: message)
            onError(message)
        }
    }

    @available(macOS 14.2, *)
    func startSession(
        bridge: CoreBridge,
        environment: PlatformEnvironment,
        processID: pid_t?,
        sourceName: String?,
        mode: String,
        context: AppContextInfo?,
        speakerLabelsEnabled: Bool,
        onFinished: @escaping (TranscriptionResult) -> Void,
        onError: @escaping (String) -> Void,
        onPermissionDenied: @escaping () -> Void,
        onStartError: @escaping (String) -> Void
    ) {
        let session = MeetingSessionService(
            bridge: bridge,
            micCapture: environment.makeAudioCapture(),
            systemCapture: environment.makeSystemAudioCapture()
        )

        configureSession(session, onFinished: onFinished, onError: onError)
        prepareForStart()

        startElapsedTimer { [weak self] in
            self?.currentSessionElapsedTime() ?? 0
        }

        do {
            try session.start(
                processID: processID,
                mode: mode,
                context: context,
                speakerLabelsEnabled: speakerLabelsEnabled
            )
            if let sourceName {
                NSLog("[Parakatt] Meeting capturing audio from: %@", sourceName)
            }
        } catch {
            // If a specific app was selected but its process is gone, fall back to all system audio.
            if processID != nil,
               let audioErr = error as? SystemAudioCaptureError,
               case .processNotFound = audioErr {
                NSLog("[Parakatt] Selected app not found (pid %d), falling back to all system audio", processID ?? 0)
                do {
                    try session.start(
                        processID: nil,
                        mode: mode,
                        context: context,
                        speakerLabelsEnabled: speakerLabelsEnabled
                    )
                    return
                } catch {
                    // Fall through to error handling below.
                }
            }

            markStartFailed()

            if let audioErr = error as? SystemAudioCaptureError, case .permissionDenied = audioErr {
                markPermissionDenied()
                onPermissionDenied()
            } else {
                markStartError(error.localizedDescription)
                onStartError("Failed to start meeting: \(error.localizedDescription)")
            }
        }
    }

    @available(macOS 14.2, *)
    func currentSessionElapsedTime() -> TimeInterval {
        session?.elapsedTime ?? 0
    }

    @available(macOS 14.2, *)
    func stopSession(mode: String, context: AppContextInfo?) {
        session?.stop(mode: mode, context: context)
    }

    @available(macOS 14.2, *)
    func cancelSession() {
        session?.cancel()
    }

    @available(macOS 14.2, *)
    func pauseSession() {
        session?.pause()
    }

    @available(macOS 14.2, *)
    func resumeSession() throws {
        try session?.resume()
    }

    func startElapsedTimer(elapsedProvider: @escaping () -> TimeInterval) {
        stopElapsedTimer()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.meetingElapsedTime = elapsedProvider()
        }
    }

    func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
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
