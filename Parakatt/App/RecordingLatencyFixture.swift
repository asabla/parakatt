import AppKit
import CryptoKit
import ParakattCore

/// Explicit app-process replay. It never starts capture, pastes, or contacts an LLM.
@MainActor
func runRecordingLatencyFixtureIfRequested() -> Bool {
    let env = ProcessInfo.processInfo.environment
    guard let output = env["PARAKATT_STOP_LATENCY"] else { return false }
    Task { @MainActor in
        var report: [String: Any] = ["completed": false, "physical_capture": false, "paste_tested": false]
        var rows: [[String: Any]] = []
        do {
            guard let root = env["PARAKATT_DATA_ROOT"], let models = env["PARAKATT_FIXTURE_MODELS"],
                  let manifest = env["PARAKATT_LATENCY_FIXTURES"],
                  let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifest))) as? [[String: Any]] else {
                throw LatencyFixtureError.invalidInput
            }
            let trials = Int(env["PARAKATT_LATENCY_TRIALS"] ?? "5") ?? 5
            guard (1...20).contains(trials), !fixtures.isEmpty else { throw LatencyFixtureError.invalidInput }
            let bridge = try CoreBridge(modelsDir: models, configDir: root, activeMode: "dictation")
            let cpu = env["PARAKATT_LATENCY_BACKEND"] == "cpu"
            try bridge.setSpeechSettings(SpeechSettings(previewModel: nil, language: .automatic, backend: cpu ? .cpu : .automatic, cpuThreads: 0))
            try bridge.setStreamingPreviewEnabled(true)
            try bridge.loadModel("parakeet-tdt-0.6b-v3")
            let backend = bridge.speechRuntimeStatus().actualBackend == .webGpu ? "webgpu" : "cpu"
            guard backend == (cpu ? "cpu" : "webgpu") else { throw LatencyFixtureError.backend }
            let state = AppState(bridge: bridge)
            for fixture in fixtures {
                guard let path = fixture["path"] as? String, let id = fixture["id"] as? String,
                      let incremental = fixture["incremental"] as? Bool else { throw LatencyFixtureError.invalidInput }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count % 4 == 0 else { throw LatencyFixtureError.invalidInput }
                let samples: [Float] = data.withUnsafeBytes { bytes in
                    stride(from: 0, to: data.count, by: 4).map { offset in
                        Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                    }
                }
                guard (8000...960000).contains(samples.count), samples.allSatisfy({ $0.isFinite }) else { throw LatencyFixtureError.invalidInput }
                var expected: String?
                // Warm each app path and shape before retaining measurements.
                for trial in -1..<trials {
                    for preview in [false, true] {
                        try state.prepareRecordingLatencyFixture(samples: samples, preview: preview, incremental: incremental)
                        // Start the request before stop; record whether the app still sees it in flight.
                        try await Task.sleep(nanoseconds: 10_000_000)
                        let previewInFlight = state.latencyFixturePreviewInFlight
                        let start = ProcessInfo.processInfo.systemUptime
                        state.stopRecording()
                        let control = ProcessInfo.processInfo.systemUptime - start
                        var drained: Double?
                        var recognized: Double?
                        let deadline = start + 60
                        while state.latencyFixtureDraining || state.isProcessing || state.lastTranscription == nil {
                            let now = ProcessInfo.processInfo.systemUptime
                            guard now < deadline, state.errorMessage == nil else { throw LatencyFixtureError.processing }
                            if drained == nil && !state.latencyFixtureDraining { drained = now - start }
                            if recognized == nil && state.lastTranscription != nil { recognized = now - start }
                            try await Task.sleep(nanoseconds: 1_000_000)
                        }
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        guard let text = state.lastTranscription, !text.isEmpty else { throw LatencyFixtureError.noSpeech }
                        if let expected, text != expected { throw LatencyFixtureError.changedText }
                        expected = text
                        if trial >= 0 { rows.append(["fixture": id, "trial": trial, "preview": preview,
                                     "preview_in_flight_at_stop": previewInFlight, "incremental": incremental,
                                     "audio_seconds": Double(samples.count) / 16000, "control_return_seconds": control,
                                     "drain_observed_seconds": drained ?? elapsed,
                                     "recognized_observed_seconds": recognized ?? elapsed,
                                     "stop_to_final_state_seconds": elapsed,
                                     "text_sha256": SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()]) }
                        while state.latencyFixturePreviewInFlight {
                            guard ProcessInfo.processInfo.systemUptime < deadline else { throw LatencyFixtureError.processing }
                            try await Task.sleep(nanoseconds: 1_000_000)
                        }
                    }
                }
            }
            report.merge(["completed": true, "actual_backend": backend,
                          "os": ProcessInfo.processInfo.operatingSystemVersionString,
                          "observations": rows, "capture_drain_seconds": 0.6,
                          "limitations": "Actual AppState stop, queue, Rust, history, and published-state path with preloaded public audio. No device capture, paste, LLM, or compositor timing. Warm model and shapes; observations use 1 ms polling."]) { _, new in new }
        } catch { report["error"] = String(describing: error) }
        report["observations"] = rows
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        NSApp.terminate(nil)
    }
    return true
}

private enum LatencyFixtureError: Error {
    case invalidInput, backend, noSpeech, processing, changedText
}
