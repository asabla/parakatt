import Foundation

/// Downloads to disk without holding the response body in memory.
final class MediaDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let cancellation: MediaCancellation
    private let progress: (Double?) -> Void
    private let done = DispatchSemaphore(value: 0)
    private var failure: Error?
    private var receivedFile = false
    private var lastProgress: TimeInterval = 0
    init(destination: URL, cancellation: MediaCancellation, progress: @escaping (Double?) -> Void) {
        self.destination = destination; self.cancellation = cancellation; self.progress = progress
    }
    func fetch(_ url: URL) throws {
        try MediaTools.freeSpace(destination.deletingLastPathComponent())
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel(); cancellation.registerDownload(nil) }
        var request = URLRequest(url: url); request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request); cancellation.registerDownload(task); task.resume()
        done.wait()
        if let failure { throw failure }
        try cancellation.check()
        guard receivedFile else { throw MediaImportError("The media download did not complete.") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            failure = MediaImportError("The media link redirected to an unsupported address."); completionHandler(nil); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do { try MediaTools.freeSpace(destination.deletingLastPathComponent()) }
        catch { failure = error; downloadTask.cancel() }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastProgress >= 0.2 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgress = now
            progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            failure = MediaImportError("The link could not be downloaded. Check that it is still valid."); return
        }
        let type = response.mimeType?.lowercased() ?? ""
        guard !type.contains("html"), !type.contains("mpegurl"), !type.contains("dash+xml") else {
            failure = MediaImportError("Use a direct video-file link or a public YouTube video link."); return
        }
        do {
            try cancellation.check()
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination); receivedFile = true
        } catch { failure = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil, error != nil, !cancellation.isCancelled { failure = MediaImportError("The download was interrupted. Check the connection and resume the import.") }
        done.signal()
    }
}

enum MediaLink {
    static func classify(_ value: String) throws -> (String, URL) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil else {
            throw MediaImportError("Enter an HTTP or HTTPS link without embedded credentials.")
        }
        if ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"].contains(host) {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let parts = url.path.split(separator: "/")
            let id: String?
            if host.hasSuffix("youtu.be") { id = parts.first.map(String.init) }
            else if parts.first == "watch" { id = components?.queryItems?.first(where: { $0.name == "v" })?.value }
            else if ["shorts", "embed", "live"].contains(parts.first.map(String.init) ?? ""), parts.count == 2 { id = String(parts[1]) }
            else { id = nil }
            guard let id, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { throw MediaImportError("Use an individual YouTube video link. Playlists are not supported.") }
            return ("youtube", URL(string: "https://www.youtube.com/watch?v=\(id)")!)
        }
        return ("direct", url)
    }
    static func youtubeArguments(directory: URL) throws -> [String] {
        ["--ignore-config", "--no-plugin-dirs", "--no-playlist", "--no-update", "--no-remote-components", "--no-js-runtimes", "--js-runtimes", "deno:\(try MediaTools.executable("deno").path)", "--ffmpeg-location", MediaTools.directory.path, "--no-cache-dir", "--paths", directory.path, "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3", "--no-cookies", "--no-cookies-from-browser"]
    }
    static func downloadYouTube(_ url: URL, directory: URL, cancellation: MediaCancellation, progress: @escaping (Double?) -> Void) throws -> URL {
        let base = try youtubeArguments(directory: directory)
        let metadata = try MediaTools.run("yt-dlp", base + ["--skip-download", "--dump-single-json", "--", url.absoluteString], cancellation: cancellation, workingDirectory: directory)
        let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
        guard let duration = object?["duration"] as? Double, duration > 0, object?["is_live"] as? Bool != true, object?["live_status"] as? String != "is_upcoming" else {
            throw MediaImportError("Live streams and scheduled videos are not supported.")
        }
        // Always start fresh after an interrupted transfer. This avoids mixing changed media.
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("download.") {
            try FileManager.default.removeItem(at: file)
        }
        _ = try MediaTools.run("yt-dlp", base + ["-f", "bv*+ba/b", "--merge-output-format", "mkv", "--no-continue", "--newline", "--progress-template", "download:bytes=%(progress.downloaded_bytes)s total=%(progress.total_bytes)s", "-o", "download.%(ext)s", "--", url.absoluteString], cancellation: cancellation, workingDirectory: directory, progress: { line in
            let fields = line.split(separator: " ").compactMap { Double($0.split(separator: "=").last ?? "") }
            progress(fields.count == 2 && fields[1] > 0 ? fields[0] / fields[1] : nil)
        })
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("download.") && ["mp4", "mkv", "webm", "mov"].contains($0.pathExtension.lowercased()) }
        guard candidates.count == 1, let result = candidates.first else { throw MediaImportError("The video download did not produce a complete media file.") }
        return result
    }
}
