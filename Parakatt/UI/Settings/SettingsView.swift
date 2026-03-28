import SwiftUI

/// Main settings window with tabs.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsView()
                .tabItem {
                    Label("Models", systemImage: "cpu")
                }

            DictionarySettingsView()
                .tabItem {
                    Label("Dictionary", systemImage: "character.book.closed")
                }

            ModeSettingsView()
                .tabItem {
                    Label("Modes", systemImage: "list.bullet")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Option + Space (hold to record)")
                    .foregroundStyle(.secondary)
                Text("Hotkey customization coming soon")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("Text Insertion") {
                Text("Automatically pastes transcribed text into the focused app")
                    .foregroundStyle(.secondary)
            }

            Section("Active Mode") {
                Picker("Mode", selection: $appState.activeMode) {
                    Text("Dictation").tag("dictation")
                    Text("Clean").tag("clean")
                    Text("Email").tag("email")
                    Text("Code").tag("code")
                }
            }
        }
        .padding()
    }
}

// MARK: - Model Settings (placeholder)

struct ModelSettingsView: View {
    var body: some View {
        VStack {
            Text("Model Management")
                .font(.headline)
            Text("Download and select STT models here.")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Coming in Phase 2")
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

// MARK: - Dictionary Settings (placeholder)

struct DictionarySettingsView: View {
    var body: some View {
        VStack {
            Text("Custom Dictionary")
                .font(.headline)
            Text("Add domain-specific word replacements.")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Coming in Phase 3")
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}

// MARK: - Mode Settings (placeholder)

struct ModeSettingsView: View {
    var body: some View {
        VStack {
            Text("Mode Configuration")
                .font(.headline)
            Text("Configure built-in modes and create custom ones.")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Coming in Phase 3")
                .foregroundStyle(.tertiary)
        }
        .padding()
    }
}
