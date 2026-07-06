import Foundation
import os.log
import ParakattCore

private let modelSignpostLog = OSLog(subsystem: "com.parakatt.app", category: .pointsOfInterest)

/// STT model load + download state.
@MainActor
final class ModelCoordinator: ObservableObject {
    /// True when the offline transcription model is loaded and ready.
    @Published var isModelLoaded = false
    /// The currently active offline STT model ID.
    @Published var activeModelId: String?
    /// True when first launch or deletion leaves no downloaded offline model.
    @Published var needsModelDownload = false
    /// True while the Rust download worker is fetching model files.
    @Published var isDownloading = false
    /// Latest download progress snapshot from the Rust core.
    @Published var downloadProgress: ParakattCore.DownloadProgress?

    var onErrorMessage: ((String?) -> Void)?

    private var downloadPollTimer: Timer?

    func loadDownloadedModels(bridge: CoreBridge?) {
        let models = bridge?.listModels() ?? []

        // Find the offline commit-path model (parakeet-*) and the
        // optional streaming preview model (nemotron-*). Both can be
        // downloaded; we register both.
        let offlineModel = models.first(where: { $0.downloaded && $0.id.hasPrefix("parakeet-") })
        let streamingModel = models.first(where: { $0.downloaded && $0.id.hasPrefix("nemotron-") })

        if let model = offlineModel {
            // Load the downloaded model on a background thread (Metal/GPU init is heavy).
            let modelId = model.id
            let streamingId = streamingModel?.id
            DispatchQueue.global(qos: .userInitiated).async { [weak self, bridge] in
                guard let self, let bridge else { return }

                NSLog("[Parakatt] Loading offline model '%@' in background...", modelId)
                do {
                    try bridge.loadModel(modelId)
                    DispatchQueue.main.async {
                        self.isModelLoaded = true
                        self.activeModelId = modelId
                        NSLog("[Parakatt] Offline model loaded — ready to transcribe")
                    }
                } catch {
                    DispatchQueue.main.async {
                        NSLog("[Parakatt] Offline model load failed: \(error) — transcription won't work until a model is loaded")
                    }
                }

                // Optionally register the streaming preview model alongside it.
                // Failure here is non-fatal — the commit path still works.
                if let streamingId {
                    do {
                        try bridge.loadModel(streamingId)
                        NSLog("[Parakatt] Streaming model registered: %@", streamingId)
                    } catch {
                        NSLog("[Parakatt] Streaming model register failed: %@", error.localizedDescription)
                    }
                }
            }
        } else {
            NSLog("[Parakatt] No offline model downloaded — user needs to download one")
            needsModelDownload = true
        }
    }

    func loadModel(_ modelId: String, bridge: CoreBridge?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, bridge] in
            let signpostID = OSSignpostID(log: modelSignpostLog)
            os_signpost(.begin, log: modelSignpostLog, name: "LoadModel", signpostID: signpostID, "%{public}s", modelId)
            defer { os_signpost(.end, log: modelSignpostLog, name: "LoadModel", signpostID: signpostID) }

            guard let self else { return }
            do {
                try bridge?.loadModel(modelId)
                DispatchQueue.main.async {
                    self.isModelLoaded = true
                    self.activeModelId = modelId
                    self.onErrorMessage?(nil)
                    NSLog("[Parakatt] Loaded model: \(modelId)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.onErrorMessage?("Failed to load model: \(error.localizedDescription)")
                    NSLog("[Parakatt] Model load failed: \(error)")
                }
            }
        }
    }

    func listModels(bridge: CoreBridge?) -> [ParakattCore.ModelInfo] {
        bridge?.listModels() ?? []
    }

    func startDownload(_ modelId: String, bridge: CoreBridge?) {
        do {
            try bridge?.startDownload(modelId)
            isDownloading = true
            startDownloadPolling(bridge: bridge)
            NSLog("[Parakatt] Started download: %@", modelId)
        } catch {
            onErrorMessage?("Failed to start download: \(error.localizedDescription)")
            NSLog("[Parakatt] Download start failed: %@", error.localizedDescription)
        }
    }

    func cancelDownload(bridge: CoreBridge?) {
        bridge?.cancelDownload()
        NSLog("[Parakatt] Download cancelled")
    }

    func deleteModel(_ modelId: String, bridge: CoreBridge?) {
        do {
            try bridge?.deleteModel(modelId)
            // If the deleted model was loaded, reset state.
            if activeModelId == modelId {
                isModelLoaded = false
                activeModelId = nil
                needsModelDownload = listModels(bridge: bridge).first(where: { $0.downloaded }) == nil
            }
            NSLog("[Parakatt] Deleted model: %@", modelId)
        } catch {
            onErrorMessage?("Failed to delete model: \(error.localizedDescription)")
            NSLog("[Parakatt] Delete model failed: %@", error.localizedDescription)
        }
    }

    func shutdown() {
        stopDownloadPolling()
    }

    private func startDownloadPolling(bridge: CoreBridge?) {
        downloadPollTimer?.invalidate()
        downloadPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self, bridge] _ in
            self?.pollDownloadProgress(bridge: bridge)
        }
    }

    private func stopDownloadPolling() {
        downloadPollTimer?.invalidate()
        downloadPollTimer = nil
    }

    private func pollDownloadProgress(bridge: CoreBridge?) {
        guard let bridge else { return }

        guard let progress = try? bridge.getDownloadProgress() else { return }
        downloadProgress = progress

        switch progress.state {
        case .completed:
            stopDownloadPolling()
            isDownloading = false
            needsModelDownload = false
            NSLog("[Parakatt] Download completed: %@", progress.modelId)
            // Auto-load the just-downloaded model.
            loadModel(progress.modelId, bridge: bridge)

        case .failed(let message):
            stopDownloadPolling()
            isDownloading = false
            onErrorMessage?("Download failed: \(message)")
            NSLog("[Parakatt] Download failed: %@", message)

        case .cancelled:
            stopDownloadPolling()
            isDownloading = false
            NSLog("[Parakatt] Download cancelled")

        case .idle:
            stopDownloadPolling()
            isDownloading = false

        case .downloading:
            break // keep polling
        }
    }
}
