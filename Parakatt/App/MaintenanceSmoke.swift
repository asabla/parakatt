import AppKit
import AVFoundation
import Foundation
import ParakattCore

/// Explicit packaged-app startup check. It uses isolated data and requests no permissions.
@MainActor
func runMaintenanceSmokeIfRequested() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    guard environment["PARAKATT_SMOKE_TEST"] == "1", let root = environment["PARAKATT_DATA_ROOT"] else { return false }
    var report: [String: Any] = ["started": false]
    do {
        let data = URL(fileURLWithPath: root, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let modelRoot = environment["PARAKATT_SMOKE_MODEL_ROOT"] ?? data.appendingPathComponent("models").path
        let core = try CoreBridge(modelsDir: modelRoot, configDir: data.appendingPathComponent("config").path, activeMode: "dictation")
        if environment["PARAKATT_SMOKE_MODEL_ROOT"] != nil { try core.loadModel("parakeet-tdt-0.6b-v3") }
        let status = core.speechRuntimeStatus()
        report = ["started": true, "model_loaded": core.isModelLoaded(), "actual_backend": status.actualBackend == .webGpu ? "webgpu" : "cpu", "os": ProcessInfo.processInfo.operatingSystemVersionString]
    } catch { report["error"] = error.localizedDescription }
    report["microphone_authorization"] = MicrophoneAuthorization.description(AVCaptureDevice.authorizationStatus(for: .audio))
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: root).appendingPathComponent("startup.json"), options: .atomic)
    }
    DispatchQueue.main.async { NSApp.terminate(nil) }
    return true
}
