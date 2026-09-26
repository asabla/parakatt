import Foundation
import ParakattCore

/// Completed text and recognized timing data have separate export fields.
enum TranscriptExport {
    static func subtitles(segments: [TimestampedSegment], duration: Double, vtt: Bool) -> String {
        guard duration.isFinite, duration > 0 else { return vtt ? "WEBVTT\n\n" : "" }
        var output = vtt ? "WEBVTT\n\n" : ""
        var previousEnd = 0
        var index = 0
        func timestamp(_ milliseconds: Int) -> String {
            String(format: "%02d:%02d:%02d%@%03d", milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60, vtt ? "." : ",", milliseconds % 1000)
        }
        for segment in segments.filter({ $0.startSecs.isFinite && $0.endSecs.isFinite }).sorted(by: { $0.startSecs < $1.startSecs }) {
            let text = segment.text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let start = max(previousEnd, Int((min(duration, max(0, segment.startSecs)) * 1000).rounded()))
            let end = Int((min(duration, max(0, segment.endSecs)) * 1000).rounded())
            guard !text.isEmpty, end > start else { continue }
            index += 1
            output += "\(index)\n\(timestamp(start)) --> \(timestamp(end))\n\(text)\n\n"
            previousEnd = end
        }
        return output
    }

    static func markdownBody(text: String, recognizedText: String?, segments: [TimestampedSegment]) -> String {
        var output = "## Processed text\n\n\(text)"
        if !segments.isEmpty {
            let timeline = segments.map { segment in
                let seconds = max(0, Int(segment.startSecs))
                let timestamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                let speaker = segment.speaker.map { "**\($0):** " } ?? ""
                return "[\(timestamp)] \(speaker)\(segment.text)"
            }.joined(separator: "\n\n")
            output += "\n\n## Recognized timeline\n\n\(timeline)"
        } else if let recognizedText, recognizedText != text {
            output += "\n\n## Recognized text\n\n\(recognizedText)"
        }
        return output
    }
    static func jsonObject(item: StoredTranscription, recognizedText: String?, status: String?, segments: [TimestampedSegment]) -> [String: Any] {
        var object: [String: Any] = ["id": item.id, "title": item.title ?? "", "created_at": item.createdAt,
                                    "duration_secs": item.durationSecs, "source": item.source, "mode": item.mode, "text": item.text]
        if let recognizedText { object["recognized_text"] = recognizedText }
        if let status { object["processing_status"] = status }
        if !segments.isEmpty {
            object["segments"] = segments.map { segment -> [String: Any] in
                var result: [String: Any] = ["text": segment.text, "start_secs": segment.startSecs, "end_secs": segment.endSecs]
                if let speaker = segment.speaker { result["speaker"] = speaker }
                return result
            }
        }
        return object
    }
}
