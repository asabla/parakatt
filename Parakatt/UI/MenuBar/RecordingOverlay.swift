import Cocoa
import Combine
import SwiftUI

/// Animated equalizer bars driven by audio level.
struct AudioLevelBarsView: View {
    let level: Float
    let tint: Color
    private let barCount = 5
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 1.5
    private let maxHeight: CGFloat = 14
    private let minHeight: CGFloat = 2

    private let multipliers: [Float] = [0.5, 0.8, 1.0, 0.8, 0.5]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                let barLevel = CGFloat(level * multipliers[i])
                let height = minHeight + (maxHeight - minHeight) * barLevel

                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(tint)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maxHeight)
        .animation(
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? nil
                : .easeOut(duration: 0.08),
            value: level
        )
    }
}

/// Pulsing recording dot.
private struct RecordingDot: View {
    @State private var isPulsing = false
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(.red.opacity(0.4))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isPulsing ? 1.0 : 0.5)
                    .opacity(isPulsing ? 0.0 : 0.6)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                    isPulsing = true
                }
            }
    }
}

/// Floating overlay shown during recording with live transcription preview.
struct RecordingOverlayView: View {
    let isRecording: Bool
    let isProcessing: Bool
    let liveText: String?
    let audioLevel: Float
    let silenceDetected: Bool
    let clippingDetected: Bool

    private var hasText: Bool {
        if let text = liveText, !text.isEmpty { return true }
        return false
    }

    private var hasWarning: Bool {
        silenceDetected || clippingDetected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRecording {
                // Header bar — always visible
                HStack(spacing: 8) {
                    RecordingDot()

                    AudioLevelBarsView(level: audioLevel, tint: .red.opacity(0.8))

                    Text("Recording")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("Release to stop")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                // Expanded content — live text or warnings
                if hasText || hasWarning {
                    Divider()
                        .padding(.horizontal, 12)
                        .opacity(0.5)

                    Group {
                        if let text = liveText, !text.isEmpty {
                            ScrollView {
                                Text(text)
                                    .font(.system(.body, design: .rounded))
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 100)
                        } else if silenceDetected {
                            Label("No audio detected — check your microphone", systemImage: "mic.slash")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if clippingDetected {
                            Label("Audio clipping — move further from mic", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

            } else if isProcessing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing...")
                        .font(.system(.callout, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
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
            .combineLatest(appState.$audioClippingDetected)
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nested, clippingDetected in
                let (inner, silenceDetected) = nested
                let (isRecording, isProcessing, liveText, audioLevel) = inner
                let newView = RecordingOverlayView(
                    isRecording: isRecording,
                    isProcessing: isProcessing,
                    liveText: liveText,
                    audioLevel: audioLevel,
                    silenceDetected: silenceDetected,
                    clippingDetected: clippingDetected
                )
                self?.hostingView?.rootView = newView

                // Resize panel to fit content
                if let hosting = self?.hostingView, let panel = self?.panel {
                    let fittingSize = hosting.fittingSize
                    let currentFrame = panel.frame
                    let newFrame = NSRect(
                        x: currentFrame.origin.x,
                        y: currentFrame.origin.y + currentFrame.height - fittingSize.height,
                        width: fittingSize.width,
                        height: fittingSize.height
                    )
                    panel.setFrame(newFrame, display: true, animate: false)
                }
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
        let view = RecordingOverlayView(
            isRecording: false, isProcessing: false, liveText: nil,
            audioLevel: 0, silenceDetected: false, clippingDetected: false
        )
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
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
        panel.hasShadow = false // SwiftUI handles shadow
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true  // Draggable!

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.maxY - size.height - 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        self.hostingView = hosting
    }
}
