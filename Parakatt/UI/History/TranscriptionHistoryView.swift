import SwiftUI
import ParakattCore

/// Main history window showing all past transcriptions with search and filtering.
struct TranscriptionHistoryView: View {
    @EnvironmentObject var appState: AppState

    @State private var searchText = ""
    @State private var sourceFilter: String? = nil
    @State private var transcriptions: [StoredTranscription] = []
    @State private var selectedId: String?

    var body: some View {
        HSplitView {
            // List pane
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search transcriptions...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { refresh() }
                        .onChange(of: searchText) { refresh() }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))

                // Filter pills
                HStack(spacing: 6) {
                    FilterPill(title: "All", isActive: sourceFilter == nil) {
                        sourceFilter = nil
                        refresh()
                    }
                    FilterPill(title: "Notes", isActive: sourceFilter == "push_to_talk") {
                        sourceFilter = "push_to_talk"
                        refresh()
                    }
                    FilterPill(title: "Meetings", isActive: sourceFilter == "meeting") {
                        sourceFilter = "meeting"
                        refresh()
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                // Transcription list
                if transcriptions.isEmpty {
                    VStack {
                        Spacer()
                        Text("No transcriptions yet")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } else {
                    List(transcriptions, id: \.id, selection: $selectedId) { item in
                        TranscriptionRow(item: item)
                            .contextMenu {
                                Button("Copy Text") { copyText(item.text) }
                                Button("Delete", role: .destructive) {
                                    appState.deleteTranscription(id: item.id)
                                    if selectedId == item.id { selectedId = nil }
                                    refresh()
                                }
                            }
                    }
                }
            }
            .frame(minWidth: 250, idealWidth: 300)

            // Detail pane
            if let id = selectedId, let item = transcriptions.first(where: { $0.id == id }) {
                TranscriptionDetailView(item: item, onTitleChanged: { newTitle in
                    appState.updateTranscriptionTitle(id: id, title: newTitle)
                    refresh()
                }, onDelete: {
                    appState.deleteTranscription(id: id)
                    selectedId = nil
                    refresh()
                })
            } else {
                VStack {
                    Spacer()
                    Text("Select a transcription")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(minWidth: 300)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear { refresh() }
    }

    private func refresh() {
        transcriptions = appState.listTranscriptions(
            searchText: searchText.isEmpty ? nil : searchText,
            sourceFilter: sourceFilter
        )
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Subviews

private struct FilterPill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptionRow: View {
    let item: StoredTranscription

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: item.source == "meeting" ? "person.2" : "mic")
                    .font(.caption2)
                    .foregroundColor(item.source == "meeting" ? .green : .blue)

                Text(item.title ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                Spacer()
            }

            HStack {
                Text(formattedDate(item.createdAt))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(formattedDuration(item.durationSecs))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(item.text)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }

    private func formattedDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else {
            // Try without fractional seconds
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
