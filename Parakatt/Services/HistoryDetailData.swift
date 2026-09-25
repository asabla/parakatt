import Foundation
import ParakattCore

struct HistoryDetailData {
    let segments: [TimestampedSegment]
    let recognizedText: String?
    let processingStatus: String?
    let hasSpeakerLabels: Bool
    let speakerHues: [String: Double]
    init(segments: [TimestampedSegment] = []) {
        self.segments = segments
        self.recognizedText = nil
        self.processingStatus = nil
        let speakers = Set(segments.compactMap(\.speaker))
        self.hasSpeakerLabels = !speakers.isEmpty
        self.speakerHues = Dictionary(uniqueKeysWithValues: speakers.map { ($0, Self.hue(for: $0)) })
    }
    private static func hue(for name: String) -> Double {
        let hash = name.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return Double(hash % 360) / 360
    }
}

