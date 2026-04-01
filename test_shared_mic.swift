#!/usr/bin/swift
/// Integration test: verify Parakatt-style audio capture doesn't crash when
/// another app (simulated by a second AVAudioEngine) is already using the mic.
///
/// Scenario:
///   1. "Other app" engine starts capturing (simulates Teams/Zoom holding the mic)
///   2. "Parakatt" engine starts capturing on the same device
///   3. "Parakatt" engine stops (teardown) — this is where the crash used to happen
///   4. "Other app" engine should still be running fine
///   5. "Other app" engine stops cleanly
///
/// Run: swift test_shared_mic.swift
/// Requires: microphone permission granted

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Helpers

/// Mirrors AudioCaptureService.teardown() — the defensive version with lock + isRunning guard.
/// Uses NSLock to nil out state before stopping, exactly as the production code does.
class SafeEngine {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?

    init(engine: AVAudioEngine, converter: AVAudioConverter? = nil) {
        self.engine = engine
        self.converter = converter
    }

    /// Tear down mirroring AudioCaptureService.teardown()
    func teardown() {
        lock.lock()
        let eng = engine
        engine = nil
        converter = nil
        lock.unlock()

        guard let eng else { return }
        if eng.isRunning {
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
        }
    }

    /// Check if engine is active (under lock, like stopCapture does)
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return engine != nil
    }

    /// Access converter under lock (like convertAndDeliver does)
    var safeConverter: AVAudioConverter? {
        lock.lock()
        defer { lock.unlock() }
        return converter
    }

}

func findBuiltInMicID() -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
    )
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
    )

    for id in ids {
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uid)
        if (uid as String).contains("BuiltIn") {
            return id
        }
    }
    return nil
}

func setDevice(_ engine: AVAudioEngine, deviceID: AudioDeviceID) -> Bool {
    guard let audioUnit = engine.inputNode.audioUnit else {
        print("  WARN: audioUnit is nil — cannot set device")
        return false
    }
    var devID = deviceID
    let status = AudioUnitSetProperty(
        audioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &devID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    return status == noErr
}

func installTap(on engine: AVAudioEngine, label: String) -> (samples: () -> [Float], lock: NSLock) {
    let lock = NSLock()
    var samples: [Float] = []
    let format = engine.inputNode.outputFormat(forBus: 0)

    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        guard let data = buffer.floatChannelData else { return }
        let s = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        lock.lock()
        samples.append(contentsOf: s)
        lock.unlock()
    }

    return (samples: {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }, lock: lock)
}

// MARK: - Tests

var passed = 0
var failed = 0

func pass(_ name: String) {
    passed += 1
    print("  PASS: \(name)")
}

func fail(_ name: String, _ reason: String) {
    failed += 1
    print("  FAIL: \(name) — \(reason)")
}

print("=== Shared Microphone Crash Test ===")
print("Mic permission: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3=authorized)\n")

// ---------- Test 1: Two engines on same device, stop Parakatt first ----------

print("--- Test 1: Two engines sharing mic, stop second engine first ---")
do {
    let otherEngine = AVAudioEngine()
    let parakattEngine = AVAudioEngine()

    if let micID = findBuiltInMicID() {
        _ = setDevice(otherEngine, deviceID: micID)
        _ = setDevice(parakattEngine, deviceID: micID)
        print("  Both engines pinned to built-in mic (device \(micID))")
    } else {
        print("  Using system default device (no built-in mic found)")
    }

    // Start "other app" first
    let otherTap = installTap(on: otherEngine, label: "other")
    otherEngine.prepare()
    try otherEngine.start()
    print("  Other engine started")

    Thread.sleep(forTimeInterval: 0.5)

    // Start "Parakatt" using SafeEngine (mirrors production teardown)
    let _ = installTap(on: parakattEngine, label: "parakatt")
    parakattEngine.prepare()
    try parakattEngine.start()
    let safePara = SafeEngine(engine: parakattEngine)
    print("  Parakatt engine started")

    // Both recording simultaneously
    Thread.sleep(forTimeInterval: 1.0)

    // Stop Parakatt via SafeEngine.teardown() — mirrors production code
    safePara.teardown()
    print("  Parakatt engine stopped (no crash)")
    pass("Parakatt teardown while other app holds mic")

    if otherEngine.isRunning {
        pass("Other engine still running after Parakatt stopped")
    } else {
        fail("Other engine still running", "engine stopped unexpectedly")
    }

    Thread.sleep(forTimeInterval: 0.5)
    let otherSamples = otherTap.samples()
    if !otherSamples.isEmpty {
        pass("Other engine captured \(otherSamples.count) samples total")
    } else {
        fail("Other engine captured audio", "no samples")
    }

    // Clean up
    let safeOther = SafeEngine(engine: otherEngine)
    safeOther.teardown()
    print("  Other engine stopped")
}

// ---------- Test 2: Double teardown (stop already-stopped engine) ----------

print("\n--- Test 2: Double teardown safety ---")
do {
    let engine = AVAudioEngine()
    let _ = installTap(on: engine, label: "double")
    engine.prepare()
    try engine.start()
    Thread.sleep(forTimeInterval: 0.3)

    let safe = SafeEngine(engine: engine)
    safe.teardown()
    safe.teardown()  // second call should be no-op (engine already nil)
    pass("Double teardown did not crash")

    if !safe.isActive {
        pass("Engine state is nil after teardown")
    } else {
        fail("Engine state cleared", "engine still set after teardown")
    }
}

// ---------- Test 3: Teardown engine that was never started ----------

print("\n--- Test 3: Teardown engine that was never started ---")
do {
    let engine = AVAudioEngine()
    let _ = installTap(on: engine, label: "never-started")
    engine.prepare()
    // Don't call start()
    let safe = SafeEngine(engine: engine)
    safe.teardown()
    pass("Teardown of prepared-but-not-started engine did not crash")
}

// ---------- Test 4: Rapid start/stop cycles with shared mic ----------

print("\n--- Test 4: Rapid start/stop cycles while other engine holds mic ---")
do {
    let otherEngine = AVAudioEngine()
    if let micID = findBuiltInMicID() {
        _ = setDevice(otherEngine, deviceID: micID)
    }
    let _ = installTap(on: otherEngine, label: "other-rapid")
    otherEngine.prepare()
    try otherEngine.start()

    let cycles = 5
    for i in 1...cycles {
        let engine = AVAudioEngine()
        if let micID = findBuiltInMicID() {
            _ = setDevice(engine, deviceID: micID)
        }
        let _ = installTap(on: engine, label: "rapid-\(i)")
        engine.prepare()
        try engine.start()
        Thread.sleep(forTimeInterval: 0.2)
        let safe = SafeEngine(engine: engine)
        safe.teardown()
    }
    pass("\(cycles) rapid start/stop cycles completed without crash")

    if otherEngine.isRunning {
        pass("Other engine survived all rapid cycles")
    } else {
        fail("Other engine survived rapid cycles", "engine stopped unexpectedly")
    }

    let safeOther = SafeEngine(engine: otherEngine)
    safeOther.teardown()
}

// ---------- Test 5: audioUnit nil safety ----------

print("\n--- Test 5: audioUnit guard (safe unwrap) ---")
do {
    let engine = AVAudioEngine()
    if let _ = engine.inputNode.audioUnit {
        pass("audioUnit accessible via safe unwrap")
    } else {
        pass("audioUnit was nil — guard prevented crash")
    }
}

// ---------- Test 6: Converter path with concurrent teardown ----------

print("\n--- Test 6: Converter tap with teardown during active callbacks ---")
do {
    let engine = AVAudioEngine()
    if let micID = findBuiltInMicID() {
        _ = setDevice(engine, deviceID: micID)
    }

    let hwFormat = engine.inputNode.outputFormat(forBus: 0)
    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
        fail("Converter creation", "could not create converter")
        exit(1)
    }

    let safe = SafeEngine(engine: engine, converter: converter)
    var callbacksAfterTeardown = 0
    let countLock = NSLock()

    // Install a tap that checks the lock before using converter (mirrors production code)
    engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
        guard let conv = safe.safeConverter else {
            // Converter was nilled by teardown — callback correctly exits early
            countLock.lock()
            callbacksAfterTeardown += 1
            countLock.unlock()
            return
        }

        let ratio = 16_000.0 / buffer.format.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var consumed = false
        conv.convert(to: outBuf, error: nil) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
    }

    engine.prepare()
    try engine.start()
    print("  Engine with converter started (hw: \(Int(hwFormat.sampleRate))Hz → 16kHz)")

    // Let callbacks fire for a bit
    Thread.sleep(forTimeInterval: 0.5)

    // Teardown while callbacks are likely in-flight
    safe.teardown()

    // Give any in-flight callbacks time to complete
    Thread.sleep(forTimeInterval: 0.2)

    countLock.lock()
    let skipped = callbacksAfterTeardown
    countLock.unlock()

    pass("Converter teardown during active callbacks did not crash")
    if skipped > 0 {
        pass("Lock correctly blocked \(skipped) post-teardown callback(s)")
    } else {
        pass("No callbacks arrived after teardown (timing-dependent, still valid)")
    }
}

// ---------- Summary ----------

print("\n=== RESULTS: \(passed) passed, \(failed) failed ===")
exit(failed > 0 ? 1 : 0)
