#!/usr/bin/swift
/// Minimal audio capture test — tries multiple approaches.

import AVFoundation
import CoreAudio
import Foundation

print("=== Microphone permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3=authorized) ===")

// MARK: - Approach 1: AVAudioEngine with default device (no device override)

print("\n=== Approach 1: AVAudioEngine (system default device, no override) ===")
do {
    let engine = AVAudioEngine()
    let format = engine.inputNode.outputFormat(forBus: 0)
    print("Default input format: \(format.sampleRate)Hz, \(format.channelCount)ch")

    var samples1: [Float] = []
    let lock1 = NSLock()

    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        let s = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        lock1.lock()
        samples1.append(contentsOf: s)
        lock1.unlock()
    }

    engine.prepare()
    try engine.start()
    print("🎤 Recording 2s (default device)...")
    Thread.sleep(forTimeInterval: 2.0)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    lock1.lock()
    let max1 = samples1.map { abs($0) }.max() ?? 0
    lock1.unlock()
    print("Samples: \(samples1.count), max amplitude: \(String(format: "%.6f", max1))")
    print(max1 > 0.001 ? "✅ Has signal" : "❌ Silence")
}

// MARK: - Approach 2: AVCaptureSession

print("\n=== Approach 2: AVCaptureSession ===")
do {
    class AudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
        var sampleCount = 0
        var maxAmp: Float = 0

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
            var length = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

            guard let ptr = dataPointer else { return }
            let floatCount = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(ptr).bindMemory(to: Float.self, capacity: floatCount)
            for i in 0..<floatCount {
                let v = abs(floatPtr[i])
                if v > maxAmp { maxAmp = v }
            }
            sampleCount += floatCount
        }
    }

    let session = AVCaptureSession()
    guard let mic = AVCaptureDevice.default(for: .audio),
          let input = try? AVCaptureDeviceInput(device: mic) else {
        print("❌ No default audio device")
        exit(1)
    }

    print("Using device: \(mic.localizedName)")
    session.addInput(input)

    let output = AVCaptureAudioDataOutput()
    let delegate = AudioDelegate()
    let queue = DispatchQueue(label: "audio")
    output.setSampleBufferDelegate(delegate, queue: queue)
    session.addOutput(output)

    session.startRunning()
    print("🎤 Recording 2s (AVCaptureSession)...")
    Thread.sleep(forTimeInterval: 2.0)
    session.stopRunning()

    print("Samples: \(delegate.sampleCount), max amplitude: \(String(format: "%.6f", delegate.maxAmp))")
    print(delegate.maxAmp > 0.001 ? "✅ Has signal" : "❌ Silence")
}

// MARK: - Approach 3: AVAudioEngine with explicit built-in mic

print("\n=== Approach 3: AVAudioEngine with explicit BuiltIn mic ===")
do {
    let engine = AVAudioEngine()

    // Find and set built-in mic
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)

    var builtInID: AudioDeviceID?
    for id in ids {
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var us = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &us, &uid)
        if (uid as String).contains("BuiltIn") {
            builtInID = id
            print("Found built-in mic: device ID \(id)")
            break
        }
    }

    if let devID = builtInID {
        // Set device BEFORE accessing inputNode
        let au = engine.inputNode.audioUnit!
        var devIDVar = devID
        let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &devIDVar, UInt32(MemoryLayout<AudioDeviceID>.size))
        print("Set device result: \(status) (0=success)")

        // Re-read format after device change
        let format = engine.inputNode.outputFormat(forBus: 0)
        print("Format after device set: \(format.sampleRate)Hz, \(format.channelCount)ch")
    }

    var samples3: [Float] = []
    let lock3 = NSLock()

    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        let s = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        lock3.lock()
        samples3.append(contentsOf: s)
        lock3.unlock()
    }

    engine.prepare()
    try engine.start()
    print("🎤 Recording 2s (built-in mic)...")
    Thread.sleep(forTimeInterval: 2.0)
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    lock3.lock()
    let max3 = samples3.map { abs($0) }.max() ?? 0
    lock3.unlock()
    print("Samples: \(samples3.count), max amplitude: \(String(format: "%.6f", max3))")
    if max3 > 0.001 {
        print("✅ Has signal — saving to /tmp/parakatt_test.raw")
        // Downsample to 16kHz if needed
        var output = samples3
        if engine.inputNode.outputFormat(forBus: 0).sampleRate != 16000 {
            let ratio = Int(engine.inputNode.outputFormat(forBus: 0).sampleRate / 16000)
            output = stride(from: 0, to: samples3.count, by: ratio).map { samples3[$0] }
            print("Downsampled \(ratio)x → \(output.count) samples at 16kHz")
        }
        let data = Data(bytes: output, count: output.count * MemoryLayout<Float>.size)
        try! data.write(to: URL(fileURLWithPath: "/tmp/parakatt_test.raw"))
        print("Saved! Now run: cargo run --example test_audio_file -p parakatt-core")
    } else {
        print("❌ Silence")
    }
}

print("\n=== ALL TESTS DONE ===")
