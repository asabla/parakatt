import Foundation

/// Owns the optional streaming live-preview service and its active/inactive state.
final class LivePreviewCoordinator {
    private var service: LivePreviewService?
    private(set) var isActive = false

    func configure(bridge: CoreBridge, onUpdate: @escaping (String, String, String) -> Void) {
        let preview = LivePreviewService(bridge: bridge)
        preview.onUpdate = onUpdate
        preview.onError = { [weak self] message in
            NSLog("[Parakatt] LivePreview disabled: %@", message)
            self?.isActive = false
        }
        service = preview
    }

    func startIfAvailable() -> Bool {
        guard let service, service.isStreamingAvailable else {
            isActive = false
            return false
        }

        do {
            _ = try service.start()
            isActive = true
            return true
        } catch {
            isActive = false
            NSLog("[Parakatt] Live preview start failed: %@ — falling back to buffered preview", error.localizedDescription)
            return false
        }
    }

    func stop() -> String {
        let finalText = service?.stop() ?? ""
        isActive = false
        return finalText
    }

    func stopIfActive() -> String? {
        guard isActive else { return nil }
        return stop()
    }

    func enqueue(_ samples: [Float]) {
        service?.enqueue(samples)
    }
}
