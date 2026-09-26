import Foundation

struct TranscriptMatch: Equatable {
    let section: Int
    let range: NSRange
}
enum TranscriptSearch {
    static func matches(in sections: [String], query: String, limit: Int = 2000) -> [TranscriptMatch] {
        guard !query.isEmpty else { return [] }
        var matches: [TranscriptMatch] = []
        for (section, text) in sections.enumerated() {
            let value = text as NSString
            var offset = 0
            while offset < value.length && matches.count < limit {
                let range = value.range(of: query, options: .caseInsensitive, range: NSRange(location: offset, length: value.length - offset))
                guard range.location != NSNotFound else { break }
                matches.append(TranscriptMatch(section: section, range: range))
                offset = range.location + range.length
            }
            if matches.count == limit { break }
        }
        return matches
    }
}
