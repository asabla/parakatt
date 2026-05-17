import Foundation
import ParakattCore

/// Long-running meeting transcription state.
///
/// Skeleton for now — AppState still owns meeting state. The follow-up
/// PR migrates: isMeetingActive, isMeetingPaused, meetingElapsedTime,
/// meetingTranscription, meetingLatestChunk, meetingSegments,
/// meetingLatestChunkStartSecs, meetingAudioStatus, meetingMicLevel,
/// plus the MeetingSessionService lifecycle and elapsed-time timer.
@MainActor
final class MeetingCoordinator: ObservableObject {
}
