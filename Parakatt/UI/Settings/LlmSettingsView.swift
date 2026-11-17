import SwiftUI

enum LlmProviderPresentation {
    static let options: [(id: String, title: String)] = [
        ("", "None"), ("ollama", "Ollama"), ("lmstudio", "LM Studio"),
        ("chatgpt", "ChatGPT plan"), ("openai", "OpenAI API"), ("anthropic", "Anthropic"),
    ]
    static func isLocal(_ id: String) -> Bool { ["ollama", "lmstudio"].contains(id) }
    static func needsApiKey(_ id: String) -> Bool { ["openai", "anthropic"].contains(id) }
    static func supportsAdvanced(_ id: String) -> Bool { !id.isEmpty && id != "chatgpt" }
}

struct LlmSettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var chatGpt: ChatGptCoordinator
    @State private var availableModels: [String] = []
    @State private var isFetching = false
    @State private var isTesting = false
    @State private var summary = ""
    @State private var details = ""
    @State private var succeeded = false
    @State private var showDetails = false
    @State private var revision = 0

    init(account: ChatGptCoordinator? = nil) {
        _chatGpt = StateObject(wrappedValue: account ?? ChatGptCoordinator())
    }

    private var isChatGpt: Bool { appState.llmProvider == "chatgpt" }
    private var busy: Bool { isFetching || isTesting || (isChatGpt && chatGpt.busy) }
    private var selectedAccountReady: Bool {
        chatGpt.accounts.contains { $0.id == chatGpt.selectedAccount && $0.signedIn && $0.planEnabled && !$0.paused }
    }
    private var canApply: Bool {
        guard !appState.llmProvider.isEmpty, !appState.llmModel.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isChatGpt { return selectedAccountReady && chatGpt.models.contains { $0.slug == appState.llmModel } }
        return !LlmProviderPresentation.needsApiKey(appState.llmProvider) || !appState.llmApiKey.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI text processing").font(.title2.weight(.semibold))
                LlmSettingsSection(title: "Provider", icon: "network") {
                    Picker("Provider", selection: Binding(get: { appState.llmProvider }, set: { appState.selectLlmProvider($0) })) {
                        ForEach(LlmProviderPresentation.options, id: \.id) { provider in
                            Text(provider.title).tag(provider.id)
                        }
                    }
                    .disabled(busy)
                    Text(appState.llmProvider.isEmpty ? "No AI requests. Saved provider configurations and credentials are kept." : "Configure the connection and model below, then apply. Speech recognition stays on this device.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !appState.llmProvider.isEmpty {
                    if isChatGpt {
                        ChatGptSettingsView(account: chatGpt, disabled: isTesting)
                    } else {
                        connectionSection
                    }
                    modelSection
                }

                TextProcessingSettingsView()
                    .disabled(busy)

                if LlmProviderPresentation.supportsAdvanced(appState.llmProvider) {
                    DisclosureGroup("Advanced") {
                        GenerationPreferencesView(appState: appState)
                            .id(appState.llmProvider)
                            .padding(.top, 8)
                    }
                }
            }
            .padding()
        }
        .onChange(of: appState.llmProvider) { _, _ in
            availableModels = []
            configurationChanged()
            isFetching = false
        }
        .onChange(of: appState.llmModel) { _, _ in configurationChanged() }
        .onChange(of: appState.llmBaseUrl) { _, _ in availableModels = []; configurationChanged(); isFetching = false }
        .onChange(of: appState.llmApiKey) { _, _ in availableModels = []; configurationChanged(); isFetching = false }
        .onChange(of: chatGpt.selectedAccount) { _, _ in configurationChanged() }
    }

    private var connectionSection: some View {
        LlmSettingsSection(title: "Connection", icon: "link") {
            if LlmProviderPresentation.isLocal(appState.llmProvider) {
                LabeledContent("Server address") {
                    TextField("http://localhost:11434", text: $appState.settings.llmBaseUrl)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Transcript text is sent to this server. Use a server on your Mac to keep processing local.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("API key") {
                    SecureField("Provider API key", text: $appState.settings.llmApiKey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Stored in Keychain for this provider. Text processing uses your API account’s billing.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = appState.settings.credentialError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .disabled(busy)
    }

    private var modelSection: some View {
        LlmSettingsSection(title: "Model", icon: "cpu") {
            HStack(spacing: 8) {
                Picker("Model", selection: $appState.settings.llmModel) {
                    Text("Select a model…").tag("")
                    if !appState.llmModel.isEmpty && !modelIDs.contains(appState.llmModel) {
                        Text(appState.llmModel + " (saved)").tag(appState.llmModel)
                    }
                    if isChatGpt {
                        ForEach(chatGpt.models, id: \.slug) { model in Text(model.displayName).tag(model.slug) }
                    } else {
                        ForEach(availableModels, id: \.self) { model in Text(model).tag(model) }
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(busy || (isChatGpt && !selectedAccountReady))
                Button(action: fetchModels) { Image(systemName: "arrow.clockwise") }
                    .help("Refresh available models")
                    .accessibilityLabel("Refresh available models")
                    .disabled(busy || (isChatGpt && !selectedAccountReady))
            }
            if !isChatGpt {
                DisclosureGroup("Enter model ID manually") {
                    TextField("Model ID", text: $appState.settings.llmModel).textFieldStyle(.roundedBorder)
                }
                .font(.caption)
                .disabled(busy)
            }
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(isTesting ? "Testing connection…" : "Loading models…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Test connection", action: testConnection)
                    .help("Apply these settings and send a short synthetic text request. No recording is sent; remote provider usage may apply.")
                    .disabled(busy || !canApply)
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !canApply)
            }
            if !appState.appliedLlmProvider.isEmpty {
                Label("In use: \(appState.appliedLlmModel)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Not applied").font(.caption).foregroundStyle(.secondary)
            }
            if !summary.isEmpty {
                Label(summary, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(succeeded ? .green : .orange)
            }
            if !details.isEmpty {
                DisclosureGroup("Details", isExpanded: $showDetails) {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private var modelIDs: [String] { isChatGpt ? chatGpt.models.map(\.slug) : availableModels }

    private func configurationChanged() {
        revision += 1
        summary = ""
        details = ""
        showDetails = false
    }

    private func fetchModels() {
        if isChatGpt { chatGpt.fetchModels(); return }
        configurationChanged()
        let requestRevision = revision
        isFetching = true
        appState.fetchLlmModels { models in
            guard requestRevision == revision else { return }
            isFetching = false
            availableModels = models
            if models.isEmpty {
                summary = "No models found. Check the connection settings."
                succeeded = false
            }
        }
    }

    @discardableResult
    private func apply() -> Bool {
        do {
            if isChatGpt { try appState.setChatGptAccount(chatGpt.selectedAccount) }
            succeeded = appState.configureLlm()
            summary = succeeded ? "Configuration applied." : "Couldn’t apply the configuration."
            details = succeeded ? "" : (appState.errorMessage ?? "Check the connection and model settings.")
            showDetails = false
            return succeeded
        } catch {
            succeeded = false
            summary = "Couldn’t apply the configuration."
            details = String(describing: error)
            return false
        }
    }

    private func testConnection() {
        guard apply() else { return }
        let requestRevision = revision
        isTesting = true
        summary = ""
        appState.testLlmPipeline { result in
            guard requestRevision == revision else { isTesting = false; return }
            isTesting = false
            succeeded = ChatGptSettingsPresentation.testPassed(result)
            summary = succeeded ? "Connection successful." : "Connection test failed."
            details = result
            if isChatGpt { chatGpt.reload(preferredAccount: chatGpt.selectedAccount) }
        }
    }
}
