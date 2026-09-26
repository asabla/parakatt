import Foundation

/// Keep a small recent set; very large transcripts remain only in the selected view.
struct HistoryDetailCache {
    private var values: [String: HistoryDetailData] = [:]
    private var order: [String] = []
    private let maxEntries = 8
    private let maxCharacters = 500_000
    mutating func value(for id: String) -> HistoryDetailData? {
        guard let value = values[id] else { return nil }
        order.removeAll { $0 == id }; order.append(id)
        return value
    }
    private func cost(_ value: HistoryDetailData) -> Int {
        (value.item?.text.utf8.count ?? 0) + value.segments.reduce(0) { $0 + $1.text.utf8.count } + (value.recognizedText?.utf8.count ?? 0)
            + value.sections.reduce(0) { $0 + $1.text.utf8.count + $1.recognizedText.utf8.count }
    }
    mutating func insert(_ value: HistoryDetailData, for id: String) {
        values.removeValue(forKey: id); order.removeAll { $0 == id }
        guard cost(value) <= maxCharacters else { return }
        values[id] = value; order.append(id)
        while values.count > maxEntries || values.values.reduce(0, { $0 + cost($1) }) > maxCharacters {
            values.removeValue(forKey: order.removeFirst())
        }
    }
    mutating func removeAll() { values.removeAll(); order.removeAll() }
}
