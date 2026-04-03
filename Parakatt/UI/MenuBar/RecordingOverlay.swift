import Cocoa
import Combine
import SwiftUI

/// Animated equalizer bars driven by audio level.
struct AudioLevelBarsView: View {
    let level: Float
    private let barCount = 5
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 20
    private let minHeight: CGFloat = 3

    // Per-bar multipliers to create staggered equalizer look
    private let multipliers: [Float] = [0.6, 0.85, 1.0, 0.85, 0.6]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let barLevel = CGFloat(level * multipliers[i])
                let height = minHeight + (maxHeight - minHeight) * barLevel

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(.red)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}

/// Floating overlay shown during recording with live transcription preview.
struct RecordingOverlayView: View {
    let isRecording: Bool
    let isProcessing: Bool
    let liveText: String?
    let audioLevel: Float
    let silenceDetected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isRecording {
                HStack(spacing: 8) {
                    AudioLevelBarsView(level: audioLevel)
                    Text("Recording")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                if let text = liveText, !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .font(.system(.body, design: .rounded))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if silenceDetected {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.slash")
                            .font(.caption)
                        Text("No audio detected — check your microphone")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                } else {
                    Text("Listening...")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            } else if isProcessing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(width: 420, height: 160)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
    }
}

/// Manages the floating overlay window lifecycle.
class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingOverlayView>?
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState
    private var isVisible = false

    init(appState: AppState) {
        self.appState = appState
        observeState()
    }

    private func observeState() {
        appState.$isRecording
            .combineLatest(appState.$isProcessing)
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] shouldShow in
                if shouldShow {
                    self?.showOverlay()
                } else {
                    self?.hideOverlay()
                }
            }
            .store(in: &cancellables)

        appState.$isRecording
            .combineLatest(appState.$isProcessing, appState.$liveTranscription, appState.$currentAudioLevel)
            .combineLatest(appState.$silenceDetected)
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] combined, silenceDetected in
                let (isRecording, isProcessing, liveText, audioLevel) = combined
                self?.hostingView?.rootView = RecordingOverlayView(
                    isRecording: isRecording,
                    isProcessing: isProcessing,
                    liveText: liveText,
                    audioLevel: audioLevel,
                    silenceDetected: silenceDetected
                )
            }
            .store(in: &cancellables)
    }

    private func showOverlay() {
        guard !isVisible else { return }
        if panel == nil { createPanel() }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    private func hideOverlay() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        isVisible = false
    }

    private func createPanel() {
        let view = RecordingOverlayView(isRecording: false, isProcessing: false, liveText: nil, audioLevel: 0, silenceDetected: false)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 160)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 210
            let y = screenFrame.midY + 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        self.hostingView = hosting
    }
}
