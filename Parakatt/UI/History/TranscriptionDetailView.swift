import SwiftUI
import ParakattCore
import UniformTypeIdentifiers

/// Detail view for a single transcription — header, toolbar, scrollable text.
/// When timestamp segments are available, shows a timeline view instead of flat text.
struct TranscriptionDetailView: View {
    @EnvironmentObject private var appState: AppState
    let sections: [HistorySection]
    let item: StoredTranscription
    let segments: [TimestampedSegment]
    let recognizedText: String?
    let processingStatus: String?
    let hasSpeakerLabels: Bool
    let speakerHues: [String: Double]
    let onTitleChanged: (String) -> Void
    let onDelete: () -> Void

    @State private var findText = ""
    @State private var matches: [TranscriptMatch] = []
    @State private var activeMatch = 0
    @FocusState private var findFocused: Bool
    private var searchSections: [String] {
        if showRecognized && !segments.isEmpty { return segments.map(\.text) }
        return (showRecognized ? (recognizedText ?? item.text) : item.text).components(separatedBy: "\n\n")
    }
    private func updateMatches() { matches = TranscriptSearch.matches(in: searchSections, query: findText); activeMatch = 0 }
    private func matchedText(_ text: String, section: Int) -> Text {
        guard !findText.isEmpty else { return Text(text) }
        let value = NSMutableAttributedString(string: text)
        for (index, match) in matches.enumerated() where match.section == section && NSMaxRange(match.range) <= value.length {
            value.addAttribute(.backgroundColor, value: index == activeMatch ? NSColor.systemOrange.withAlphaComponent(0.55) : NSColor.systemYellow.withAlphaComponent(0.25), range: match.range)
        }
        return Text(AttributedString(value))
    }
    private func moveMatch(_ direction: Int) {
        guard !matches.isEmpty else { return }
        activeMatch = (activeMatch + direction + matches.count) % matches.count
    }

    @State private var editingText = false
    @State private var correctedText = ""
    @State private var operationBusy = false
    @State private var operationError: String?
    @State private var showRecognized = false
    @State private var editingTitle = false
    @State private var titleText = ""
    @State private var showDeleteConfirm = false
    @State private var copied = false
    @FocusState private var titleFieldFocused: Bool

    init(item: StoredTranscription, segments: [TimestampedSegment], recognizedText: String?, processingStatus: String?, hasSpeakerLabels: Bool, onTitleChanged: @escaping (String) -> Void, onDelete: @escaping () -> Void, initiallyShowRecognized: Bool = false, speakerHues: [String: Double]? = nil, sections: [HistorySection] = []) {
        self.sections = sections
        self.item = item
        self.segments = segments
        self.recognizedText = recognizedText
        self.processingStatus = processingStatus
        self.hasSpeakerLabels = hasSpeakerLabels
        self.speakerHues = speakerHues ?? HistoryDetailData(segments: segments).speakerHues
        self.onTitleChanged = onTitleChanged
        self.onDelete = onDelete
        _showRecognized = State(initialValue: initiallyShowRecognized)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Picker("Transcript view", selection: $showRecognized) {
                    Text("Processed text").tag(false)
                    Text("Recognized timeline").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380, alignment: .leading)
                if ["degraded", "incomplete", "interrupted"].contains(processingStatus ?? "") {
                    Label(processingStatus == "degraded" ? "Some sections use recognized text because processing did not complete." : "This recording is incomplete. Available recognized text has been kept.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            if sections.contains(where: { $0.status == "failed" || $0.status == "speech_failed" }) {
                DisclosureGroup("Sections that need attention") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(sections.filter { $0.status == "failed" || $0.status == "speech_failed" }.enumerated()), id: \.offset) { entry in
                                let section = entry.element
                                Text("Section \(section.chunkId + 1) (\(String(describing: section.source))): \(section.status == "speech_failed" ? "Speech was not recognized. Review recovery." : "Processing failed or was skipped. Recognized text was kept.")")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 100)
                }.padding(.horizontal, 20).padding(.bottom, 10)
            }
            if let operationError {
                Text(operationError).font(.callout).foregroundStyle(.red).padding(.horizontal, 20)
            }
            textSection
                .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { if operationBusy { appState.cancelHistoryProcessing(id: item.id) } }
        .sheet(isPresented: $editingText) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit processed text").font(.title2)
                Text("The original recognized text and timeline remain available.").foregroundStyle(.secondary)
                TextEditor(text: $correctedText).font(.body).border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Cancel") { editingText = false }
                    Spacer()
                    Button("Save") {
                        let text = correctedText
                        performHistoryChange { try $0.editTranscription(id: item.id, text: text) }
                        showRecognized = false
                        editingText = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 600, height: 440)
        }
        .alert("Delete Transcription?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This transcription will be permanently removed.")
        }
    }

    private func performHistoryChange(_ work: @escaping (CoreBridge) throws -> Void) {
        operationBusy = true
        operationError = nil
        appState.changeHistory(work) { error in
            operationBusy = false
            operationError = error
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Editable title
            titleView

            // Metadata chips
            MetadataFlowLayout(spacing: 12) {
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
                    NSPasteboard.general.setString(showRecognized ? (recognizedText ?? (segments.isEmpty ? item.text : segments.map(\.text).joined(separator: " "))) : item.text, forType: .string)
                    let anim: Animation? = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? nil : .easeInOut(duration: 0.2)
                    withAnimation(anim) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        withAnimation(anim) { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .tint(copied ? .green : nil)

                Menu {
                    Button("Markdown (.md)") { exportMarkdown() }
                    Button("JSON (.json)") { exportJSON() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }

                Menu {
                    Button("Edit processed text…") { correctedText = item.text; editingText = true }.disabled(operationBusy)
                    Button("Undo last text change") {
                        performHistoryChange { try $0.undoTranscriptionEdit(id: item.id) }
                    }.disabled(operationBusy)
                    Button("Retry failed processing") {
                        performHistoryChange { try $0.retryHistoryProcessing(id: item.id) }
                    }.disabled(operationBusy || processingStatus != "degraded")
                    Button("Cancel processing") { appState.cancelHistoryProcessing(id: item.id) }.disabled(!operationBusy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("Edit text or retry processing")
                if operationBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 4)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
                .disabled(operationBusy)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Title

    @ViewBuilder
    private var titleView: some View {
        HStack(alignment: .top, spacing: 8) {
            if editingTitle {
                TextField("Title", text: $titleText, axis: .vertical)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .lineLimit(1...2)
                    .focused($titleFieldFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { cancelTitleEdit() }
                    .onAppear { titleFieldFocused = true }
                Button(action: commitTitle) {
                    Image(systemName: "checkmark")
                }
                .help("Save title")
                .accessibilityLabel("Save title")
                Button(action: cancelTitleEdit) {
                    Image(systemName: "xmark")
                }
                .help("Cancel title edit")
                .accessibilityLabel("Cancel title edit")
            } else {
                Text(item.title ?? "Untitled")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { beginTitleEdit() }
                Button(action: beginTitleEdit) {
                    Image(systemName: "pencil")
                }
                .help("Edit title")
                .accessibilityLabel("Edit title")
            }
        }
        .buttonStyle(.borderless)
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
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack {
                    TextField("Find in transcript", text: $findText).textFieldStyle(.roundedBorder).focused($findFocused)
                        .onSubmit { moveMatch(1) }
                    Text(matches.isEmpty ? "0 matches" : "\(activeMatch + 1) / \(matches.count)\(matches.count == 2000 ? "+" : "")").font(.caption)
                    Button { moveMatch(-1) } label: { Image(systemName: "chevron.up") }.help("Previous match").disabled(matches.isEmpty)
                    Button { moveMatch(1) } label: { Image(systemName: "chevron.down") }.help("Next match").disabled(matches.isEmpty)
                    Button("Next match") { moveMatch(1) }.keyboardShortcut("g", modifiers: .command).hidden().frame(width: 0)
                    Button("Previous match") { moveMatch(-1) }.keyboardShortcut("g", modifiers: [.command, .shift]).hidden().frame(width: 0)
                }.padding(.horizontal, 20).padding(.vertical, 8)
                ScrollView {
                    if !showRecognized || segments.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(searchSections.enumerated()), id: \.offset) { entry in
                                matchedText(entry.element, section: entry.offset)
                                    .font(.body).lineSpacing(4).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(entry.offset)
                            }
                        }.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    } else { timelineView }
                }
            }
            .onChange(of: findText) { updateMatches(); if let match = matches.first { proxy.scrollTo(match.section, anchor: .center) } }
            .onChange(of: activeMatch) { if matches.indices.contains(activeMatch) { proxy.scrollTo(matches[activeMatch].section, anchor: .center) } }
            .onChange(of: showRecognized) { updateMatches() }
            .onChange(of: item.text) { updateMatches() }
            .onChange(of: recognizedText) { updateMatches() }
            .onChange(of: segments.count) { updateMatches() }
            .onChange(of: item.id) { findText = ""; updateMatches() }
            .background(Button("Find in transcript") { findFocused = true }.keyboardShortcut("f", modifiers: [.command, .shift]).hidden())
        }
    }

    private func speakerColor(_ name: String) -> Color {
        let hue = speakerHues[name] ?? 0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    private var timelineView: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                HStack(alignment: .top, spacing: 12) {
                    if hasSpeakerLabels {
                        speakerBadge(segment.speaker)
                    }

                    // Timestamp label
                    Text(formatTimestamp(segment.startSecs))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)

                    // Timeline dot and line
                    VStack(spacing: 0) {
                        Circle()
                            .fill(dotColor(for: segment.speaker))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        if index < segments.count - 1 {
                            Rectangle()
                                .fill(dotColor(for: segment.speaker).opacity(0.25))
                                .frame(width: 2)
                                .frame(maxHeight: .infinity)
                        }
                    }

                    // Segment text
                    matchedText(segment.text, section: index)
                        .font(.system(.body, design: .default))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 12)
                }.id(index)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private func speakerBadge(_ speaker: String?) -> some View {
        let label = speaker ?? "—"
        let color = speaker.map(speakerColor) ?? Color.secondary.opacity(0.5)
        Text(label)
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .frame(width: 76, alignment: .trailing)
            .fixedSize(horizontal: false, vertical: true)
            .help(label)
            .padding(.top, 1)
    }

    private func dotColor(for speaker: String?) -> Color {
        guard let speaker else { return Color.accentColor.opacity(0.7) }
        return speakerColor(speaker)
    }

    // MARK: - Export

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "\(item.title ?? "transcription").md"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let bodyText = TranscriptExport.markdownBody(text: item.text, recognizedText: recognizedText, segments: segments)

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

    private func exportJSON() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "\(item.title ?? "transcription").json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let dict = TranscriptExport.jsonObject(item: item, recognizedText: recognizedText, status: processingStatus, segments: segments)

            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url)
            }
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

/// Wrap whole metadata labels instead of compressing them into clipped columns.
private struct MetadataFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            let frame = layout.frames[index]
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), frames)
    }
}
