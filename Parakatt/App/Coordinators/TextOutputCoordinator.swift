import Foundation

/// Handles delivery of completed transcription text to the focused app.
@MainActor
final class TextOutputCoordinator {
    func insertIfEnabled(text: String, autoPaste: Bool, inserter: TextInserting?) -> String? {
        guard autoPaste else { return nil }
        let inserted = inserter?.insertText(text) ?? false
        return inserted ? nil : "Could not paste text — transcription copied to clipboard"
    }
}
