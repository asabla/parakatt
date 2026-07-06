import Foundation

/// Diagnostic helpers that do not depend on AppState's live recording buffer.
@MainActor
final class DiagnosticsCoordinator {
    @available(macOS 14.2, *)
    func runSystemAudioDiagnostic(environment: PlatformEnvironment) {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        NSLog("[Parakatt] === SYSTEM AUDIO DIAGNOSTIC START (macOS %d.%d.%d) ===",
              osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion)

        let testCapture = environment.makeSystemAudioCapture()
        var collectedSamples: [Float] = []
        let sampleLock = NSLock()

        testCapture.onAudioSamples = { samples in
            sampleLock.lock()
            collectedSamples.append(contentsOf: samples)
            sampleLock.unlock()
        }

        do {
            try testCapture.startCapture(processID: nil)
            NSLog("[Parakatt] SYSDIAG: Capturing all system audio for 3 seconds...")
        } catch {
            NSLog("[Parakatt] SYSDIAG: ❌ Failed to start capture: %@", error.localizedDescription)
            NSLog("[Parakatt] === SYSTEM AUDIO DIAGNOSTIC END ===")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            testCapture.stopCapture()

            sampleLock.lock()
            let samples = collectedSamples
            sampleLock.unlock()

            let maxAmp = samples.map { abs($0) }.max() ?? 0
            let rms = samples.isEmpty ? 0 : sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))

            NSLog("[Parakatt] SYSDIAG: %d samples (%.1fs), max=%.6f, rms=%.6f",
                  samples.count, Double(samples.count) / 16000.0, maxAmp, rms)

            if samples.isEmpty {
                NSLog("[Parakatt] SYSDIAG: ❌ NO SAMPLES — system audio callback never fired")
                NSLog("[Parakatt] SYSDIAG: Check System Settings > Privacy & Security > Screen & System Audio Recording")
            } else if maxAmp > 0.001 {
                NSLog("[Parakatt] SYSDIAG: ✅ System audio has signal")
            } else {
                NSLog("[Parakatt] SYSDIAG: ⚠️ Samples received but SILENT (max=%.6f) — is audio playing from another app?", maxAmp)
            }

            NSLog("[Parakatt] === SYSTEM AUDIO DIAGNOSTIC END ===")
        }
    }
}
