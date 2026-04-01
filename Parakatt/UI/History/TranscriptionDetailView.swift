import SwiftUI
import ParakattCore
import UniformTypeIdentifiers

/// Detail view for a single transcription — header, toolbar, scrollable text.
/// When timestamp segments are available, shows a timeline view instead of flat text.
struct TranscriptionDetailView: View {
    let item: StoredTranscription
    let segments: [TimestampedSegment]
    let onTitleChanged: (String) -> Void
    let onDelete: () -> Void

    @State private var editingTitle = false
    @State private var titleText = ""
    @State private var showDeleteConfirm = false
    @State private var copied = false
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            textSection
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Delete Transcription?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This transcription will be permanently removed.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Editable title
            titleView

            // Metadata chips
            HStack(spacing: 16) {
                MetadataChip(
                    icon: item.source == "meeting" ? "person.2.fill" : "mic.fill",
                    text: item.source == "meeting" ? "Meeting" : "Voice Note",
                    color: item.source == "meeting" ? .green : .blue
                )

                MetadataChip(
                    icon: "calendar",
                    text: formattedDate(item.createdAt),
                    color: .secondary
                )

                if item.durationSecs >= 1.0 {
                    MetadataChip(
                        icon: "clock",
                        text: formattedDuration(item.durationSecs),
                        color: .secondary
                    )
                }

                if item.mode != "dictation" {
                    MetadataChip(
                        icon: "text.badge.checkmark",
                        text: item.mode.capitalized,
                        color: .secondary
                    )
                }
            }

            // Action toolbar
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    withAnimation(.easeInOut(duration: 0.2)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(.easeInOut(duration: 0.2)) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .tint(copied ? .green : nil)

                Button {
                    exportMarkdown()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Spacer()

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    // MARK: - Title

    @ViewBuilder
    private var titleView: some View {
        if editingTitle {
            TextField("Title", text: $titleText)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .focused($titleFieldFocused)
                .onSubmit { commitTitle() }
                .onExitCommand { cancelTitleEdit() }
                .onAppear { titleFieldFocused = true }
        } else {
            Text(item.title ?? "Untitled")
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .onTapGesture(count: 2) { beginTitleEdit() }
                .overlay(alignment: .trailing) {
                    Button { beginTitleEdit() } label: {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 24)
                }
        }
    }

    private func beginTitleEdit() {
        titleText = item.title ?? ""
        editingTitle = true
    }

    private func commitTitle() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onTitleChanged(trimmed)
        }
        editingTitle = false
    }

    private func cancelTitleEdit() {
        editingTitle = false
    }

    // MARK: - Text body

    private var textSection: some View {
        ScrollView {
            if segments.isEmpty {
                // Flat text for transcriptions without timestamp data.
                Text(item.text)
                    .font(.system(.body, design: .default))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            } else {
                // Timeline view with timestamps.
                timelineView
            }
        }
    }

    private var timelineView: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                HStack(alignment: .top, spacing: 12) {
                    // Timestamp label
                    Text(formatTimestamp(segment.startSecs))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)

                    // Timeline dot and line
                    VStack(spacing: 0) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        if index < segments.count - 1 {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.2))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }

                    // Segment text
                    Text(segment.text)
                        .font(.system(.body, design: .default))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Export

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "\(item.title ?? "transcription").md"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let bodyText: String
            if segments.isEmpty {
                bodyText = item.text
            } else {
                bodyText = segments.map { seg in
                    "[\(formatTimestamp(seg.startSecs))] \(seg.text)"
                }.joined(separator: "\n\n")
            }

            let md = """
            # \(item.title ?? "Untitled")

            **Date:** \(formattedDate(item.createdAt))
            **Duration:** \(formattedDuration(item.durationSecs))
            **Type:** \(item.source == "meeting" ? "Meeting" : "Voice Note")
            **Mode:** \(item.mode)

            ---

            \(bodyText)
            """
            try? md.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Formatters

    private func formattedDate(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return iso }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df.string(from: date)
    }

    private func formattedDuration(_ secs: Double) -> String {
        let totalSeconds = Int(secs)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private func formatTimestamp(_ secs: Double) -> String {
        let totalSeconds = Int(secs)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func parseISO(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}

// MARK: - Metadata chip

private struct MetadataChip: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
        } icon: {
            Image(systemName: icon)
                .font(.caption2)
        }
        .foregroundStyle(color)
    }
}
