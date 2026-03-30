import Cocoa
import Combine
import SwiftUI

/// Floating overlay shown during recording with live transcription preview.
struct RecordingOverlayView: View {
    let isRecording: Bool
    let isProcessing: Bool
    let liveText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
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
            .combineLatest(appState.$isProcessing, appState.$liveTranscription)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isProcessing, liveText in
                self?.hostingView?.rootView = RecordingOverlayView(
                    isRecording: isRecording,
                    isProcessing: isProcessing,
                    liveText: liveText
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
        let view = RecordingOverlayView(isRecording: false, isProcessing: false, liveText: nil)
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
