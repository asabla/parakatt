import Cocoa

/// Represents a running app that can be used as an audio source.
struct AudioSourceApp: Identifiable, Hashable {
    let id: pid_t
    let name: String
    let bundleIdentifier: String
    let icon: NSImage?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioSourceApp, rhs: AudioSourceApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// Discovers running apps that are likely audio sources for meeting transcription.
enum AudioSourceService {
    /// Known communication/media app bundle identifiers.
    private static let knownBundleIds: [(bundleId: String, label: String)] = [
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("us.zoom.xos", "Zoom"),
        ("com.hnc.Discord", "Discord"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.google.Chrome", "Google Chrome"),
        ("com.apple.Safari", "Safari"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.spotify.client", "Spotify"),
    ]

    /// Returns currently running apps that match known audio source bundle IDs.
    static func listRunningAudioApps() -> [AudioSourceApp] {
        var apps: [AudioSourceApp] = []
        var seenPIDs = Set<pid_t>()

        for (bundleId, _) in knownBundleIds {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            for app in running where !app.isTerminated {
                let pid = app.processIdentifier
                guard !seenPIDs.contains(pid) else { continue }
                seenPIDs.insert(pid)

                apps.append(AudioSourceApp(
                    id: pid,
                    name: app.localizedName ?? bundleId,
                    bundleIdentifier: bundleId,
                    icon: app.icon
                ))
            }
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolve a bundle identifier to a PID if the app is currently running.
    static func pidForBundleId(_ bundleId: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first(where: { !$0.isTerminated })?
            .processIdentifier
    }
}
