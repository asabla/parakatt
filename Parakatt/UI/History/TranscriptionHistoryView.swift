import SwiftUI
import ParakattCore
import UniformTypeIdentifiers

/// Main history window — master-detail split inspired by Notes.app.
struct TranscriptionHistoryView: View {
    @EnvironmentObject var appState: AppState

    @State private var searchText = ""
    @State private var sourceFilter: String? = nil
    @State private var transcriptions: [StoredTranscription] = []
    @State private var selectedId: String?
    @State private var selectedIds: Set<String> = []
    @State private var isSelectionMode = false
    @State private var showDeleteConfirmation = false

    private enum FilterOption: String, CaseIterable {
        case all = "All"
        case notes = "Notes"
        case meetings = "Meetings"

        var sourceValue: String? {
            switch self {
            case .all: nil
            case .notes: "push_to_talk"
            case .meetings: "meeting"
            }
        }

        var icon: String {
            switch self {
            case .all: "tray.full"
            case .notes: "mic"
            case .meetings: "person.2"
            }
        }
    }

    private var activeFilter: FilterOption {
        switch sourceFilter {
        case "push_to_talk": .notes
        case "meeting": .meetings
        default: .all
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            detailContent
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { refresh() }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Filter + selection mode toolbar
            Group {
            if isSelectionMode {
                // Selection mode toolbar — two rows for breathing room
                VStack(spacing: 8) {
                    // Row 1: Selection count + management
                    HStack {
                        Text("\(selectedIds.count)")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                        + Text(" selected")
                            .font(.system(.body))
                            .foregroundColor(.secondary)

                        Spacer()

                        Button {
                            if selectedIds.count == transcriptions.count {
                                selectedIds.removeAll()
                            } else {
                                selectedIds = Set(transcriptions.map(\.id))
                            }
                        } label: {
                            Text(selectedIds.count == transcriptions.count ? "Deselect All" : "Select All")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)

                        Button("Done") {
                            isSelectionMode = false
                            selectedIds.removeAll()
                        }
                        .buttonStyle(.bordered)
                    }

                    // Row 2: Actions
                    HStack(spacing: 8) {
                        Button {
                            exportSelected()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedIds.isEmpty)

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(selectedIds.isEmpty)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 8) {
                    Picker("Filter", selection: Binding(
                        get: { activeFilter },
                        set: { option in
                            sourceFilter = option.sourceValue
                            refresh()
                        }
                    )) {
                        ForEach(FilterOption.allCases, id: \.self) { option in
                            Label(option.rawValue, systemImage: option.icon)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    if !transcriptions.isEmpty {
                        Button {
                            isSelectionMode = true
                            selectedIds.removeAll()
                        } label: {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Select multiple items")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            }
            .animation(
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    ? nil
                    : .easeInOut(duration: 0.15),
                value: isSelectionMode
            )

            Divider()

            // Transcription list
            if transcriptions.isEmpty {
                emptyListView
            } else if isSelectionMode {
                // Multi-select list
                List(transcriptions, id: \.id) { item in
                    HStack(spacing: 10) {
                        Image(systemName: selectedIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(selectedIds.contains(item.id) ? Color.blue : Color.secondary.opacity(0.4))

                        TranscriptionRow(item: item)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .listRowSeparator(.visible)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIds.contains(item.id) {
                            selectedIds.remove(item.id)
                        } else {
                            selectedIds.insert(item.id)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                // Normal single-select list
                List(transcriptions, id: \.id, selection: $selectedId) { item in
                    TranscriptionRow(item: item)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.visible)
                        .contextMenu {
                            Button {
                                copyText(item.text)
                            } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                            }
                            Divider()
                            Button(role: .destructive) {
                                appState.deleteTranscription(id: item.id)
                                if selectedId == item.id { selectedId = nil }
                                refresh()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .searchable(text: $searchText, prompt: "Search transcriptions")
        .onChange(of: searchText) { refresh() }
        .onSubmit(of: .search) { refresh() }
        .alert("Delete \(selectedIds.count) transcription\(selectedIds.count == 1 ? "" : "s")?",
               isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let count = appState.deleteTranscriptions(ids: Array(selectedIds))
                NSLog("[Parakatt] Bulk deleted %d transcriptions", count)
                selectedIds.removeAll()
                isSelectionMode = false
                selectedId = nil
                refresh()
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if let id = selectedId, let item = transcriptions.first(where: { $0.id == id }) {
            TranscriptionDetailView(
                item: item,
                segments: appState.getTranscriptionSegments(id: id),
                onTitleChanged: { newTitle in
                    appState.updateTranscriptionTitle(id: id, title: newTitle)
                    refresh()
                },
                onDelete: {
                    appState.deleteTranscription(id: id)
                    selectedId = nil
                    refresh()
                }
            )
        } else {
            emptyDetailView
        }
    }

    // MARK: - Empty states

    private var emptyListView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.quaternary)
            Text("No transcriptions")
                .font(.title3)
                .foregroundStyle(.secondary)
            if sourceFilter != nil {
                Text("Try changing the filter or searching for something else.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Transcriptions from voice notes and meetings will appear here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
    }

    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.quaternary)
            Text("Select a transcription")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Choose an item from the sidebar to view its full text.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func refresh() {
        transcriptions = appState.listTranscriptions(
            searchText: searchText.isEmpty ? nil : searchText,
            sourceFilter: sourceFilter,
            limit: 500
        )
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportSelected() {
        let selected = transcriptions.filter { selectedIds.contains($0.id) }
        guard !selected.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "parakatt-export-\(selected.count).json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let items: [[String: Any]] = selected.map { item in
                [
                    "id": item.id,
                    "title": item.title ?? "",
                    "created_at": item.createdAt,
                    "duration_secs": item.durationSecs,
                    "source": item.source,
                    "mode": item.mode,
                    "text": item.text,
                ]
            }

            if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
        }
    }
}

// MARK: - Row

private struct TranscriptionRow: View {
    let item: StoredTranscription

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Title line with source badge
            HStack(spacing: 6) {
                SourceBadge(source: item.source)

                Text(item.title ?? "Untitled")
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Metadata line
            HStack(spacing: 8) {
                Text(relativeDate(item.createdAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if item.durationSecs >= 1.0 {
                    Text("·")
                        .foregroundStyle(.quaternary)
                    Text(formattedDuration(item.durationSecs))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Text preview
            if !item.text.isEmpty {
                Text(item.text)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Formatters

    private func relativeDate(_ iso: String) -> String {
        guard let date = parseISO(iso) else { return iso }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let tf = DateFormatter()
            tf.timeStyle = .short
            tf.dateStyle = .none
            return "Today \(tf.string(from: date))"
        } else if calendar.isDateInYesterday(date) {
            let tf = DateFormatter()
            tf.timeStyle = .short
            tf.dateStyle = .none
            return "Yesterday \(tf.string(from: date))"
        } else if let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 {
            let df = DateFormatter()
            df.dateFormat = "EEEE HH:mm"
            return df.string(from: date)
        } else {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return df.string(from: date)
        }
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

    private func parseISO(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}

// MARK: - Source badge

private struct SourceBadge: View {
    let source: String

    private var isMeeting: Bool { source == "meeting" }

    var body: some View {
        Image(systemName: isMeeting ? "person.2.fill" : "mic.fill")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isMeeting ? .green : .blue)
            .frame(width: 20, height: 20)
            .background(
                (isMeeting ? Color.green : Color.blue).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
    }
}
