import Foundation

private struct CaptureSignal: Sendable {
    var samples = 0
    var squares: Double = 0
    var peak: Float = 0
    mutating func append(_ audio: [Float]) {
        samples += audio.count
        for value in audio {
            squares += Double(value) * Double(value)
            peak = max(peak, abs(value))
        }
    }
}

/// Opt-in check for a selected test app. Does not capture the microphone or other apps.
@available(macOS 14.2, *)
@MainActor
func systemAudioCaptureSmoke(processID: pid_t) async throws -> [String: Any] {
    let capture = SystemAudioCaptureService()
    let signal = Locked(wrappedValue: CaptureSignal())
    capture.onAudioSamples = { signal.wrappedValue.append($0) }
    try capture.startCapture(processID: processID)
    defer { capture.stopCapture() }
    try await Task.sleep(nanoseconds: 15_000_000_000)
    capture.stopCapture()
    let measured = signal.wrappedValue
    guard measured.samples > 1600, measured.peak > 0.001 else {
        throw NSError(domain: "ParakattCaptureSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected test app delivered \(measured.samples) samples with peak \(measured.peak). Check System Audio Recording permission and test playback."])
    }
    return ["samples": measured.samples, "peak": measured.peak, "rms": sqrt(measured.squares / Double(measured.samples)), "source": "selected test app"]
}
