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
    /// Periodic health signal reflecting what the tap is actually delivering.
    /// Emitted every ~2s from the capture callback queue. Lets the UI distinguish
    /// "tap created but delivering nothing" from "audio is flowing cleanly".
    var onHealth: ((SystemAudioHealth) -> Void)?

    private var tapID: AudioObjectID = AudioObjectID.max
    private var aggregateDeviceID: AudioObjectID = AudioObjectID.max
    private var ioProcID: AudioDeviceIOProcID?
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000
    private let callbackQueue = DispatchQueue(label: "com.parakatt.systemaudiotap", qos: .userInteractive)
    private let stateLock = NSLock()

    // Diagnostic counters (reset on each startCapture)
    private var emptyBufferCount = 0
    private var callbackCount = 0
    private var totalSamplesDelivered = 0

    // Rolling RMS / health tracking (accessed only from callbackQueue).
    private var rmsAccumSquares: Double = 0
    private var rmsAccumCount: Int = 0
    private var lastHealthEmitTime: CFAbsoluteTime = 0
    private var lastNonSilentTime: CFAbsoluteTime = 0
    private var lastNonEmptyTime: CFAbsoluteTime = 0
    private let silenceThresholdDbfs: Double = -60.0
    private let healthEmitIntervalSecs: Double = 2.0

    // Remembered between startCapture/stopCapture so the output-device-change
    // listener can rebuild the aggregate with the same target.
    private var activeProcessID: pid_t?
    private var outputChangeListener: AudioObjectPropertyListenerBlock?

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
        // The aggregate's main sub-device must be the one the user's other
        // apps are actually rendering to — otherwise the tap delivers
        // empty/silent buffers. We log the selected device so the problem is
        // visible in the diagnostics bundle if capture goes silent.
        let outputDeviceID = try Self.defaultOutputDeviceID()
        let outputUID = try Self.deviceUID(for: outputDeviceID)
        let outputName = Self.deviceName(for: outputDeviceID) ?? "(unknown)"
        NSLog("[Parakatt] System audio: using output device '%@' (uid=%@)",
              outputName, outputUID)

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

        // Reset diagnostic counters.
        emptyBufferCount = 0
        callbackCount = 0
        totalSamplesDelivered = 0
        let now = CFAbsoluteTimeGetCurrent()
        rmsAccumSquares = 0
        rmsAccumCount = 0
        lastHealthEmitTime = now
        lastNonSilentTime = now
        lastNonEmptyTime = now

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        NSLog("[Parakatt] System audio capture STARTED via Core Audio tap (pid: %@, macOS %d.%d.%d)",
              processID.map { String($0) } ?? "all",
              osVersion.majorVersion, osVersion.minorVersion, osVersion.patchVersion)

        // Remember target so we can rebuild after a default-output change
        // (e.g. user plugs in AirPods mid-meeting).
        activeProcessID = processID
        registerOutputChangeListener()
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

        var sawAnyData = false
        for buffer in bufferList {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                emptyBufferCount += 1
                if emptyBufferCount == 1 || emptyBufferCount % 100 == 0 {
                    NSLog("[Parakatt] System audio: empty buffer (count: %d)", emptyBufferCount)
                }
                continue
            }
            sawAnyData = true
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floatPtr = data.bindMemory(to: Float.self, capacity: sampleCount)
            let samples = Array(UnsafeBufferPointer(start: floatPtr, count: sampleCount))

            // The tap delivers at the output device's sample rate (typically 48kHz).
            // Resample to 16kHz for STT.
            resampleAndDeliver(samples: samples)
        }

        if !sawAnyData {
            // All buffers were empty — still tick the health emit clock so the
            // UI learns about persistent empty-buffer conditions.
            maybeEmitHealth(emptyThisTick: true, deliveredSamples: [])
        }
    }

    /// Accumulate RMS and, if the emit interval has elapsed, call onHealth with
    /// a classification of what the tap has been delivering. Runs on
    /// callbackQueue — single-threaded access to the accumulator fields.
    private func maybeEmitHealth(emptyThisTick: Bool, deliveredSamples: [Float]) {
        let now = CFAbsoluteTimeGetCurrent()

        if !emptyThisTick {
            lastNonEmptyTime = now
            var sumSq: Double = 0
            for s in deliveredSamples {
                sumSq += Double(s) * Double(s)
            }
            rmsAccumSquares += sumSq
            rmsAccumCount += deliveredSamples.count
        }

        guard now - lastHealthEmitTime >= healthEmitIntervalSecs else { return }
        lastHealthEmitTime = now

        let health: SystemAudioHealth
        let emptyDuration = now - lastNonEmptyTime
        if emptyDuration >= healthEmitIntervalSecs {
            health = .empty(forSeconds: emptyDuration)
        } else if rmsAccumCount > 0 {
            let meanSq = rmsAccumSquares / Double(rmsAccumCount)
            let rms = sqrt(max(meanSq, 0))
            let dbfs = 20.0 * log10(max(rms, 1e-9))
            if dbfs >= silenceThresholdDbfs {
                lastNonSilentTime = now
                health = .ok(rmsDbfs: dbfs)
            } else {
                health = .silent(forSeconds: now - lastNonSilentTime)
            }
        } else {
            health = .empty(forSeconds: emptyDuration)
        }

        rmsAccumSquares = 0
        rmsAccumCount = 0
        onHealth?(health)
    }

    // MARK: - Resampling

    private func resampleAndDeliver(samples: [Float]) {
        // Snapshot state under lock so teardown on another thread doesn't race.
        stateLock.lock()
        let deviceID = aggregateDeviceID
        var conv = converter
        stateLock.unlock()

        guard deviceID != AudioObjectID.max else {
            NSLog("[Parakatt] System audio resample: device torn down, skipping")
            return
        }

        // Detect source sample rate from the aggregate device.
        let sourceSampleRate: Double
        if let detected = Self.deviceSampleRate(deviceID) {
            sourceSampleRate = detected
        } else {
            sourceSampleRate = 48_000
            NSLog("[Parakatt] System audio: could not read device sample rate, assuming 48kHz")
        }

        if abs(sourceSampleRate - targetSampleRate) < 1.0 {
            onAudioSamples?(samples)
            return
        }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            NSLog("[Parakatt] System audio: failed to construct PCM formats")
            return
        }

        if conv == nil || conv?.inputFormat.sampleRate != sourceSampleRate {
            conv = AVAudioConverter(from: sourceFormat, to: targetFormat)
            stateLock.lock()
            converter = conv
            stateLock.unlock()
        }
        guard let conv else {
            NSLog("[Parakatt] System audio: failed to create AVAudioConverter (source: %.0fHz)", sourceSampleRate)
            return
        }

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            NSLog("[Parakatt] System audio: failed to create input PCM buffer (%d samples)", samples.count)
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            inputBuffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }

        let ratio = targetSampleRate / sourceSampleRate
        let outputFrameCount = AVAudioFrameCount(Double(samples.count) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            NSLog("[Parakatt] System audio: failed to create output PCM buffer (%d frames)", outputFrameCount)
            return
        }

        var consumed = false
        var convertError: NSError?
        let convStatus = conv.convert(to: outputBuffer, error: &convertError) { _, ioStatus in
            if consumed { ioStatus.pointee = .noDataNow; return nil }
            consumed = true
            ioStatus.pointee = .haveData
            return inputBuffer
        }
        if convStatus == .error {
            NSLog("[Parakatt] System audio: convert failed: %@",
                  convertError?.localizedDescription ?? "unknown")
            return
        }

        let count = Int(outputBuffer.frameLength)
        guard count > 0, let data = outputBuffer.floatChannelData else {
            NSLog("[Parakatt] System audio: converter produced 0 frames")
            return
        }
        let resampled = Array(UnsafeBufferPointer(start: data[0], count: count))

        callbackCount += 1
        totalSamplesDelivered += resampled.count
        if callbackCount % 50 == 1 {
            NSLog("[Parakatt] System audio callback #%d, total samples: %d (%.1fs)",
                  callbackCount, totalSamplesDelivered, Double(totalSamplesDelivered) / 16000.0)
        }

        maybeEmitHealth(emptyThisTick: false, deliveredSamples: resampled)
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

        unregisterOutputChangeListener()

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

    // MARK: - Default-output-device listener

    /// Register a property listener for the system's default output device.
    /// When it changes (e.g. AirPods connect mid-meeting), the aggregate we
    /// built from the old default won't capture anything, so we rebuild with
    /// the new main sub-device.
    private func registerOutputChangeListener() {
        guard outputChangeListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.callbackQueue.async { [weak self] in
                self?.rebuildAfterOutputChange()
            }
        }
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            callbackQueue,
            block
        )
        if err == noErr {
            outputChangeListener = block
        } else {
            NSLog("[Parakatt] System audio: output-change listener register FAILED (err=%d)", err)
        }
    }

    private func unregisterOutputChangeListener() {
        guard let block = outputChangeListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            callbackQueue,
            block
        )
        outputChangeListener = nil
    }

    /// Called from the output-change listener. Tears down the current tap +
    /// aggregate and re-runs startCapture with the remembered processID so
    /// the new default output becomes the tap's main sub-device.
    private func rebuildAfterOutputChange() {
        stateLock.lock()
        let isActive = tapID != AudioObjectID.max
        let pid = activeProcessID
        stateLock.unlock()
        guard isActive else { return }

        NSLog("[Parakatt] System audio: default output changed — rebuilding aggregate")
        teardown()
        do {
            try startCapture(processID: pid)
        } catch {
            NSLog("[Parakatt] System audio: rebuild FAILED: %@", error.localizedDescription)
            // Signal health so the UI can show that capture went down.
            onHealth?(.empty(forSeconds: 0))
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

    private static func deviceName(for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard err == noErr, let cf = name?.takeRetainedValue() else { return nil }
        return cf as String
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

/// Health snapshot emitted periodically from the system-audio tap so the UI
/// can distinguish "flowing" from "tap exists but delivers nothing".
enum SystemAudioHealth {
    /// Audio is flowing with signal above the silence threshold.
    case ok(rmsDbfs: Double)
    /// Buffers are arriving with data but the level is below the silence
    /// threshold. `forSeconds` is how long we've been continuously silent.
    case silent(forSeconds: Double)
    /// Buffers are arriving empty (nil mData or zero byte size) or not at all.
    /// `forSeconds` is how long since the last non-empty buffer.
    case empty(forSeconds: Double)
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
