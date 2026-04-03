import Foundation

/// File-based logging service with rotation.
///
/// Writes log lines to `~/Library/Application Support/Parakatt/logs/parakatt.log`.
/// Rotates when the file exceeds `maxFileSize` bytes, keeping up to `maxFiles` rotated copies.
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
    func log(_ message: String, category: String = "App") {
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

    /// Redirect NSLog output to the file logger by installing a custom handler.
    func startCapturingNSLog() {
        // Capture stderr (where NSLog writes) and tee it to the log file.
        // This is a lightweight approach — NSLog still goes to Console.app.
        let pipe = Pipe()
        let originalStderr = dup(STDERR_FILENO)

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Write to original stderr so Console.app still gets it
            write(originalStderr, (data as NSData).bytes, data.count)

            // Also write to our log file
            self?.queue.async {
                self?.fileHandle?.write(data)
            }
        }

        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
    }

    // MARK: - Private

    private func setupLogFile() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()

        // Write startup marker
        let timestamp = dateFormatter.string(from: Date())
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let marker = "\n[\(timestamp)] [App] === Parakatt \(version) started ===\n"
        if let data = marker.data(using: .utf8) {
            fileHandle?.write(data)
        }
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
