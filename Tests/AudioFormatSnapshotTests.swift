import AVFoundation
import XCTest
@testable import ParakattApp

final class AudioFormatSnapshotTests: XCTestCase {
    func testWorkerRebuildsFormatsWithoutSharingFrameworkObjects() throws {
        for (rate, channels, interleaved) in [(48_000.0, UInt32(2), true), (16_000.0, UInt32(1), false)] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
            let snapshot = AudioFormatSnapshot(format)
            let layoutTag = format.channelLayout?.layoutTag
            let done = expectation(description: "rebuilt")
            DispatchQueue.global().async {
                let rebuilt = snapshot.makeFormat()
                XCTAssertEqual(rebuilt?.sampleRate, rate)
                XCTAssertEqual(rebuilt?.channelCount, channels)
                XCTAssertEqual(rebuilt?.isInterleaved, interleaved)
                XCTAssertEqual(rebuilt?.channelLayout?.layoutTag, layoutTag)
                done.fulfill()
            }
            wait(for: [done], timeout: 5)
        }
    }

    func testMultichannelLayoutSurvivesSnapshot() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let rebuilt = try XCTUnwrap(AudioFormatSnapshot(format).makeFormat())
        XCTAssertEqual(rebuilt.channelCount, 6)
        XCTAssertEqual(rebuilt.channelLayout?.layoutTag, layout.layoutTag)
    }
}
