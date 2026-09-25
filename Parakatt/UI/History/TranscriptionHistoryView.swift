import SwiftUI
import ParakattCore
import UniformTypeIdentifiers

/// Main history window — master-detail split inspired by Notes.app.
struct TranscriptionHistoryView: View {
    @EnvironmentObject var appState: AppState

    @State private var queryGeneration = UUID()
    @State private var searchTask: Task<Void, Never>?
    @State private var segmentCache: [String: HistoryDetailData] = [:]
    @State private var selectedDetail = HistoryDetailData()
    @State private var searchText = ""
    @State private var sidebarVisible = true
    @FocusState private var searchFocused: Bool
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

    init(selectedId: String? = nil) {
        _selectedId = State(initialValue: selectedId)
    }

    var body: some View {
        // Keep controls in the content layout. An implicit navigation toolbar can
        // extend over the detail header when this view is hosted in an NSWindow.
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                if sidebarVisible {
                    sidebarContent
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
                detailContent
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { refresh() }
        .onReceive(appState.$historyRevision.dropFirst()) { _ in refresh(invalidateCache: true) }
        .onChange(of: selectedId) { loadSegments() }
        .onDisappear { searchTask?.cancel(); queryGeneration = UUID() }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            .accessibilityLabel("Toggle sidebar")
            .keyboardShortcut("s", modifiers: [.command, .control])

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcriptions", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { refresh() }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            .frame(maxWidth: 360)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: searchText) {
            if !searchText.isEmpty { sidebarVisible = true }
            refresh(debounce: true)
        }
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
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
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)

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
                    .listRowSeparator(.hidden)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedIds.contains(item.id) {
                            selectedIds.remove(item.id)
                        } else {
                            selectedIds.insert(item.id)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                // Normal single-select list
                List(transcriptions, id: \.id, selection: $selectedId) { item in
                    TranscriptionRow(item: item)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                        .listRowSeparator(.hidden)
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
                                refresh(invalidateCache: true)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .alert("Delete \(selectedIds.count) transcription\(selectedIds.count == 1 ? "" : "s")?",
               isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                let count = appState.deleteTranscriptions(ids: Array(selectedIds))
                NSLog("[Parakatt] Bulk deleted %d transcriptions", count)
                selectedIds.removeAll()
                isSelectionMode = false
                selectedId = nil
                refresh(invalidateCache: true)
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
                segments: selectedDetail.segments,
                recognizedText: selectedDetail.recognizedText,
                processingStatus: selectedDetail.processingStatus,
                hasSpeakerLabels: selectedDetail.hasSpeakerLabels,
                onTitleChanged: { newTitle in
                    appState.updateTranscriptionTitle(id: id, title: newTitle)
                    refresh(invalidateCache: true)
                },
                onDelete: {
                    appState.deleteTranscription(id: id)
                    selectedId = nil
                    refresh(invalidateCache: true)
                },
                speakerHues: selectedDetail.speakerHues
            ).id(id)
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

    private func refresh(debounce: Bool = false, invalidateCache: Bool = false) {
        searchTask?.cancel()
        let generation = UUID()
        queryGeneration = generation
        if invalidateCache { segmentCache.removeAll() }
        searchTask = Task { @MainActor in
            if debounce {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
            guard !Task.isCancelled else { return }
            appState.queryHistory(search: searchText.isEmpty ? nil : searchText, source: sourceFilter) { rows in
                guard queryGeneration == generation else { return }
                transcriptions = rows
                loadSegments()
            }
        }
    }

    private func loadSegments() {
        guard let id = selectedId else { selectedDetail = HistoryDetailData(); return }
        if let cached = segmentCache[id] { selectedDetail = cached; return }
        selectedDetail = HistoryDetailData()
        let generation = queryGeneration
        appState.queryDetail(id: id) { rows in
            guard queryGeneration == generation else { return }
            segmentCache[id] = rows
            if selectedId == id { selectedDetail = rows }
        }
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
                    .foregroundStyle(.secondary)
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
