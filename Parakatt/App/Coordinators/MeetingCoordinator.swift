import Foundation
import ParakattCore

@MainActor
final class MeetingCoordinator: ObservableObject {
    @Published var isMeetingActive: Bool = false
    @Published var isMeetingPaused: Bool = false
    @Published var meetingElapsedTime: TimeInterval = 0
    @Published var meetingTranscription: String? = nil
    @Published var meetingLatestChunk: String? = nil
    @Published var meetingSegments: [TimestampedSegment] = []
    @Published var meetingLatestChunkStartSecs: Double? = nil
    @Published var meetingAudioStatus: MeetingAudioStatus = .unknown
    @Published var meetingMicLevel: Float = 0
}
