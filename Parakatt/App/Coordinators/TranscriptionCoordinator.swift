import Foundation
import os.log
import ParakattCore

private let transcriptionSignpostLog = OSLog(subsystem: "com.parakatt.app", category: .pointsOfInterest)

/// Runs one-off transcription jobs and reports results back to AppState.
@MainActor
final class TranscriptionCoordinator {
    func processSingleShot(
        samples: [Float],
        sampleRate: UInt32,
        activeMode: String,
        llmProvider: String,
        bridge: CoreBridge?,
        context: AppContextInfo?,
        effectiveMode: String,
        onMissingEngine: @escaping () -> Void,
        onSuccess: @escaping (TranscriptionResult, Float) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        let maxAmp = samples.map { abs($0) }.max() ?? 0
        NSLog("[Parakatt] Processing %d samples (%.1fs), maxAmp=%.4f, mode=%@, llm=%@",
              samples.count, Double(samples.count) / Double(sampleRate), maxAmp, activeMode, llmProvider.isEmpty ? "none" : llmProvider)

        guard let bridge else {
            onMissingEngine()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let signpostID = OSSignpostID(log: transcriptionSignpostLog)
            os_signpost(.begin, log: transcriptionSignpostLog, name: "Transcribe", signpostID: signpostID, "samples: %d", samples.count)
            defer { os_signpost(.end, log: transcriptionSignpostLog, name: "Transcribe", signpostID: signpostID) }

            do {
                let result = try bridge.transcribe(
                    audioSamples: samples,
                    sampleRate: sampleRate,
                    mode: effectiveMode,
                    context: context
                )

                DispatchQueue.main.async {
                    onSuccess(result, maxAmp)
                }
            } catch {
                DispatchQueue.main.async {
                    onFailure(error.localizedDescription)
                }
            }
        }
    }
}
