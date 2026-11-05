import AVFoundation
import Foundation

/// Transfers value data across queues without sharing an AVAudioFormat instance.
struct AudioFormatSnapshot: Sendable {
    private let description: Data
    private let layout: Data?

    init(_ format: AVAudioFormat) {
        description = withUnsafeBytes(of: format.streamDescription.pointee) { Data($0) }
        layout = format.channelLayout.flatMap { layout in
            guard let headerSize = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions) else { return nil }
            let size = headerSize + Int(layout.layout.pointee.mNumberChannelDescriptions) * MemoryLayout<AudioChannelDescription>.stride
            return Data(bytes: layout.layout, count: size)
        }
    }

    func makeFormat() -> AVAudioFormat? {
        var stream = description.withUnsafeBytes { $0.loadUnaligned(as: AudioStreamBasicDescription.self) }
        guard let layout else { return AVAudioFormat(streamDescription: &stream) }
        // Data does not promise the alignment required by AudioChannelLayout.
        let count = max(layout.count, MemoryLayout<AudioChannelLayout>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: count)
        layout.copyBytes(to: UnsafeMutableRawBufferPointer(start: storage, count: layout.count))
        let channels = AVAudioChannelLayout(layout: storage.assumingMemoryBound(to: AudioChannelLayout.self))
        return AVAudioFormat(streamDescription: &stream, channelLayout: channels)
    }
}
