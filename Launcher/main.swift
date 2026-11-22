import Foundation

// Bundle entry point. The application framework runs in this process, so
// system permissions are attributed to the signed Parakatt app bundle.
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
