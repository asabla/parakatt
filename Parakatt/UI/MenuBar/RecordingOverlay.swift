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
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .fill(.red.opacity(0.4))
                    .frame(width: 20, height: 20)
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

    /// Tracks whether the glow entrance effect is active.
    @State private var showEntranceGlow = false
    /// Tracks the entrance animation state.
    @State private var isAppeared = false

    private var hasText: Bool {
        if let text = liveText, !text.isEmpty { return true }
        return false
    }

    private var hasWarning: Bool {
        silenceDetected || clippingDetected
    }

    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Red accent bar along the top edge
            if isRecording {
                LinearGradient(
                    colors: [.red.opacity(0.9), .orange.opacity(0.7)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 3)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 14,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 14
                    )
                )
            }

            if isRecording {
                // Header bar — larger sizing for visibility
                HStack(spacing: 10) {
                    RecordingDot()

                    AudioLevelBarsView(level: audioLevel, tint: .red.opacity(0.8))

                    Text("Recording")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Text("Release to stop")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                // Expanded content — live text or warnings
                if hasText || hasWarning {
                    Divider()
                        .padding(.horizontal, 12)
                        .opacity(0.5)

                    Group {
                        if let text = liveText, !text.isEmpty {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    Text(text)
                                        .font(.system(.body, design: .rounded))
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id("liveText")
                                }
                                .onChange(of: text) { _, _ in
                                    proxy.scrollTo("liveText", anchor: .bottom)
                                }
                                .onAppear {
                                    proxy.scrollTo("liveText", anchor: .bottom)
                                }
                            }
                            .frame(maxHeight: 160)
                        } else if silenceDetected {
                            Label("No audio detected — check your microphone", systemImage: "mic.slash")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        } else if clippingDetected {
                            Label("Audio clipping — move further from mic", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                }

            } else if isProcessing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing...")
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        // Normal shadow + entrance glow
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .shadow(color: .red.opacity(showEntranceGlow ? 0.5 : 0), radius: 20, y: 0)
        // Entrance animation: scale up + fade in
        .scaleEffect(isAppeared ? 1.0 : 0.75)
        .opacity(isAppeared ? 1.0 : 0.0)
        .onAppear {
            if reduceMotion {
                isAppeared = true
                return
            }
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                isAppeared = true
            }
            if isRecording {
                showEntranceGlow = true
                withAnimation(.easeOut(duration: 1.5)) {
                    showEntranceGlow = false
                }
            }
        }
        .onChange(of: isRecording) { _, recording in
            guard recording, !reduceMotion else { return }
            showEntranceGlow = true
            withAnimation(.easeOut(duration: 1.5)) {
                showEntranceGlow = false
            }
        }
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
        panel?.alphaValue = 1.0
        panel?.orderFrontRegardless()
        isVisible = true
    }

    private func hideOverlay() {
        guard isVisible else { return }
        isVisible = false

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel?.orderOut(nil)
            return
        }

        // Fade + scale out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.panel?.alphaValue = 1.0
        })
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
