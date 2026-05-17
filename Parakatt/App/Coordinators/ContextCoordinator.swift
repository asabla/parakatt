import Foundation

/// Audio-source + foreground-app context shared across recording flows.
///
/// Currently owns the meeting audio source pick (pid + display name).
/// AppState's `ContextService` invocations stay where they are for
/// now — moving them here is a follow-up once the other coordinators
/// have settled.
@MainActor
final class ContextCoordinator: ObservableObject {
    /// pid of the application to capture system audio from, or nil
    /// for the system-wide default mix.
    @Published var selectedAudioSourcePID: pid_t?
    /// Human-readable display name for the selected source — shown in
    /// the meeting UI so the user can confirm the right window is
    /// being captured.
    @Published var selectedAudioSourceName: String?
}
