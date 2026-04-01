import AVFoundation
import CoreAudio
import Foundation

/// Captures system audio (output from other apps) via Core Audio process taps.
///
/// Uses AudioHardwareCreateProcessTap (macOS 14.2+) which only requires the
/// "System Audio Recording Only" permission — no Screen Recording needed.
/// Delivers 16kHz mono Float32 samples through the same callback interface
/// as AudioCaptureService.
@available(macOS 14.2, *)
class SystemAudioCaptureService {
    var onAudioSamples: (([Float]) -> Void)?

    private var tapID: AudioObjectID = AudioObjectID.max
    private var aggregateDeviceID: AudioObjectID = AudioObjectID.max
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000
    private let callbackQueue = DispatchQueue(label: "com.parakatt.systemaudiotap", qos: .userInteractive)
    private let stateLock = NSLock()

    /// Start capturing system audio.
    /// - Parameter processID: If provided, capture audio from this process only.
    ///   If nil, capture all system audio (excluding Parakatt itself).
    func startCapture(processID: pid_t? = nil) throws {
        stopCapture()

        // 1. Create the process tap.
        let tapDescription: CATapDescription
        if let pid = processID {
            let objectID = try Self.translatePID(pid)
            tapDescription = CATapDescription(monoMixdownOfProcesses: [objectID])
        } else {
            // Global tap excluding our own process.
            let selfObjectID = try Self.translatePID(ProcessInfo.processInfo.processIdentifier)
            tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [selfObjectID])
        }
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted

        var newTapID: AudioObjectID = AudioObjectID.max
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapErr == noErr else {
            if tapErr == -1 {
                throw SystemAudioCaptureError.permissionDenied
            }
            throw SystemAudioCaptureError.tapCreationFailed(tapErr)
        }
        self.tapID = newTapID

        // 2. Create an aggregate device that includes the tap.
        let outputDeviceID = try Self.defaultOutputDeviceID()
        let outputUID = try Self.deviceUID(for: outputDeviceID)

        let aggregateDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ParakattSystemAudioTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = AudioObjectID.max
        let aggErr = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &newAggregateID)
        guard aggErr == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID.max
            throw SystemAudioCaptureError.aggregateDeviceFailed(aggErr)
        }
        self.aggregateDeviceID = newAggregateID

        // 3. Create an IOProc on the aggregate device to receive audio.
        var procID: AudioDeviceIOProcID?
        let ioErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, callbackQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.handleAudioCallback(inInputData)
        }
        guard ioErr == noErr, let procID else {
            teardown()
            throw SystemAudioCaptureError.ioProcFailed(ioErr)
        }
        self.ioProcID = procID

        // 4. Start the device.
        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else {
            teardown()
            throw SystemAudioCaptureError.deviceStartFailed(startErr)
        }

        NSLog("[Parakatt] System audio capture STARTED via Core Audio tap (pid: %@)",
              processID.map { String($0) } ?? "all")
    }

    func stopCapture() {
        stateLock.lock()
        let hasTap = tapID != AudioObjectID.max
        stateLock.unlock()
        guard hasTap else { return }
        teardown()
        NSLog("[Parakatt] System audio capture STOPPED")
    }

    // MARK: - Audio callback

    private func handleAudioCallback(_ inputData: UnsafePointer<AudioBufferList>) {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))

        for buffer in bufferList {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floatPtr = data.bindMemory(to: Float.self, capacity: sampleCount)
            let samples = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))

            // The tap delivers at the output device's sample rate (typically 48kHz).
            // Resample to 16kHz for STT.
            resampleAndDeliver(samples: samples)
        }
    }

    // MARK: - Resampling

    private func resampleAndDeliver(samples: [Float]) {
        // Snapshot state under lock so teardown on another thread doesn't race.
        stateLock.lock()
        let deviceID = aggregateDeviceID
        var conv = converter
        stateLock.unlock()

        guard deviceID != AudioObjectID.max else { return }

        // Detect source sample rate from the aggregate device.
        let sourceSampleRate = Self.deviceSampleRate(deviceID) ?? 48_000

        if abs(sourceSampleRate - targetSampleRate) < 1.0 {
            onAudioSamples?(samples)
            return
        }

        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        )!

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        if conv == nil || conv?.inputFormat.sampleRate != sourceSampleRate {
            conv = AVAudioConverter(from: sourceFormat, to: targetFormat)
            stateLock.lock()
            converter = conv
            stateLock.unlock()
        }
        guard let conv else { return }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            inputBuffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }

        let ratio = targetSampleRate / sourceSampleRate
        let outputFrameCount = AVAudioFrameCount(Double(samples.count) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

        var consumed = false
        conv.convert(to: outputBuffer, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        let count = Int(outputBuffer.frameLength)
        guard count > 0, let data = outputBuffer.floatChannelData else { return }
        let resampled = Array(UnsafeBufferPointer(start: data[0], count: count))
        onAudioSamples?(resampled)
    }

    // MARK: - Teardown

    private func teardown() {
        // Snapshot and nil out state under lock so in-flight callbacks exit early.
        stateLock.lock()
        let procID = ioProcID
        let aggID = aggregateDeviceID
        let tapIDLocal = tapID
        ioProcID = nil
        aggregateDeviceID = AudioObjectID.max
        tapID = AudioObjectID.max
        converter = nil
        stateLock.unlock()

        if let procID, aggID != AudioObjectID.max {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }

        if aggID != AudioObjectID.max {
            AudioHardwareDestroyAggregateDevice(aggID)
        }

        if tapIDLocal != AudioObjectID.max {
            AudioHardwareDestroyProcessTap(tapIDLocal)
        }
    }

    deinit {
        teardown()
    }

    // MARK: - Core Audio helpers

    private static func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        var objectID: AudioObjectID = AudioObjectID.max
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            qualifierSize,
            &pid,
            &size,
            &objectID
        )
        guard err == noErr else {
            throw SystemAudioCaptureError.processNotFound(pid)
        }
        return objectID
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr else {
            throw SystemAudioCaptureError.noOutputDevice
        }
        return deviceID
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid)
        guard err == noErr else {
            throw SystemAudioCaptureError.deviceUIDNotFound
        }
        return uid as String
    }

    private static func deviceSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        guard err == noErr else { return nil }
        return sampleRate
    }
}

enum SystemAudioCaptureError: Error, LocalizedError {
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case processNotFound(pid_t)
    case noOutputDevice
    case deviceUIDNotFound

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "System Audio Recording permission is required. Enable Parakatt in System Settings > Privacy & Security > Screen & System Audio Recording."
        case .tapCreationFailed(let s):
            return "Failed to create audio tap (error \(s))"
        case .aggregateDeviceFailed(let s):
            return "Failed to create aggregate audio device (error \(s))"
        case .ioProcFailed(let s):
            return "Failed to create audio IO proc (error \(s))"
        case .deviceStartFailed(let s):
            return "Failed to start audio device (error \(s))"
        case .processNotFound(let pid):
            return "Audio process not found for PID \(pid)"
        case .noOutputDevice:
            return "No audio output device found"
        case .deviceUIDNotFound:
            return "Could not read audio device UID"
        }
    }
}
