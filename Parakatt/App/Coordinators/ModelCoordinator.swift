import Foundation
import ParakattCore

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
}
