import CoreAudio
import XCTest
@testable import ParakattApp

final class AudioProcessSelectionTests: XCTestCase {
    private let slack = AudioApplicationTarget(pid: 10, bundleIdentifier: "com.tinyspeck.slackmacgap", bundleURL: URL(fileURLWithPath: "/Applications/Slack.app"))

    func testSlackIncludesItsAudioHelpersWithoutRequiringTheMainProcessToPlayAudio() {
        let processes = [
            AudioProcessIdentity(objectID: 20, pid: 11, bundleIdentifier: "com.tinyspeck.slackmacgap.helper", bundleURL: URL(fileURLWithPath: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app")),
            AudioProcessIdentity(objectID: 21, pid: 12, bundleIdentifier: "com.tinyspeck.slackmacgap", bundleURL: nil),
            AudioProcessIdentity(objectID: 22, pid: 13, bundleIdentifier: "com.apple.Safari", bundleURL: URL(fileURLWithPath: "/Applications/Safari.app")),
        ]
        XCTAssertEqual(slack.processObjectIDs(in: processes), [20, 21])
    }

    func testSelectionDoesNotCaptureAnotherAppOrAnotherInstalledCopy() {
        let processes = [
            AudioProcessIdentity(objectID: 30, pid: 14, bundleIdentifier: "com.tinyspeck.slackmacgap2", bundleURL: nil),
            AudioProcessIdentity(objectID: 31, pid: 15, bundleIdentifier: "com.tinyspeck.slackmacgap.helper", bundleURL: URL(fileURLWithPath: "/Applications/Slack Backup.app")),
            AudioProcessIdentity(objectID: 32, pid: 16, bundleIdentifier: "unrelated", bundleURL: URL(fileURLWithPath: "/Applications/Slack.application")),
            AudioProcessIdentity(objectID: kAudioObjectUnknown, pid: 10, bundleIdentifier: nil, bundleURL: nil),
        ]
        XCTAssertTrue(slack.processObjectIDs(in: processes).isEmpty)
    }

    func testHelperRestartReplacesOldObjectsAndAnEmptySelectionStaysEmpty() {
        let old = AudioProcessIdentity(objectID: 40, pid: 20, bundleIdentifier: "com.tinyspeck.slackmacgap.helper", bundleURL: nil)
        let new = AudioProcessIdentity(objectID: 41, pid: 21, bundleIdentifier: "com.tinyspeck.slackmacgap.helper", bundleURL: nil)
        XCTAssertEqual(slack.processObjectIDs(in: [old, old]), [40])
        XCTAssertEqual(slack.processObjectIDs(in: [new]), [41])
        XCTAssertEqual(slack.processObjectIDs(in: []), [])
    }

    @MainActor
    func testCoreAudioHandlerCreatedOnMainCanRunOnAnAudioQueue() {
        guard #available(macOS 14.2, *) else { return }
        let capture = SystemAudioCaptureService()
        let callback = expectation(description: "audio callback ran off main")
        capture.onHealth = { health in
            XCTAssertFalse(Thread.isMainThread)
            if case .empty = health { callback.fulfill() }
        }
        let handler = capture.makeIOHandler()
        DispatchQueue.global().async {
            var timestamp = AudioTimeStamp()
            var input = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))
            var output = input
            withUnsafePointer(to: &timestamp) { time in
                withUnsafePointer(to: &input) { data in
                    withUnsafeMutablePointer(to: &output) { handler(time, data, time, $0, time) }
                }
            }
        }
        wait(for: [callback], timeout: 5)
    }
}
