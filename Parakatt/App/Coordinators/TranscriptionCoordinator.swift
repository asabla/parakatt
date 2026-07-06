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

    func processPttChunk(
        sessionId: String,
        samples: [Float],
        sampleRate: UInt32,
        chunkIndex: UInt32,
        mode: String,
        context: AppContextInfo?,
        bridge: CoreBridge?,
        runLocked: @escaping (@escaping () -> Void) -> Void,
        onAccumulatedText: @escaping (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bridge else { return }

            runLocked {
                do {
                    let result = try bridge.processChunk(
                        sessionId: sessionId,
                        audioSamples: samples,
                        sampleRate: sampleRate,
                        chunkIndex: chunkIndex,
                        mode: mode,
                        context: context
                    )
                    // Pull the running accumulated text on demand instead of
                    // having Rust clone it on every chunk.
                    let acc = (try? bridge.getSessionText(sessionId: sessionId)) ?? ""
                    if let llmErr = result.llmError {
                        NSLog("[Parakatt] PTT chunk %d LLM degraded (raw text used): %@", chunkIndex, llmErr)
                    }
                    DispatchQueue.main.async {
                        onAccumulatedText(acc)
                    }
                    NSLog("[Parakatt] PTT chunk %d: \"%@\"", chunkIndex, result.text)
                } catch {
                    NSLog("[Parakatt] PTT chunk %d failed: %@", chunkIndex, error.localizedDescription)
                }
            }
        }
    }

    func finishPttSession(
        sessionId: String,
        remainingSamples: [Float],
        sampleRate: UInt32,
        chunkIndex: UInt32,
        mode: String,
        context: AppContextInfo?,
        bridge: CoreBridge?,
        runLocked: @escaping (@escaping () -> Void) -> Void,
        onMissingEngine: @escaping () -> Void,
        onSuccess: @escaping (TranscriptionResult) -> Void,
        onFailure: @escaping (String) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let bridge else {
                DispatchQueue.main.async { onMissingEngine() }
                return
            }

            // Wait for any in-flight chunk to complete, then run the tail
            // under the same lock. The final finishSession call stays outside
            // the lock so future chunk edits cannot accidentally block it.
            runLocked {
                if remainingSamples.count >= Int(sampleRate / 10) {
                    do {
                        let result = try bridge.processChunk(
                            sessionId: sessionId,
                            audioSamples: remainingSamples,
                            sampleRate: sampleRate,
                            chunkIndex: chunkIndex,
                            mode: mode,
                            context: context
                        )
                        NSLog("[Parakatt] PTT final chunk %d: \"%@\"", chunkIndex, result.text)
                    } catch {
                        NSLog("[Parakatt] PTT final chunk failed: %@", error.localizedDescription)
                    }
                } else {
                    NSLog("[Parakatt] PTT tail too short (%.1fs), skipping",
                          Double(remainingSamples.count) / Double(sampleRate))
                }
            }

            do {
                let result = try bridge.finishSession(
                    sessionId: sessionId,
                    mode: mode,
                    context: context,
                    source: "push_to_talk"
                )
                DispatchQueue.main.async {
                    onSuccess(result)
                }
            } catch {
                bridge.cancelSession(sessionId: sessionId)
                DispatchQueue.main.async {
                    onFailure(error.localizedDescription)
                }
            }
        }
    }

    func processBufferedPreview(
        sessionId: String,
        samples: [Float],
        sampleRate: UInt32,
        bridge: CoreBridge,
        onSuccess: @escaping (StreamingChunkResult) -> Void,
        onComplete: @escaping () -> Void
    ) {
        DispatchQueue.global(qos: .userInteractive).async {
            defer {
                DispatchQueue.main.async {
                    onComplete()
                }
            }

            do {
                let result = try bridge.bufferedPreviewUpdate(
                    sessionId: sessionId,
                    audioSamples: samples,
                    sampleRate: sampleRate
                )
                DispatchQueue.main.async {
                    onSuccess(result)
                }
            } catch {
                // Silently ignore streaming errors.
            }
        }
    }
}
