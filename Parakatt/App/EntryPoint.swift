import Foundation

/// C-callable entry point for the stable launcher binary.
///
/// The launcher (Launcher/main.swift) loads ParakattApp.framework via dlopen
/// and calls this function to start the application. This decoupling keeps
/// the launcher binary identical across versions so macOS TCC permissions
/// persist after updates.
@_cdecl("parakatt_main")
public func parakattMain() {
    ParakattApp.main()
}
