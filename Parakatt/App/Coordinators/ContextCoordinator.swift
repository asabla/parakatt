import Foundation

/// Audio-source + foreground-app context shared across recording flows.
@MainActor
final class ContextCoordinator: ObservableObject {
    private var contextProvider: AppContextProviding?

    /// pid of the application to capture system audio from, or nil
    /// for the system-wide default mix.
    @Published var selectedAudioSourcePID: pid_t?
    /// Human-readable display name for the selected source — shown in
    /// the meeting UI so the user can confirm the right window is
    /// being captured.
    @Published var selectedAudioSourceName: String?

    func configure(provider: AppContextProviding?) {
        contextProvider = provider
    }

    func currentContext() -> AppContextInfo? {
        contextProvider?.currentContext()
    }

    func restorePreferredAudioSource(bridge: CoreBridge?, runningApps: RunningAppProviding) {
        guard let bundleId = try? bridge?.getPreferredAudioSource() else { return }
        if let pid = runningApps.pidForBundleId(bundleId) {
            selectedAudioSourcePID = pid
            let name = runningApps.nameForBundleId(bundleId) ?? bundleId
            selectedAudioSourceName = name
            NSLog("[Parakatt] Restored preferred audio source: %@ (pid %d)", name, pid)
        } else {
            NSLog("[Parakatt] Preferred audio source %@ not running", bundleId)
        }
    }

    func setPreferredAudioSource(bundleId: String?, bridge: CoreBridge?) {
        do {
            try bridge?.setPreferredAudioSource(bundleId)
        } catch {
            NSLog("[Parakatt] Failed to save audio source preference: %@", error.localizedDescription)
        }
    }

    func listRunningAudioApps(runningApps: RunningAppProviding) -> [AudioSourceApp] {
        runningApps.listRunningAudioApps()
    }
}
