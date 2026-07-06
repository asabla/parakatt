import Foundation

/// Owns the Rust engine bridge lifecycle.
@MainActor
final class EngineCoordinator {
    private(set) var bridge: CoreBridge?
    private(set) var isReady = false

    func initialize(modelsDir: String, configDir: String, activeMode: String) throws -> CoreBridge {
        let created = try CoreBridge(
            modelsDir: modelsDir,
            configDir: configDir,
            activeMode: activeMode
        )
        bridge = created
        isReady = true
        return created
    }

    func shutdown() {
        bridge = nil
        isReady = false
    }
}
