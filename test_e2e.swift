#!/usr/bin/swift
import AVFoundation
import Foundation

print("=== Audio Input Devices ===")

// List all audio devices
let devices = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.microphone, .builtInMicrophone, .externalUnknown],
    mediaType: .audio,
    position: .unspecified
).devices

for (i, device) in devices.enumerated() {
    let isDefault = (device.uniqueID == AVCaptureDevice.default(for: .audio)?.uniqueID)
    print("[\(i)] \(device.localizedName) (id: \(device.uniqueID))\(isDefault ? " ← DEFAULT" : "")")
}

if devices.isEmpty {
    print("❌ No audio input devices found!")
    exit(1)
}

print("\n=== Default Input Device Details ===")
let engine = AVAudioEngine()
let inputNode = engine.inputNode
let hwFormat = inputNode.outputFormat(forBus: 0)
let inputFormat = inputNode.inputFormat(forBus: 0)

print("Output format: \(hwFormat)")
print("Input format:  \(inputFormat)")
print("Sample rate: \(hwFormat.sampleRate)")
print("Channels: \(hwFormat.channelCount)")
print("Common format: \(hwFormat.commonFormat.rawValue) (1=float32, 2=float64, 3=int16, 4=int32)")
print("Interleaved: \(hwFormat.isInterleaved)")

print("\n=== Recording Test (2 seconds, native format) ===")

var tapCallCount = 0
var totalFrames = 0
var maxVal: Float = 0

// Try capturing in the INPUT format instead of output format
inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
    tapCallCount += 1
    let count = Int(buffer.frameLength)
    totalFrames += count

    if let data = buffer.floatChannelData {
        for i in 0..<count {
            let v = abs(data[0][i])
            if v > maxVal { maxVal = v }
        }
    }

    if tapCallCount <= 3 {
        print("  tap #\(tapCallCount): \(count) frames, format: \(buffer.format.sampleRate)Hz \(buffer.format.channelCount)ch")
    }
}

engine.prepare()
do {
    try engine.start()
    print("🎤 Recording... speak now!")
} catch {
    print("❌ Engine start failed: \(error)")
    exit(1)
}

Thread.sleep(forTimeInterval: 2.0)

inputNode.removeTap(onBus: 0)
engine.stop()

print("Tap called \(tapCallCount) times, \(totalFrames) total frames")
print("Max amplitude: \(String(format: "%.6f", maxVal))")

if maxVal > 0.01 {
    print("✅ AUDIO IS WORKING")
} else {
    print("❌ Still silence. Check: System Settings > Sound > Input — is the right mic selected and volume up?")
}

print("\n=== DONE ===")
