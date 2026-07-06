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
}
