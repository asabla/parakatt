import AppKit
import AVFoundation
import Foundation
import ParakattCore

/// Explicit packaged-app startup check. It uses isolated data and requests no permissions.
@MainActor
func runMaintenanceSmokeIfRequested() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard environment["PARAKATT_SMOKE_TEST"] == "1", let root = environment["PARAKATT_DATA_ROOT"] else { return false }
    if let source = environment["PARAKATT_SMOKE_PLAYBACK"] {
        Task { @MainActor in
            var result: [String: Any] = ["started": true]
            do {
                let data = URL(fileURLWithPath: root, isDirectory: true)
                try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
                let core = try CoreBridge(modelsDir: data.appendingPathComponent("models").path, configDir: data.appendingPathComponent("config").path)
                result["playback"] = try await mediaPlaybackSmoke(core: core, source: URL(fileURLWithPath: source), root: data)
            } catch { result["error"] = error.localizedDescription }
            if let bytes = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: URL(fileURLWithPath: root).appendingPathComponent("startup.json"), options: .atomic)
            }
            NSApp.terminate(nil)
        }
        return true
    }
    var report: [String: Any] = ["started": false]
    do {
        let data = URL(fileURLWithPath: root, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let modelRoot = environment["PARAKATT_SMOKE_MODEL_ROOT"] ?? data.appendingPathComponent("models").path
        let core = try CoreBridge(modelsDir: modelRoot, configDir: data.appendingPathComponent("config").path, activeMode: "dictation")
        if environment["PARAKATT_SMOKE_MODEL_ROOT"] != nil { try core.loadModel("parakeet-tdt-0.6b-v3") }
        let status = core.speechRuntimeStatus()
        report = ["started": true, "model_loaded": core.isModelLoaded(), "actual_backend": status.actualBackend == .webGpu ? "webgpu" : "cpu", "os": ProcessInfo.processInfo.operatingSystemVersionString]
        if let source = environment["PARAKATT_SMOKE_MEDIA"] { report["media"] = try mediaImportSmoke(core: core, source: URL(fileURLWithPath: source)) }
    } catch { report["error"] = error.localizedDescription }
    report["microphone_authorization"] = MicrophoneAuthorization.description(AVCaptureDevice.authorizationStatus(for: .audio))
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: root).appendingPathComponent("startup.json"), options: .atomic)
    }
    DispatchQueue.main.async { NSApp.terminate(nil) }
    return true
}
