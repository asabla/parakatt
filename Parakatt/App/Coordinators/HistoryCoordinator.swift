import Foundation
import ParakattCore

/// Transcription history queries and mutations.
@MainActor
final class HistoryCoordinator {
    func listTranscriptions(
        bridge: CoreBridge?,
        searchText: String? = nil,
        sourceFilter: String? = nil,
        limit: UInt32 = 50,
        offset: UInt32 = 0
    ) -> [StoredTranscription] {
        let query = TranscriptionQuery(
            searchText: searchText,
            sourceFilter: sourceFilter,
            limit: limit,
            offset: offset
        )
        return (try? bridge?.listTranscriptions(query: query)) ?? []
    }

    func searchTranscriptions(bridge: CoreBridge?, query: String) -> [StoredTranscription] {
        (try? bridge?.searchTranscriptions(searchText: query)) ?? []
    }

    func getTranscription(bridge: CoreBridge?, id: String) -> StoredTranscription? {
        try? bridge?.getTranscription(id: id)
    }

    func updateTranscriptionTitle(bridge: CoreBridge?, id: String, title: String) {
        try? bridge?.updateTranscriptionTitle(id: id, title: title)
    }

    func deleteTranscription(bridge: CoreBridge?, id: String) {
        do {
            try bridge?.deleteTranscription(id: id)
            NSLog("[Parakatt] Deleted transcription: %@", id)
        } catch {
            NSLog("[Parakatt] Failed to delete transcription %@: %@", id, error.localizedDescription)
        }
    }

    func deleteTranscriptions(bridge: CoreBridge?, ids: [String]) -> Int {
        do {
            let count = try bridge?.deleteTranscriptions(ids: ids) ?? 0
            NSLog("[Parakatt] Bulk deleted %d transcriptions", count)
            return Int(count)
        } catch {
            NSLog("[Parakatt] Failed to bulk delete: %@", error.localizedDescription)
            return 0
        }
    }

    func getTranscriptionSegments(bridge: CoreBridge?, id: String) -> [TimestampedSegment] {
        (try? bridge?.getTranscriptionSegments(id: id)) ?? []
    }
}
