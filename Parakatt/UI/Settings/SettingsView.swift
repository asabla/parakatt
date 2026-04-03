import SwiftUI
import HotKey
import ParakattCore

struct SettingsView: View {
    var body: some View {
        TabView {
            DashboardSettingsView()
                .tabItem { Label("Dashboard", systemImage: "house") }

            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }

            LlmSettingsView()
                .tabItem { Label("LLM", systemImage: "brain") }

            DictionarySettingsView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            StatisticsSettingsView()
                .tabItem { Label("Statistics", systemImage: "chart.bar") }
        }
        .frame(width: 680, height: 500)
    }
}

// MARK: - Dashboard

struct DashboardSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats: [(String, String)] = []

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // App header
                HStack(spacing: 14) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Parakatt")
                            .font(.system(.title2, weight: .bold))
                        Text("Version \(appVersion) (\(buildNumber))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Divider()

                // Quick status
                VStack(alignment: .leading, spacing: 10) {
                    Label("Status", systemImage: "circle.fill")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        DashboardStatusRow(
                            label: "Speech Model",
                            value: appState.activeModelId ?? "Not loaded",
                            icon: "cpu",
                            color: appState.isModelLoaded ? .green : .orange
                        )
                        Divider().padding(.leading, 40)
                        DashboardStatusRow(
                            label: "Processing Mode",
                            value: appState.activeMode.capitalized,
                            icon: "wand.and.stars",
                            color: .blue
                        )
                        Divider().padding(.leading, 40)
                        DashboardStatusRow(
                            label: "LLM Provider",
                            value: appState.llmProvider.isEmpty ? "None" : appState.llmProvider.capitalized,
                            icon: "brain",
                            color: appState.llmProvider.isEmpty ? .secondary : .purple
                        )
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Quick stats
                let overview = stats.filter {
                    $0.0 == "Total transcriptions" || $0.0 == "Total duration" || $0.0 == "Total words"
                }
                if !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Activity", systemImage: "chart.bar")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 10) {
                            ForEach(overview, id: \.0) { stat in
                                StatCard(label: stat.0, value: stat.1)
                            }
                        }
                    }
                }

                // Permissions
                VStack(alignment: .leading, spacing: 10) {
                    Label("Permissions", systemImage: "lock.shield")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        DashboardStatusRow(
                            label: "Accessibility",
                            value: AXIsProcessTrusted() ? "Granted" : "Not granted",
                            icon: "hand.raised.fill",
                            color: AXIsProcessTrusted() ? .green : .red
                        )
                        Divider().padding(.leading, 40)
                        DashboardStatusRow(
                            label: "Microphone",
                            value: "Granted on first use",
                            icon: "mic.fill",
                            color: .green
                        )
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .background(.quaternary.opacity(0.5))
        .onAppear {
            stats = appState.getStatistics()
        }
    }
}

private struct DashboardStatusRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 24)

            Text(label)
                .font(.body)

            Spacer()

            Text(value)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Models

struct ModelsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var models: [ParakattCore.ModelInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if appState.needsModelDownload && !appState.isDownloading {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("No speech model downloaded. Download one to start transcribing.")
                            .font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                ForEach(models, id: \.id) { model in
                    ModelRowView(model: model)
                }
            }
            .padding()
        }
        .onAppear { refreshModels() }
        .onReceive(appState.$isDownloading) { _ in refreshModels() }
        .onReceive(appState.$isModelLoaded) { _ in refreshModels() }
    }

    private func refreshModels() {
        models = appState.listModels()
    }
}

struct ModelRowView: View {
    @EnvironmentObject var appState: AppState
    let model: ParakattCore.ModelInfo

    private var isDownloadingThis: Bool {
        appState.isDownloading && appState.downloadProgress?.modelId == model.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.headline)
                        if model.downloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        if appState.activeModelId == model.id {
                            Text("Active")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                                .foregroundStyle(.blue)
                        }
                    }
                    if let desc = model.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(formatBytes(model.sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isDownloadingThis {
                    Button("Cancel") {
                        appState.cancelModelDownload()
                    }
                } else if model.downloaded {
                    Button("Delete") {
                        appState.deleteModel(model.id)
                    }
                } else {
                    Button("Download") {
                        appState.startModelDownload(model.id)
                    }
                    .disabled(appState.isDownloading)
                }
            }

            if isDownloadingThis, let progress = appState.downloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progressFraction(progress))

                    HStack {
                        Text("File \(progress.fileIndex + 1)/\(progress.totalFiles): \(progress.currentFile)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if progress.bytesTotal > 0 {
                            Text("\(formatBytes(progress.bytesDownloaded)) / \(formatBytes(progress.bytesTotal))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func progressFraction(_ progress: ParakattCore.DownloadProgress) -> Double {
        guard progress.bytesTotal > 0 else { return 0 }
        return Double(progress.bytesDownloaded) / Double(progress.bytesTotal)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1.0 {
            return String(format: "%.0f MB", mb)
        }
        let kb = Double(bytes) / 1_000
        return String(format: "%.0f KB", kb)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecordingHotkey = false
    @State private var pendingKey: Key?
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    @State private var currentKey: Key = .space
    @State private var currentModifiers: NSEvent.ModifierFlags = [.option]
    @State private var currentMode: String = "hold"
    @State private var showNewModeSheet = false
    @State private var loadedModes: [ModeConfig] = []

    fileprivate struct ModeOption: Identifiable {
        let id: String
        let label: String
        let description: String
        let icon: String
        let color: Color
        let isCustom: Bool
    }

    private static let builtinNames = Set(["dictation", "clean", "email", "code"])

    private static func iconForMode(_ name: String) -> String {
        switch name.lowercased() {
        case "dictation": return "waveform"
        case "clean": return "text.badge.checkmark"
        case "email": return "envelope.fill"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "star.fill"
        }
    }

    private static func colorForMode(_ name: String) -> Color {
        switch name.lowercased() {
        case "dictation": return .blue
        case "clean": return .green
        case "email": return .orange
        case "code": return .purple
        default: return .pink
        }
    }

    private var modes: [ModeOption] {
        loadedModes.map { m in
            let isCustom = !Self.builtinNames.contains(m.name.lowercased())
            let desc: String
            if isCustom {
                if let prompt = m.systemPrompt, !prompt.isEmpty {
                    desc = String(prompt.prefix(60)) + (prompt.count > 60 ? "..." : "")
                } else {
                    desc = "Custom mode"
                }
            } else {
                desc = builtinDescription(m.name)
            }
            return ModeOption(
                id: m.name,
                label: m.name.capitalized,
                description: desc,
                icon: Self.iconForMode(m.name),
                color: Self.colorForMode(m.name),
                isCustom: isCustom
            )
        }
    }

    private func builtinDescription(_ name: String) -> String {
        switch name.lowercased() {
        case "dictation": return "Raw transcription — exactly what you said"
        case "clean": return "Fix grammar, punctuation, and formatting"
        case "email": return "Structure output as a professional email"
        case "code": return "Code-aware — preserves identifiers and syntax"
        default: return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: - Shortcut section
                VStack(alignment: .leading, spacing: 14) {
                    Label("Shortcut", systemImage: "keyboard")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    // Keycap display / recorder
                    VStack(spacing: 12) {
                        if isRecordingHotkey {
                            hotkeyRecorderContent
                        } else {
                            hotkeyDisplayContent
                        }

                        // Trigger behavior
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 0) {
                                triggerButton(
                                    title: "Hold",
                                    subtitle: "Release to finish",
                                    icon: "hand.tap",
                                    isSelected: currentMode == "hold"
                                ) { currentMode = "hold" }

                                triggerButton(
                                    title: "Toggle",
                                    subtitle: "Tap to start & stop",
                                    icon: "arrow.triangle.2.circlepath",
                                    isSelected: currentMode == "toggle"
                                ) { currentMode = "toggle" }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onChange(of: currentMode) { _, newMode in
                                appState.setHotkey(key: currentKey, modifiers: currentModifiers, mode: newMode)
                            }
                        }

                        // Reset link
                        if currentKey != .space || currentModifiers != [.option] || currentMode != "hold" {
                            HStack {
                                Spacer()
                                Button {
                                    currentKey = .space
                                    currentModifiers = [.option]
                                    currentMode = "hold"
                                    appState.setHotkey(key: .space, modifiers: [.option], mode: "hold")
                                } label: {
                                    Label("Reset to default", systemImage: "arrow.counterclockwise")
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                }
                .background {
                    HotkeyRecorderOverlay(
                        capturedKey: $pendingKey,
                        capturedModifiers: $pendingModifiers,
                        isActive: isRecordingHotkey
                    )
                    .frame(width: 0, height: 0)
                }
                .onAppear { loadCurrentHotkey() }

                // MARK: - Processing mode section
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Processing Mode", systemImage: "wand.and.stars")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Spacer()

                        Button {
                            showNewModeSheet = true
                        } label: {
                            Label("New Mode", systemImage: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                    }

                    VStack(spacing: 0) {
                        ForEach(Array(modes.enumerated()), id: \.element.id) { index, mode in
                            GeneralModeRow(
                                mode: mode,
                                isSelected: appState.activeMode == mode.id,
                                onSelect: {
                                    appState.activeMode = mode.id
                                },
                                onDelete: mode.isCustom ? {
                                    appState.deleteMode(mode.id)
                                    if appState.activeMode == mode.id {
                                        appState.activeMode = "dictation"
                                    }
                                    reloadModes()
                                } : nil
                            )

                            if index < modes.count - 1 {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .onAppear { reloadModes() }
                .sheet(isPresented: $showNewModeSheet) {
                    NewModeSheet { name, prompt in
                        let mode = ModeConfig(
                            name: name.lowercased(),
                            sttProvider: nil,
                            llmProvider: nil,
                            systemPrompt: prompt.isEmpty ? nil : prompt,
                            dictionaryEnabled: true
                        )
                        appState.saveMode(mode)
                        reloadModes()
                    }
                }

                // MARK: - Behavior section
                VStack(alignment: .leading, spacing: 10) {
                    Label("Behavior", systemImage: "slider.horizontal.3")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)

                    VStack(spacing: 0) {
                        BehaviorToggleRow(
                            icon: "doc.on.clipboard",
                            color: .blue,
                            label: "Auto-paste transcription",
                            description: "Automatically insert text at cursor after recording",
                            isOn: Binding(
                                get: { appState.autoPaste },
                                set: { appState.setAutoPaste($0) }
                            )
                        )

                        Divider().padding(.leading, 52)

                        BehaviorToggleRow(
                            icon: "rectangle.on.rectangle",
                            color: .green,
                            label: "Show recording overlay",
                            description: "Display a floating window with live transcription while recording",
                            isOn: Binding(
                                get: { appState.showRecordingOverlay },
                                set: { appState.setShowOverlay($0) }
                            )
                        )

                        Divider().padding(.leading, 52)

                        BehaviorToggleRow(
                            icon: "ant",
                            color: .orange,
                            label: "Debug mode",
                            description: "Enable verbose logging for troubleshooting (visible in Console.app)",
                            isOn: Binding(
                                get: { appState.debugMode },
                                set: { appState.setDebugMode($0) }
                            )
                        )
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.background)
                            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .background(.quaternary.opacity(0.5))
    }

    // MARK: - Hotkey display (idle state)

    @ViewBuilder
    private var hotkeyDisplayContent: some View {
        HStack {
            keycapRow(key: currentKey, modifiers: currentModifiers)
            Spacer()
            Button {
                isRecordingHotkey = true
            } label: {
                Text("Record New Shortcut")
                    .font(.system(.caption, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Hotkey recorder (active state)

    @ViewBuilder
    private var hotkeyRecorderContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse.wholeSymbol, isActive: true)
                Text("Press your new shortcut")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.red.opacity(0.2), lineWidth: 1)
            }

            if let key = pendingKey, !pendingModifiers.isEmpty {
                HStack {
                    keycapRow(key: key, modifiers: pendingModifiers)
                    Spacer(minLength: 12)
                    Button("Apply") {
                        currentKey = key
                        currentModifiers = pendingModifiers
                        appState.setHotkey(key: currentKey, modifiers: currentModifiers, mode: currentMode)
                        dismissRecorder()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button("Cancel") { dismissRecorder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Include at least one modifier key")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel") { dismissRecorder() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Keycap row

    @ViewBuilder
    private func keycapRow(key: Key, modifiers: NSEvent.ModifierFlags) -> some View {
        HStack(spacing: 5) {
            ForEach(modifierSymbols(modifiers), id: \.self) { symbol in
                keycap(symbol)
            }
            keycap(HotkeyService.displayName(for: key))
        }
    }

    @ViewBuilder
    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(.body, design: .rounded, weight: .semibold))
            .frame(minWidth: 32, minHeight: 28)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.1), radius: 0.5, y: 0.5)
    }

    // MARK: - Trigger mode button

    @ViewBuilder
    private func triggerButton(
        title: String,
        subtitle: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.blue.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func dismissRecorder() {
        isRecordingHotkey = false
        pendingKey = nil
        pendingModifiers = []
    }

    private func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> [String] {
        var result: [String] = []
        if flags.contains(.control) { result.append("\u{2303}") }
        if flags.contains(.option)  { result.append("\u{2325}") }
        if flags.contains(.shift)   { result.append("\u{21E7}") }
        if flags.contains(.command) { result.append("\u{2318}") }
        return result
    }

    private func loadCurrentHotkey() {
        let config = appState.loadHotkeyConfig()
        currentKey = config.key
        currentModifiers = config.modifiers
        currentMode = config.mode
    }

    private func reloadModes() {
        loadedModes = appState.listModes()
    }
}

/// NSView wrapper that captures key events for hotkey recording.
struct HotkeyRecorderOverlay: NSViewRepresentable {
    @Binding var capturedKey: Key?
    @Binding var capturedModifiers: NSEvent.ModifierFlags
    var isActive: Bool

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onKeyCaptured = { key, modifiers in
            capturedKey = key
            capturedModifiers = modifiers
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.isCapturing = isActive
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class HotkeyRecorderNSView: NSView {
    var onKeyCaptured: ((Key, NSEvent.ModifierFlags) -> Void)?
    var isCapturing = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.isEmpty else { return } // Require at least one modifier

        // Map Carbon keyCode to HotKey.Key
        if let key = HotkeyService.keyFromString(keyCodeToString(event.keyCode)) {
            onKeyCaptured?(key, modifiers)
        }
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        // Carbon virtual key codes to string names
        switch keyCode {
        case 49: return "space"
        case 48: return "tab"
        case 36: return "return"
        case 53: return "escape"
        case 51: return "delete"
        case 0: return "a"; case 11: return "b"; case 8: return "c"; case 2: return "d"
        case 14: return "e"; case 3: return "f"; case 5: return "g"; case 4: return "h"
        case 34: return "i"; case 38: return "j"; case 40: return "k"; case 37: return "l"
        case 46: return "m"; case 45: return "n"; case 31: return "o"; case 35: return "p"
        case 12: return "q"; case 15: return "r"; case 1: return "s"; case 17: return "t"
        case 32: return "u"; case 9: return "v"; case 13: return "w"; case 7: return "x"
        case 16: return "y"; case 6: return "z"
        case 29: return "0"; case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 23: return "5"; case 22: return "6"; case 26: return "7"
        case 28: return "8"; case 25: return "9"
        case 122: return "f1"; case 120: return "f2"; case 99: return "f3"; case 118: return "f4"
        case 96: return "f5"; case 97: return "f6"; case 98: return "f7"; case 100: return "f8"
        case 101: return "f9"; case 109: return "f10"; case 103: return "f11"; case 111: return "f12"
        default: return ""
        }
    }
}

private struct BehaviorToggleRow: View {
    let icon: String
    let color: Color
    let label: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOn ? .white : color)
                .frame(width: 28, height: 28)
                .background(
                    isOn ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.15)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(.body, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct GeneralModeRow: View {
    let mode: GeneralSettingsView.ModeOption
    let isSelected: Bool
    let onSelect: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? .white : mode.color)
                    .frame(width: 28, height: 28)
                    .background(
                        isSelected ? AnyShapeStyle(mode.color) : AnyShapeStyle(mode.color.opacity(0.15)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(mode.label)
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(.primary)
                        if mode.isCustom {
                            Text("Custom")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(mode.color.opacity(0.15), in: Capsule())
                                .foregroundStyle(mode.color)
                        }
                    }
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if let onDelete {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete custom mode")
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(mode.color)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? mode.color.opacity(0.04) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NewModeSheet: View {
    var onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Custom Mode")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g., Summary, Translate, Notes", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $prompt)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text("This prompt tells the LLM how to process your transcription.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Create") {
                    onSave(name, prompt)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - LLM Settings

struct LlmSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var availableModels: [String] = []
    @State private var statusMessage = ""
    @State private var isFetching = false

    fileprivate struct ProviderOption: Identifiable {
        let id: String
        let label: String
        let description: String
        let icon: String
        let color: Color
    }

    private let providers: [ProviderOption] = [
        ProviderOption(id: "", label: "None", description: "Dictation only — no post-processing", icon: "mic.fill", color: .secondary),
        ProviderOption(id: "ollama", label: "Ollama", description: "Local inference server", icon: "desktopcomputer", color: .blue),
        ProviderOption(id: "lmstudio", label: "LM Studio", description: "Local model runtime", icon: "cpu.fill", color: .purple),
        ProviderOption(id: "openai", label: "OpenAI", description: "Remote API — requires key", icon: "globe", color: .green),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Provider selection
                VStack(alignment: .leading, spacing: 10) {
                    Text("Provider")
                        .font(.headline)
                    Text("Choose an LLM backend for post-processing transcriptions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(providers) { provider in
                            LlmProviderRow(
                                provider: provider,
                                isSelected: appState.llmProvider == provider.id
                            ) {
                                appState.llmProvider = provider.id
                                setDefaults(for: provider.id)
                                availableModels = []
                                appState.llmModel = ""
                                statusMessage = ""
                            }
                        }
                    }
                }

                // MARK: Connection settings
                if !appState.llmProvider.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text("Connection")
                                .font(.headline)
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            if appState.llmProvider == "openai" {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("API Key")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    SecureField("sk-...", text: $appState.llmApiKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Server URL")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("http://localhost:11434", text: $appState.llmBaseUrl)
                                    .textFieldStyle(.roundedBorder)
                            }

                            HStack {
                                if availableModels.isEmpty {
                                    Button {
                                        fetchModels()
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isFetching {
                                                ProgressView()
                                                    .controlSize(.small)
                                            } else {
                                                Image(systemName: "arrow.down.circle")
                                                    .font(.caption)
                                            }
                                            Text(isFetching ? "Fetching..." : "Fetch Models")
                                        }
                                    }
                                    .disabled(isFetching)
                                } else {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Model")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        HStack {
                                            Picker("", selection: $appState.llmModel) {
                                                Text("Select a model...").tag("")
                                                ForEach(availableModels, id: \.self) { model in
                                                    Text(model).tag(model)
                                                }
                                            }
                                            .labelsHidden()

                                            Button {
                                                fetchModels()
                                            } label: {
                                                Image(systemName: "arrow.clockwise")
                                            }
                                        }
                                    }
                                }
                            }

                            if !appState.llmModel.isEmpty {
                                HStack(spacing: 8) {
                                    Button("Apply") { applyConfig() }

                                    Button("Test Connection") { testConnection() }

                                    if !statusMessage.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: statusMessage.contains("OK") || statusMessage.contains("reachable") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                                .font(.caption)
                                            Text(statusMessage)
                                                .font(.caption)
                                        }
                                        .foregroundStyle(statusMessage.contains("OK") || statusMessage.contains("reachable") ? .green : .orange)
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }

                    // MARK: How it works
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                            .padding(.top, 1)
                        Text("When a mode other than \"Dictation\" is active, the transcription is sent to the LLM for post-processing (grammar fixing, email formatting, etc). Domain words from the Dictionary are included as context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding()
        }
    }

    private func setDefaults(for provider: String) {
        switch provider {
        case "ollama":
            appState.llmBaseUrl = "http://localhost:11434"
        case "lmstudio":
            appState.llmBaseUrl = "http://localhost:1234"
        case "openai":
            appState.llmBaseUrl = "https://api.openai.com"
        default:
            break
        }
    }

    private func fetchModels() {
        isFetching = true
        statusMessage = ""

        DispatchQueue.global(qos: .userInitiated).async {
            let models = appState.fetchLlmModels()

            DispatchQueue.main.async {
                isFetching = false
                availableModels = models
                if models.isEmpty {
                    statusMessage = "No models found — is the server running?"
                } else if models.count == 1 {
                    appState.llmModel = models[0]
                }
            }
        }
    }

    private func applyConfig() {
        appState.configureLlm()
        statusMessage = "OK — \(appState.llmModel)"
    }

    private func testConnection() {
        // Apply first to ensure current settings are active
        appState.configureLlm()
        statusMessage = "Testing..."

        DispatchQueue.global(qos: .userInitiated).async {
            let result = appState.testLlmConnection()
            DispatchQueue.main.async {
                statusMessage = result
            }
        }
    }
}

private struct LlmProviderRow: View {
    let provider: LlmSettingsView.ProviderOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: provider.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(provider.color)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(provider.label)
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(.primary)
                        if isSelected && !provider.id.isEmpty {
                            Text("Active")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(provider.color.opacity(0.15), in: Capsule())
                                .foregroundStyle(provider.color)
                        }
                    }
                    Text(provider.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isSelected && !provider.id.isEmpty ? provider.color : .secondary)
                        .font(.system(size: 14))
                }
            }
            .padding(10)
            .background(
                isSelected ? AnyShapeStyle(provider.color.opacity(0.06)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? provider.color.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dictionary

struct DictionarySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var domainWords: [String] = []
    @State private var replacements: [Replacement] = []
    @State private var newDomainWord = ""
    @State private var newPattern = ""
    @State private var newReplacement = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Domain words
                VStack(alignment: .leading, spacing: 8) {
                    Text("Domain Words")
                        .font(.headline)
                    Text("Words the transcriber should know about. Helps distinguish similar-sounding words (e.g. \"eval\" not \"evil\", \"kubectl\" not \"cube control\").")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(domainWords, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                    .font(.body.monospaced())
                                Button {
                                    domainWords.removeAll { $0 == word }
                                    save()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    HStack {
                        TextField("Add word (e.g. eval, kubectl, Parakatt)", text: $newDomainWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addDomainWord() }
                        Button("Add") { addDomainWord() }
                            .disabled(newDomainWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Divider()

                // MARK: Replacements
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replacements")
                        .font(.headline)
                    Text("Always replace one word/phrase with another after transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !replacements.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(replacements) { r in
                                HStack {
                                    Text(r.pattern)
                                        .font(.body.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                    Text(r.replacement)
                                        .font(.body.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        replacements.removeAll { $0.id == r.id }
                                        save()
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Pattern", text: $newPattern)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Replacement", text: $newReplacement)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") { addReplacement() }
                            .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding()
        }
        .onAppear { load() }
    }

    // MARK: - Actions

    private func addDomainWord() {
        let word = newDomainWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !domainWords.contains(word) else { return }
        domainWords.append(word)
        newDomainWord = ""
        save()
    }

    private func addReplacement() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        let r = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !r.isEmpty else { return }
        replacements.append(Replacement(pattern: p, replacement: r))
        newPattern = ""
        newReplacement = ""
        save()
    }

    // MARK: - Persistence (via Rust engine)

    private func load() {
        let rules = appState.getDictionaryRules()
        domainWords = []
        replacements = []
        for rule in rules {
            if rule.pattern == rule.replacement {
                // Domain word: pattern == replacement means "keep this word as-is"
                domainWords.append(rule.pattern)
            } else {
                replacements.append(Replacement(pattern: rule.pattern, replacement: rule.replacement))
            }
        }
    }

    private func save() {
        var rules: [ParakattCore.ReplacementRule] = []

        // Domain words stored as identity replacements (pattern == replacement)
        for word in domainWords {
            rules.append(ParakattCore.ReplacementRule(
                pattern: word,
                replacement: word,
                contextType: "always",
                contextValue: nil,
                enabled: true
            ))
        }

        // Explicit replacements
        for r in replacements {
            rules.append(ParakattCore.ReplacementRule(
                pattern: r.pattern,
                replacement: r.replacement,
                contextType: "always",
                contextValue: nil,
                enabled: true
            ))
        }

        appState.setDictionaryRules(rules)
    }
}

struct Replacement: Identifiable {
    let id = UUID()
    let pattern: String
    let replacement: String
}

// MARK: - Flow Layout (tag cloud)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

// MARK: - Statistics

struct StatisticsSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats: [(String, String)] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Overview cards
                let overview = stats.filter { !$0.0.hasPrefix("Mode:") && $0.0 != "Voice notes" && $0.0 != "Meetings" }
                if !overview.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Overview", systemImage: "chart.bar")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 10) {
                            ForEach(overview, id: \.0) { stat in
                                StatCard(label: stat.0, value: stat.1)
                            }
                        }
                    }
                }

                // By source
                let sources = stats.filter { $0.0 == "Voice notes" || $0.0 == "Meetings" }
                if !sources.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("By Type", systemImage: "square.stack")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        VStack(spacing: 0) {
                            ForEach(Array(sources.enumerated()), id: \.element.0) { index, stat in
                                StatRow(
                                    label: stat.0,
                                    value: stat.1,
                                    icon: stat.0 == "Meetings" ? "person.2.fill" : "mic.fill",
                                    color: stat.0 == "Meetings" ? .orange : .blue
                                )
                                if index < sources.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.background)
                                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.quaternary, lineWidth: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                // By mode
                let modes = stats.filter { $0.0.hasPrefix("Mode: ") }
                if !modes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("By Mode", systemImage: "wand.and.stars")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        VStack(spacing: 0) {
                            ForEach(Array(modes.enumerated()), id: \.element.0) { index, stat in
                                let modeName = String(stat.0.dropFirst(6)) // Drop "Mode: "
                                StatRow(
                                    label: modeName.capitalized,
                                    value: stat.1,
                                    icon: modeIcon(modeName),
                                    color: modeColor(modeName)
                                )
                                if index < modes.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.background)
                                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.quaternary, lineWidth: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Details section
                let details = stats.filter {
                    $0.0 == "Avg duration" || $0.0 == "Longest" || $0.0 == "Total segments" || $0.0 == "Database size"
                }
                if !details.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Details", systemImage: "info.circle")
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        VStack(spacing: 0) {
                            ForEach(Array(details.enumerated()), id: \.element.0) { index, stat in
                                StatRow(
                                    label: stat.0,
                                    value: stat.1,
                                    icon: detailIcon(stat.0),
                                    color: .secondary
                                )
                                if index < details.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.background)
                                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.quaternary, lineWidth: 0.5)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                if stats.isEmpty && !isLoading {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar")
                            .font(.largeTitle)
                            .foregroundStyle(.quaternary)
                        Text("No transcriptions yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(20)
        }
        .background(.quaternary.opacity(0.5))
        .onAppear { loadStats() }
    }

    private func loadStats() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = appState.getStatistics()
            DispatchQueue.main.async {
                stats = result
                isLoading = false
            }
        }
    }

    private func modeIcon(_ mode: String) -> String {
        switch mode.lowercased() {
        case "dictation": return "waveform"
        case "clean": return "text.badge.checkmark"
        case "email": return "envelope.fill"
        case "code": return "chevron.left.forwardslash.chevron.right"
        default: return "star"
        }
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode.lowercased() {
        case "dictation": return .blue
        case "clean": return .green
        case "email": return .orange
        case "code": return .purple
        default: return .secondary
        }
    }

    private func detailIcon(_ label: String) -> String {
        switch label {
        case "Avg duration": return "timer"
        case "Longest": return "arrow.up.right"
        case "Total segments": return "list.bullet"
        case "Database size": return "externaldrive"
        default: return "info.circle"
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 24)

            Text(label)
                .font(.body)

            Spacer()

            Text(value)
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
