/// C-callable entry point for the executable in the app bundle.
///
/// The launcher loads ParakattApp.framework and starts SwiftUI in the same process.
@MainActor
@_cdecl("parakatt_main")
public func parakattMain() {
    ParakattApp.main()
}
