import Foundation
import ParakattCore

/// STT model load + download state.
///
/// Skeleton for now — AppState still owns model state. The follow-up
/// PR migrates: isModelLoaded, activeModelId, needsModelDownload,
/// isDownloading, downloadProgress, modelLoadProgress, plus the
/// pollDownloadProgress() loop and model-load lifecycle.
@MainActor
final class ModelCoordinator: ObservableObject {
}
