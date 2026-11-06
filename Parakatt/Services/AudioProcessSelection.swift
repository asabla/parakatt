import CoreAudio
import Foundation

struct AudioProcessIdentity: Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?
}

struct AudioApplicationTarget: Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?

    func processObjectIDs(in processes: [AudioProcessIdentity]) -> [AudioObjectID] {
        let root = bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path
        return Array(Set(processes.filter { process in
            guard process.objectID != kAudioObjectUnknown,
                  process.objectID != AudioObjectID.max else { return false }
            if process.pid == pid { return true }
            if let root, let path = process.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path {
                return path == root || path.hasPrefix(root + "/")
            }
            guard let bundleIdentifier, let candidate = process.bundleIdentifier else { return false }
            return candidate == bundleIdentifier || candidate.hasPrefix(bundleIdentifier + ".")
        }.map(\.objectID))).sorted()
    }
}
