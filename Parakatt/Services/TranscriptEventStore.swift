import Foundation
import ParakattCore

/// Applies completed chunk replacements by identity, not callback arrival order.
struct TranscriptEventStore {
    private(set) var sessionID: String
    private var chunks: [String: TranscriptionEvent] = [:]
    private var closed = false
    init(sessionID: String) { self.sessionID = sessionID }
    mutating func apply(_ events: [TranscriptionEvent]) -> Bool {
        guard !closed else { return false }
        var changed = false
        for event in events where event.sessionId == sessionID {
            if case .finished = event.state { closed = true; break }
            let key = "\(event.chunkId):\(event.source)"
            if let previous = chunks[key], previous.revision >= event.revision { continue }
            chunks[key] = event
            changed = true
        }
        return changed
    }
    var text: String {
        let ordered = chunks.values.sorted {
            if $0.chunkId != $1.chunkId { return $0.chunkId < $1.chunkId }
            return sourceOrder($0.source) < sourceOrder($1.source)
        }
        return assembleTranscriptParts(parts: ordered.map(\.text), sources: ordered.map(\.source))
    }
    private func sourceOrder(_ source: ChunkSource) -> Int {
        switch source { case .mixed: return 0; case .mic: return 1; case .system: return 2 }
    }
    mutating func close() { closed = true }
}
