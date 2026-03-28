import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio in 16kHz mono Float32 format.
///
/// Selects the best available input device — prefers the system default,
/// falls back to the built-in microphone if the default produces silence.
class AudioCaptureService {
    var onAudioSamples: (([Float]) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000

    /// Currently selected device ID (nil = system default).
    private var selectedDeviceUID: String?

    /// Start a recording session.
    func startCapture() throws {
        teardown()

        let engine = AVAudioEngine()

        // Select input device
        if let uid = selectedDeviceUID ?? Self.findWorkingInputDeviceUID() {
            try Self.setInputDevice(engine: engine, uid: uid)
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let deviceUsed = selectedDeviceUID ?? Self.findWorkingInputDeviceUID() ?? "system default"
        NSLog("[Parakatt] Audio input: %.0fHz %dch (device: %@)",
              hwFormat.sampleRate, hwFormat.channelCount, deviceUsed)

        // Install tap in native format (nil = use hardware format)
        // Resample to 16kHz mono in the delivery callback
        if hwFormat.sampleRate != targetSampleRate || hwFormat.channelCount != 1 {
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )!

            guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                throw AudioCaptureError.converterCreationFailed
            }
            self.converter = conv

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.convertAndDeliver(buffer: buffer)
            }
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.deliverSamples(from: buffer)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine

        NSLog("[Parakatt] Audio capture STARTED")
    }

    func stopCapture() {
        guard audioEngine != nil else { return }
        teardown()
        NSLog("[Parakatt] Audio capture STOPPED")
    }

    /// Set the input device by UID. Pass nil for system default.
    func setInputDevice(uid: String?) {
        selectedDeviceUID = uid
    }

    /// List available audio input devices.
    static func listInputDevices() -> [(uid: String, name: String, isDefault: Bool)] {
        var results: [(uid: String, name: String, isDefault: Bool)] = []
        let defaultUID = getDefaultInputDeviceUID()

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var inputSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize) == noErr else { continue }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPointer) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

            let uidStr = uid as String
            results.append((uid: uidStr, name: name as String, isDefault: uidStr == defaultUID))
        }

        return results
    }

    // MARK: - Private

    private func teardown() {
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        converter = nil
    }

    private func convertAndDeliver(buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        let ratio = targetSampleRate / buffer.format.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var consumed = false
        converter.convert(to: outBuf, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        deliverSamples(from: outBuf)
    }

    private func deliverSamples(from buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
        onAudioSamples?(samples)
    }

    // MARK: - Device selection helpers

    /// Find a suitable input device.
    /// Always prefers the built-in microphone since external devices
    /// (USB headsets, etc.) may be physically disconnected and produce silence.
    /// The user can override this via the Input Device menu.
    private static func findWorkingInputDeviceUID() -> String? {
        let devices = listInputDevices()

        // Check if system default IS the built-in mic already
        if let defaultDev = devices.first(where: { $0.isDefault }),
           defaultDev.uid.contains("BuiltIn") {
            return nil // system default is the built-in mic, no override needed
        }

        // System default is NOT built-in — override to built-in if available
        if let builtIn = devices.first(where: { $0.uid.contains("BuiltIn") }) {
            NSLog("[Parakatt] Default device is not built-in mic, overriding → %@", builtIn.name)
            return builtIn.uid
        }

        // No built-in mic (e.g. Mac Mini) — use system default
        return nil
    }

    private static func getDefaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else {
            return nil
        }
        return uid as String
    }

    private static func setInputDevice(engine: AVAudioEngine, uid: String) throws {
        let devices = listInputDevices()
        guard devices.contains(where: { $0.uid == uid }) else {
            throw AudioCaptureError.noInputDevice
        }

        // Find the AudioDeviceID for this UID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs)

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var devUID: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &devUID)

            if (devUID as String) == uid {
                // Set this device as the engine's input
                let audioUnit = engine.inputNode.audioUnit!
                var inputDeviceID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &inputDeviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                return
            }
        }
    }
}

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice
    case formatCreationFailed
    case converterCreationFailed

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No audio input device available"
        case .formatCreationFailed: return "Failed to create target audio format"
        case .converterCreationFailed: return "Failed to create audio format converter"
        }
    }
}
