import Foundation

/// File-based logging service with rotation.
///
/// Writes log lines to `~/Library/Application Support/Parakatt/logs/parakatt.log`.
/// Rotates when the file exceeds `maxFileSize` bytes, keeping up to `maxFiles` rotated copies.
///
/// This supplements (not replaces) NSLog — NSLog continues to write to Console.app/stderr
/// as normal, while this service maintains a persistent log file for troubleshooting.
class FileLogService {
    static let shared = FileLogService()

    private let logDir: URL
    private let logFile: URL
    private let maxFileSize: UInt64 = 10 * 1024 * 1024 // 10 MB
    private let maxFiles = 5
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.parakatt.filelog", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        logDir = appSupport.appendingPathComponent("Parakatt/logs")
        logFile = logDir.appendingPathComponent("parakatt.log")
        setupLogFile()
    }

    /// Write a log line with timestamp and category.
    /// Also writes via NSLog so it appears in Console.app.
    func log(_ message: String, category: String = "App") {
        // NSLog for Console.app + stderr (visible in `make run`)
        NSLog("[Parakatt] [%@] %@", category, message)

        // File log with more precise timestamp
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            self.fileHandle?.write(data)

            // Check rotation
            if let attrs = try? FileManager.default.attributesOfItem(atPath: self.logFile.path),
               let size = attrs[.size] as? UInt64, size > self.maxFileSize {
                self.rotate()
            }
        }
    }

    /// Mirror an existing NSLog message to the file log.
    /// Call this after NSLog to also persist the message to disk.
    func mirror(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = self.dateFormatter.string(from: Date())
            let line = "[\(timestamp)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.fileHandle?.write(data)
        }
    }

    /// Write a startup marker to the log file.
    func logStartup() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        log("=== Parakatt \(version) (\(build)) started ===", category: "App")
    }

    // MARK: - Private

    private func setupLogFile() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
    }

    private func rotate() {
        fileHandle?.closeFile()
        fileHandle = nil

        // Shift existing rotated files: .4 -> delete, .3 -> .4, .2 -> .3, .1 -> .2, current -> .1
        let fm = FileManager.default
        for i in stride(from: maxFiles - 1, through: 1, by: -1) {
            let src = logDir.appendingPathComponent("parakatt.\(i).log")
            let dst = logDir.appendingPathComponent("parakatt.\(i + 1).log")
            try? fm.removeItem(at: dst)
            try? fm.moveItem(at: src, to: dst)
        }

        let rotated = logDir.appendingPathComponent("parakatt.1.log")
        try? fm.moveItem(at: logFile, to: rotated)

        // Create fresh log file
        fm.createFile(atPath: logFile.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()

        NSLog("[Parakatt] Log rotated")
    }

    deinit {
        fileHandle?.closeFile()
    }
}
