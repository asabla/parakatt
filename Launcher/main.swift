import Foundation

// Stable launcher binary for Parakatt.
//
// This executable must NEVER change between releases so that macOS TCC
// (Transparency, Consent, and Control) permissions persist across updates.
// TCC keys permissions on the main executable's CDHash — if this binary
// stays identical, users keep their Accessibility/Microphone/Screen Recording
// grants after upgrading.
//
// All actual application code lives in ParakattApp.framework, which is
// loaded at runtime via dlopen. The framework can change freely between
// versions without affecting TCC.

let frameworksPath = Bundle.main.privateFrameworksPath ?? {
    // Fallback: derive from executable path
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
    return execURL
        .deletingLastPathComponent()          // MacOS/
        .deletingLastPathComponent()          // Contents/
        .appendingPathComponent("Frameworks")
        .path
}()

let dylibPath = frameworksPath + "/ParakattApp.framework/ParakattApp"

guard let handle = dlopen(dylibPath, RTLD_NOW) else {
    let error = dlerror().map { String(cString: $0) } ?? "unknown error"
    fputs("Parakatt: failed to load ParakattApp.framework: \(error)\n", stderr)
    exit(1)
}

typealias EntryFunction = @convention(c) () -> Void
guard let symbol = dlsym(handle, "parakatt_main") else {
    fputs("Parakatt: failed to find parakatt_main entry point\n", stderr)
    exit(1)
}

let entry = unsafeBitCast(symbol, to: EntryFunction.self)
entry()
// entry() starts the NSApplication run loop and never returns
