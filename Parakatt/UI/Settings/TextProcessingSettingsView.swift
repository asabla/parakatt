import ParakattCore
import SwiftUI

enum TextProcessingPresentation {
    static let basicModes = ["dictation", "punctuation", "clean"]
    static func isReservedName(_ name: String) -> Bool {
        (basicModes + ["email", "code", "off", "grammar + punctuation"]).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func selectionTitle(_ mode: String) -> String {
        (basicModes + ["email", "code"]).contains(mode.lowercased()) ? title(mode) : "Custom: \(title(mode))"
    }
    static func title(_ mode: String) -> String {
        switch mode.lowercased() {
        case "dictation": return "Off"
        case "punctuation": return "Punctuation"
        case "clean": return "Grammar + punctuation"
        default: return mode.capitalized
        }
    }
    static func description(_ mode: String) -> String {
        switch mode.lowercased() {
        case "dictation": return "Transcription and dictionary corrections only. No AI request."
        case "punctuation": return "Adjust punctuation, capitalization, and spacing without changing your words."
        case "clean": return "Correct grammar, spelling, and punctuation while preserving your meaning."
        case "email": return "Format your words as an email using the configured provider."
        case "code": return "Use code-aware processing with the configured provider."
        default: return "Use the instructions defined for this custom mode."
        }
    }
}

struct LlmSettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct TextProcessingSettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var modes: [ModeConfig] = []
    var disableWithoutProvider = true

    var body: some View {
        LlmSettingsSection(title: "Text cleanup", icon: "text.badge.checkmark") {
            Picker("Text cleanup", selection: Binding(get: { appState.activeMode }, set: { appState.activeMode = $0 })) {
                ForEach(TextProcessingPresentation.basicModes, id: \.self) { mode in
                    Text(TextProcessingPresentation.title(mode)).tag(mode)
                }
                Divider()
                ForEach(specializedModes, id: \.name) { mode in
                    Text(TextProcessingPresentation.selectionTitle(mode.name)).tag(mode.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(disableWithoutProvider && appState.llmProvider.isEmpty)
            Text(TextProcessingPresentation.description(appState.activeMode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if appState.llmProvider.isEmpty {
                Text("Select and apply a provider to enable AI text cleanup. Without one, all modes keep the recognized text and dictionary corrections.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("When AI processing is enabled, up to 120 preceding words from the same recording and speaker provide context automatically. Remote providers receive this text. Changes apply to the next recording; failed processing keeps your original text.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.appliedLlmProvider.isEmpty {
                    Label("Apply the provider configuration before using AI cleanup.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { modes = appState.listModes() }
    }

    private var specializedModes: [ModeConfig] {
        var saved = modes.filter { !TextProcessingPresentation.basicModes.contains($0.name) }
        if !TextProcessingPresentation.basicModes.contains(appState.activeMode) && !saved.contains(where: { $0.name == appState.activeMode }) {
            saved.append(ModeConfig(name: appState.activeMode, sttProvider: nil, llmProvider: nil, systemPrompt: nil, dictionaryEnabled: true))
        }
        return saved
    }
}
