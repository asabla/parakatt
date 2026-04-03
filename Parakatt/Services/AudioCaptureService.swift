import AVFoundation
import CoreAudio
import Foundation

/// Captures microphone audio in 16kHz mono Float32 format.
///
/// Selects the best available input device — prefers the system default,
/// falls back to the built-in microphone if the default produces silence.
class AudioCaptureService {
    var onAudioSamples: (([Float]) -> Void)?
    /// Called when the audio device list changes (device plugged/unplugged).
    var onDeviceChanged: (() -> Void)?

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000
    private let engineLock = NSLock()
    private var deviceListenerInstalled = false

    /// Currently selected device ID (nil = system default).
    private var selectedDeviceUID: String?

    /// Start a recording session.
    ///
    /// Uses the macOS system default input device unless the user has
    /// explicitly selected a specific device via the Input Device menu.
    /// This means connecting AirPods (which changes the system default)
    /// will automatically use AirPods — no manual selection needed.
    func startCapture() throws {
        teardown()
        tapCallbackCount = 0
        lastConverterSourceRate = 0

        let engine = AVAudioEngine()

        // Only override the device if the user explicitly selected one.
        // When selectedDeviceUID is nil, AVAudioEngine uses the system
        // default — which is what the user expects after connecting
        // AirPods or any other audio device.
        if let uid = selectedDeviceUID {
            NSLog("[Parakatt] Requesting explicit input device: %@", uid)
            do {
                try Self.setInputDevice(engine: engine, uid: uid)
            } catch {
                // If the explicit device fails (common with Bluetooth),
                // fall back to system default rather than failing entirely.
                NSLog("[Parakatt] WARNING: Failed to set device %@: %@ — using system default",
                      uid, error.localizedDescription)
            }
        }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            NSLog("[Parakatt] ERROR: Input node format has sampleRate=0 — no working input device")
            throw AudioCaptureError.noInputDevice
        }

        // Log the actual device the engine ended up using
        let actualDevice = Self.currentInputDeviceName(engine: engine) ?? "unknown"
        NSLog("[Parakatt] Audio input: %.0fHz %dch (device: %@)",
              hwFormat.sampleRate, hwFormat.channelCount, actualDevice)

        // Install tap with nil format — lets the system choose the actual
        // hardware format. This avoids -10868 (FormatNotSupported) errors
        // when the device's real format differs from what outputFormat reports
        // (common with Bluetooth devices like AirPods).
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.engineLock.lock()
            let active = self.audioEngine != nil
            self.engineLock.unlock()
            guard active else { return }

            let bufferFormat = buffer.format
            if bufferFormat.sampleRate != self.targetSampleRate || bufferFormat.channelCount != 1 {
                self.convertAndDeliver(buffer: buffer)
            } else {
                self.deliverSamples(from: buffer)
            }
        }

        engine.prepare()
        try engine.start()

        engineLock.lock()
        self.audioEngine = engine
        engineLock.unlock()

        installDeviceChangeListener()
        NSLog("[Parakatt] Audio capture STARTED")
    }

    /// Stop the current recording session and tear down the audio engine.
    func stopCapture() {
        engineLock.lock()
        let hasEngine = audioEngine != nil
        engineLock.unlock()
        guard hasEngine else { return }
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
            let nameStr = name as String

            // Filter out internal/virtual aggregate devices that aren't real hardware.
            // CADefaultDeviceAggregate is created internally by Core Audio.
            // Also skip devices whose UID or name suggests they are virtual aggregates.
            if uidStr.hasPrefix("CADefaultDeviceAggregate") { continue }
            if nameStr.hasPrefix("CADefaultDeviceAggregate") { continue }

            // Check transport type — skip aggregate (kAudioDeviceTransportTypeAggregate = 'grup')
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transportType) == noErr {
                // 'grup' = aggregate, 'virt' = virtual
                if transportType == kAudioDeviceTransportTypeAggregate
                    || transportType == kAudioDeviceTransportTypeVirtual {
                    continue
                }
            }

            results.append((uid: uidStr, name: nameStr, isDefault: uidStr == defaultUID))
        }

        return results
    }

    // MARK: - Device change listener

    private func installDeviceChangeListener() {
        guard !deviceListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        // Use Unmanaged to pass self as the client data pointer for the C callback.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceChangeCallback,
            selfPtr
        )

        if status == noErr {
            deviceListenerInstalled = true
            NSLog("[Parakatt] Device change listener installed")
        } else {
            NSLog("[Parakatt] Failed to install device change listener: %d", status)
        }
    }

    private func removeDeviceChangeListener() {
        guard deviceListenerInstalled else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        AudioObjectRemovePropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            deviceChangeCallback,
            selfPtr
        )
        deviceListenerInstalled = false
    }

    /// Handle device list changes: if an explicitly-selected device was removed,
    /// fall back to system default and restart capture.
    fileprivate func handleDeviceChange() {
        guard let uid = selectedDeviceUID else { return }

        let devices = Self.listInputDevices()
        let stillAvailable = devices.contains { $0.uid == uid }
        if !stillAvailable {
            NSLog("[Parakatt] Selected device %@ was disconnected — falling back to system default", uid)
            selectedDeviceUID = nil
            onDeviceChanged?()

            engineLock.lock()
            let isActive = audioEngine != nil
            engineLock.unlock()
            if isActive {
                do {
                    try startCapture()
                    NSLog("[Parakatt] Restarted capture with system default after device disconnect")
                } catch {
                    NSLog("[Parakatt] Failed to restart capture after device disconnect: %@",
                          error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Private

    private func teardown() {
        removeDeviceChangeListener()

        // Nil out state under lock FIRST so in-flight tap callbacks exit early
        engineLock.lock()
        let engine = audioEngine
        audioEngine = nil
        converter = nil
        engineLock.unlock()

        guard let engine else { return }

        var error: NSError?
        let ok = catchObjCException({
            if engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
        }, &error)

        if !ok {
            NSLog("[Parakatt] Audio engine teardown caught ObjC exception: %@",
                  error?.localizedDescription ?? "unknown")
        }
    }

    /// Track the source format to detect when we need a new converter.
    private var lastConverterSourceRate: Double = 0

    private func convertAndDeliver(buffer: AVAudioPCMBuffer) {
        let bufferFormat = buffer.format

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // Create or recreate converter if the source format changed.
        engineLock.lock()
        if converter == nil || lastConverterSourceRate != bufferFormat.sampleRate {
            converter = AVAudioConverter(from: bufferFormat, to: targetFormat)
            lastConverterSourceRate = bufferFormat.sampleRate
            if converter == nil {
                NSLog("[Parakatt] ERROR: Failed to create converter from %.0fHz %dch to 16kHz mono",
                      bufferFormat.sampleRate, bufferFormat.channelCount)
            } else {
                NSLog("[Parakatt] Created audio converter: %.0fHz %dch → 16kHz mono",
                      bufferFormat.sampleRate, bufferFormat.channelCount)
            }
        }
        let conv = converter
        engineLock.unlock()

        guard let conv else { return }

        let ratio = targetSampleRate / bufferFormat.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var consumed = false
        conv.convert(to: outBuf, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        deliverSamples(from: outBuf)
    }

    private var tapCallbackCount = 0

    private func deliverSamples(from buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: count))

        tapCallbackCount += 1
        if tapCallbackCount == 1 || tapCallbackCount % 100 == 0 {
            let maxAmp = samples.map { abs($0) }.max() ?? 0
            NSLog("[Parakatt] Mic tap callback #%d: %d samples, maxAmp=%.6f%@",
                  tapCallbackCount, count, maxAmp,
                  maxAmp < 0.0001 ? " (SILENT)" : "")
        }

        onAudioSamples?(samples)
    }

    // MARK: - Device selection helpers

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
        guard let device = devices.first(where: { $0.uid == uid }) else {
            NSLog("[Parakatt] ERROR: Device not found for uid: %@", uid)
            NSLog("[Parakatt] Available devices: %@", devices.map { "\($0.name) (\($0.uid))" }.joined(separator: ", "))
            throw AudioCaptureError.noInputDevice
        }

        NSLog("[Parakatt] Setting input device: %@ (uid: %@)", device.name, uid)

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
                guard let audioUnit = engine.inputNode.audioUnit else {
                    NSLog("[Parakatt] ERROR: Could not get audioUnit from inputNode")
                    throw AudioCaptureError.noInputDevice
                }

                var inputDeviceID = deviceID
                let status = AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &inputDeviceID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )

                if status != noErr {
                    NSLog("[Parakatt] ERROR: AudioUnitSetProperty failed with status %d for device %@ (id %d)",
                          status, device.name, deviceID)
                    throw AudioCaptureError.deviceSelectionFailed(status)
                }

                // Verify the device actually changed
                var currentDeviceID: AudioDeviceID = 0
                var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
                let verifyStatus = AudioUnitGetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &currentDeviceID,
                    &propSize
                )

                if verifyStatus == noErr {
                    if currentDeviceID == deviceID {
                        NSLog("[Parakatt] Input device set successfully: %@ (CoreAudio id %d)",
                              device.name, deviceID)
                    } else {
                        NSLog("[Parakatt] WARNING: Device set returned noErr but current device is %d, expected %d",
                              currentDeviceID, deviceID)
                    }
                }

                return
            }
        }

        NSLog("[Parakatt] ERROR: Could not find CoreAudio device ID for uid: %@", uid)
        throw AudioCaptureError.noInputDevice
    }

    /// Get the name of the device currently used by the engine's input node.
    private static func currentInputDeviceName(engine: AVAudioEngine) -> String? {
        guard let audioUnit = engine.inputNode.audioUnit else { return nil }

        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr else { return nil }

        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        let nameStatus = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        guard nameStatus == noErr else { return nil }
        return name as String
    }
}

/// C callback for AudioObjectAddPropertyListener — dispatches to the instance method.
private func deviceChangeCallback(
    _: AudioObjectID,
    _: UInt32,
    _: UnsafePointer<AudioObjectPropertyAddress>,
    clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let service = Unmanaged<AudioCaptureService>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async {
        service.handleDeviceChange()
    }
    return noErr
}

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice
    case formatCreationFailed
    case converterCreationFailed
    case deviceSelectionFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No audio input device available"
        case .formatCreationFailed: return "Failed to create target audio format"
        case .converterCreationFailed: return "Failed to create audio format converter"
        case .deviceSelectionFailed(let status): return "Failed to select audio device (error \(status))"
        }
    }
}
