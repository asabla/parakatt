import Cocoa
import Combine
import SwiftUI

/// A small floating overlay shown while recording or processing.
struct RecordingOverlayView: View {
    let isRecording: Bool
    let isProcessing: Bool

    var body: some View {
        VStack(spacing: 8) {
            if isRecording {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                Text("Recording...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isProcessing {
                ProgressView()
                    .controlSize(.small)
                Text("Processing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
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
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isProcessing in
                guard let self else { return }
                if isRecording || isProcessing {
                    self.showOverlay(isRecording: isRecording, isProcessing: isProcessing)
                } else {
                    self.hideOverlay()
                }
            }
            .store(in: &cancellables)
    }

    private func showOverlay(isRecording: Bool, isProcessing: Bool) {
        if panel == nil {
            createPanel(isRecording: isRecording, isProcessing: isProcessing)
        } else {
            // Update the existing view
            hostingView?.rootView = RecordingOverlayView(
                isRecording: isRecording,
                isProcessing: isProcessing
            )
        }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    private func hideOverlay() {
        guard isVisible else { return }
        panel?.orderOut(nil)
        isVisible = false
    }

    private func createPanel(isRecording: Bool, isProcessing: Bool) {
        let view = RecordingOverlayView(isRecording: isRecording, isProcessing: isProcessing)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 140, height: 80)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 80),
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
            let x = screenFrame.midX - 70
            let y = screenFrame.maxY - 100
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        self.hostingView = hosting
    }
}
