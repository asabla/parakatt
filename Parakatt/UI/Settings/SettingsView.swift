import SwiftUI
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

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Option (⌥) + Space — hold to record, release to transcribe")
                    .foregroundStyle(.secondary)
            }

            Section("Active Mode") {
                Picker("Mode", selection: $appState.activeMode) {
                    Text("Dictation — raw transcription").tag("dictation")
                    Text("Clean — fix grammar").tag("clean")
                    Text("Email — format as email").tag("email")
                    Text("Code — code-aware").tag("code")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding()
    }
}

// MARK: - LLM Settings

struct LlmSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var availableModels: [String] = []
    @State private var statusMessage = ""
    @State private var isFetching = false

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $appState.llmProvider) {
                    Text("None (dictation only)").tag("")
                    Text("Ollama (local)").tag("ollama")
                    Text("LM Studio (local)").tag("lmstudio")
                    Text("OpenAI (remote)").tag("openai")
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.llmProvider) { _, newValue in
                    setDefaults(for: newValue)
                    availableModels = []
                    appState.llmModel = ""
                    statusMessage = ""
                }
            }

            if !appState.llmProvider.isEmpty {
                Section("Connection") {
                    if appState.llmProvider == "openai" {
                        SecureField("API Key", text: $appState.llmApiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    TextField("Server URL", text: $appState.llmBaseUrl)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        if availableModels.isEmpty {
                            Button(isFetching ? "Fetching..." : "Fetch Models") {
                                fetchModels()
                            }
                            .disabled(isFetching)
                        } else {
                            Picker("Model", selection: $appState.llmModel) {
                                Text("Select a model...").tag("")
                                ForEach(availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }

                            Button {
                                fetchModels()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                    }

                    if !appState.llmModel.isEmpty {
                        HStack {
                            Button("Apply") { applyConfig() }
                            if !statusMessage.isEmpty {
                                Text(statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(statusMessage.contains("OK") ? .green : .orange)
                            }
                        }
                    }
                }

                Section("How it works") {
                    Text("When a mode other than \"Dictation\" is active, the transcription is sent to the LLM for post-processing (grammar fixing, email formatting, etc). Domain words from the Dictionary are included as context.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
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
