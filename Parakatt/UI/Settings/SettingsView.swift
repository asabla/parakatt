import SwiftUI
import HotKey
import ParakattCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelsSettingsView()
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }

            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            LlmSettingsView()
                .tabItem { Label("LLM", systemImage: "brain") }

            DictionarySettingsView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 520, height: 480)
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

    fileprivate struct ModeOption: Identifiable {
        let id: String
        let label: String
        let description: String
        let icon: String
        let color: Color
    }

    private let modes: [ModeOption] = [
        ModeOption(id: "dictation", label: "Dictation", description: "Raw transcription — exactly what you said", icon: "waveform", color: .blue),
        ModeOption(id: "clean", label: "Clean", description: "Fix grammar, punctuation, and formatting", icon: "text.badge.checkmark", color: .green),
        ModeOption(id: "email", label: "Email", description: "Structure output as a professional email", icon: "envelope.fill", color: .orange),
        ModeOption(id: "code", label: "Code", description: "Code-aware — preserves identifiers and syntax", icon: "chevron.left.forwardslash.chevron.right", color: .purple),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // MARK: Hotkey card
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("Hotkey")
                            .font(.headline)
                    }

                    if isRecordingHotkey {
                        // Recording mode: capture the next key combination
                        VStack(spacing: 8) {
                            Text("Press your new shortcut...")
                                .font(.system(.body, design: .rounded, weight: .medium))
                                .foregroundStyle(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))

                            if let key = pendingKey, !pendingModifiers.isEmpty {
                                HStack(spacing: 4) {
                                    hotkeyDisplay(key: key, modifiers: pendingModifiers)
                                    Spacer()
                                    Button("Apply") {
                                        currentKey = key
                                        currentModifiers = pendingModifiers
                                        appState.setHotkey(key: currentKey, modifiers: currentModifiers, mode: currentMode)
                                        isRecordingHotkey = false
                                        pendingKey = nil
                                        pendingModifiers = []
                                    }
                                    Button("Cancel") {
                                        isRecordingHotkey = false
                                        pendingKey = nil
                                        pendingModifiers = []
                                    }
                                }
                            } else {
                                Text("Requires at least one modifier (Option, Command, Control, or Shift)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)

                                Button("Cancel") {
                                    isRecordingHotkey = false
                                    pendingKey = nil
                                    pendingModifiers = []
                                }
                            }
                        }
                    } else {
                        // Display current hotkey
                        HStack(spacing: 8) {
                            hotkeyDisplay(key: currentKey, modifiers: currentModifiers)
                            Spacer()
                            Button("Change") {
                                isRecordingHotkey = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    // Mode picker: Hold vs Toggle
                    HStack(spacing: 12) {
                        Picker("", selection: $currentMode) {
                            Text("Hold to record").tag("hold")
                            Text("Toggle (tap to start/stop)").tag("toggle")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: currentMode) { _, newMode in
                            appState.setHotkey(key: currentKey, modifiers: currentModifiers, mode: newMode)
                        }
                    }

                    Text(currentMode == "hold"
                         ? "Hold modifier to record, release to transcribe"
                         : "Press hotkey to start recording, press again to stop")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Reset to default
                    if currentKey != .space || currentModifiers != [.option] || currentMode != "hold" {
                        Button("Reset to Default (Option+Space, Hold)") {
                            currentKey = .space
                            currentModifiers = [.option]
                            currentMode = "hold"
                            appState.setHotkey(key: .space, modifiers: [.option], mode: "hold")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .background {
                    HotkeyRecorderOverlay(
                        capturedKey: $pendingKey,
                        capturedModifiers: $pendingModifiers,
                        isActive: isRecordingHotkey
                    )
                    .frame(width: 0, height: 0)
                }
                .onAppear { loadCurrentHotkey() }

                Divider()

                // MARK: Active Mode
                VStack(alignment: .leading, spacing: 10) {
                    Text("Active Mode")
                        .font(.headline)
                    Text("Choose how transcriptions are processed after recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 6) {
                        ForEach(modes) { mode in
                            GeneralModeRow(
                                mode: mode,
                                isSelected: appState.activeMode == mode.id
                            ) {
                                appState.activeMode = mode.id
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func hotkeyDisplay(key: Key, modifiers: NSEvent.ModifierFlags) -> some View {
        HStack(spacing: 4) {
            ForEach(HotkeyService.modifierDisplayNames(modifiers), id: \.self) { name in
                Text(name)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            Text("+")
                .foregroundStyle(.tertiary)
            Text(HotkeyService.displayName(for: key))
                .font(.system(.body, design: .rounded, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private func loadCurrentHotkey() {
        let config = appState.loadHotkeyConfig()
        currentKey = config.key
        currentModifiers = config.modifiers
        currentMode = config.mode
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

private struct GeneralModeRow: View {
    let mode: GeneralSettingsView.ModeOption
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: mode.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? mode.color : .secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(mode.label)
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(.primary)
                        if isSelected {
                            Text("Active")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(mode.color.opacity(0.15), in: Capsule())
                                .foregroundStyle(mode.color)
                        }
                    }
                    Text(mode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(mode.color)
                        .font(.system(size: 14))
                }
            }
            .padding(10)
            .background(
                isSelected ? AnyShapeStyle(mode.color.opacity(0.06)) : AnyShapeStyle(.quaternary),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? mode.color.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

                                    if !statusMessage.isEmpty {
                                        HStack(spacing: 4) {
                                            Image(systemName: statusMessage.contains("OK") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                                .font(.caption)
                                            Text(statusMessage)
                                                .font(.caption)
                                        }
                                        .foregroundStyle(statusMessage.contains("OK") ? .green : .orange)
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
                    .foregroundStyle(isSelected ? provider.color : .secondary)
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
