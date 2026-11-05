import Foundation

/// Shared between capture callbacks and main-actor recording controls.
/// The buffer lock permits atomic admission/drain operations across several accesses.
// Every mutable property is backed by Locked.
final class RecordingAudioState: @unchecked Sendable {
    let lock = NSLock()
    @Locked var buffer = FloatQueue()
    @Locked var journal: CaptureJournal?
    @Locked var preview: LivePreviewService?
    @Locked var previewActive = false
    @Locked var silentCallbacks = 0
    @Locked var sampleCount = 0
    @Locked var lastMeterUpdate: CFAbsoluteTime = 0
    @Locked var longRecordingWarned = false
    @Locked var smoothedLevel: Float = 0
}
