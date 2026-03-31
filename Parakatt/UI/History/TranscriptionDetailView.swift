import SwiftUI
import ParakattCore

/// Detail view for a single transcription with full text, metadata, and actions.
struct TranscriptionDetailView: View {
    let item: StoredTranscription
    let onTitleChanged: (String) -> Void
    let onDelete: () -> Void

    @State private var editingTitle = false
    @State private var titleText = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if editingTitle {
                        TextField("Title", text: $titleText, onCommit: {
                            onTitleChanged(titleText)
                            editingTitle = false
                        })
                        .textFieldStyle(.roundedBorder)
                    } else {
                        Text(item.title ?? "Untitled")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Button(action: {
                            titleText = item.title ?? ""
                            editingTitle = true
                        }) {
                            Image(systemName: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                // Metadata
                HStack(spacing: 12) {
                    Label(item.source == "meeting" ? "Meeting" : "Note",
                          systemImage: item.source == "meeting" ? "person.2" : "mic")
                        .font(.caption)
                        .foregroundColor(item.source == "meeting" ? .green : .blue)

                    Label(formattedDate(item.createdAt), systemImage: "calendar")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Label(formattedDuration(item.durationSecs), systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let mode = Optional(item.mode), mode != "dictation" {
                        Label(mode.capitalized, systemImage: "text.badge.checkmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Actions
                HStack(spacing: 8) {
                    Button("Copy Text") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                    }

                    Button("Export as Markdown") {
                        exportMarkdown()
                    }

                    Spacer()

                    Button("Delete", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .foregroundColor(.red)
                }
                .font(.caption)
            }
            .padding()

            Divider()

            // Full text
            ScrollView {
                Text(item.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 300)
        .alert("Delete Transcription?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(item.title ?? "transcription").md"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let markdown = """
            # \(item.title ?? "Untitled")

            **Date:** \(formattedDate(item.createdAt))
            **Duration:** \(formattedDuration(item.durationSecs))
            **Type:** \(item.source == "meeting" ? "Meeting" : "Note")
            **Mode:** \(item.mode)

            ---

            \(item.text)
            """
            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: iso) else { return iso }
            return formatDate(date)
        }
        return formatDate(date)
    }

    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private func formattedDuration(_ secs: Double) -> String {
        let minutes = Int(secs) / 60
        let seconds = Int(secs) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}
