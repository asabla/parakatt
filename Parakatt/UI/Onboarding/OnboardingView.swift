import SwiftUI
import ParakattCore

/// First-run onboarding view that walks users through setup.
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var currentStep = 0
    var onComplete: () -> Void

    private let steps = ["Welcome", "Modes", "Setup"]

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            Group {
                switch currentStep {
                case 0: welcomeStep
                case 1: modesStep
                case 2: setupStep
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation bar
            HStack {
                // Step indicators
                HStack(spacing: 6) {
                    ForEach(0..<steps.count, id: \.self) { i in
                        Circle()
                            .fill(i == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 8, height: 8)
                    }
                }

                Spacer()

                if currentStep > 0 {
                    Button("Back") {
                        currentStep -= 1
                    }
                    .buttonStyle(.bordered)
                }

                if currentStep < steps.count - 1 {
                    Button("Next") {
                        currentStep += 1
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Welcome to Parakatt")
                .font(.title)
                .fontWeight(.bold)

            Text("Local voice-to-text that lives in your menu bar.\nPress a hotkey, speak, and your words appear wherever you're typing.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            // Hotkey display
            VStack(spacing: 8) {
                Text("Your hotkey")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                HStack(spacing: 4) {
                    KeycapView(label: "Option")
                    Text("+")
                        .foregroundStyle(.secondary)
                    KeycapView(label: "Space")
                }
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("Hold to record, release to transcribe")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Step 2: Modes

    private var modesStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Transcription Modes")
                .font(.title2)
                .fontWeight(.bold)

            Text("Choose how your speech is processed after transcription.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                ModeInfoRow(icon: "waveform", color: .blue,
                           name: "Dictation", desc: "Raw transcription \u{2014} exactly what you said")
                ModeInfoRow(icon: "text.badge.checkmark", color: .green,
                           name: "Clean", desc: "Fix grammar, punctuation, and formatting")
                ModeInfoRow(icon: "envelope.fill", color: .orange,
                           name: "Email", desc: "Structure output as a professional email")
                ModeInfoRow(icon: "chevron.left.forwardslash.chevron.right", color: .purple,
                           name: "Code", desc: "Code-aware \u{2014} preserves identifiers and syntax")
            }
            .padding(.horizontal, 20)

            Text("Dictation works out of the box. Other modes require an LLM\n(Ollama, LM Studio, or OpenAI) \u{2014} configure in Settings later.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(30)
    }

    // MARK: - Step 3: Setup

    private var setupStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("Almost Ready")
                .font(.title2)
                .fontWeight(.bold)

            Text("Parakatt needs a few things to work properly.")
                .font(.body)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                SetupRow(
                    icon: "arrow.down.circle.fill",
                    color: .blue,
                    title: "Download a speech model",
                    subtitle: "~2.5 GB, runs entirely on-device",
                    done: !(appState.needsModelDownload)
                )
                SetupRow(
                    icon: "hand.raised.fill",
                    color: .orange,
                    title: "Accessibility permission",
                    subtitle: "Required to insert text into other apps",
                    done: AXIsProcessTrusted()
                )
                SetupRow(
                    icon: "mic.fill",
                    color: .green,
                    title: "Microphone permission",
                    subtitle: "Granted automatically when you first record",
                    done: true
                )
            }
            .padding(16)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("Click \"Get Started\" to open Settings where you can\ndownload a model and start transcribing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(30)
    }
}

// MARK: - Helper Views

private struct KeycapView: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(.callout, design: .rounded, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
            )
            .shadow(color: .black.opacity(0.1), radius: 1, y: 1)
    }
}

private struct ModeInfoRow: View {
    let icon: String
    let color: Color
    let name: String
    let desc: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(.body, weight: .medium))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SetupRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String
    let done: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, weight: .medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
