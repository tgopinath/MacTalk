import AppKit
import AVFoundation
import CoreAudio
import Foundation

struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// CoreAudio device enumeration and default-device switching.
///
/// WebRTC's macOS audio module opens the system default input/output when a call starts.
/// MacTalk honours the devices chosen in Settings (or in the call window) by making them
/// the default for the duration of the call, then restores the previous defaults.
enum AudioDevices {
    enum Scope { case input, output }

    static func list(_ scope: Scope) -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channelCount(id, scope) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultDevice(_ scope: Scope) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector(scope), mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    static func defaultUID(_ scope: Scope) -> String? {
        defaultDevice(scope).flatMap { string($0, kAudioDevicePropertyDeviceUID) }
    }

    @discardableResult
    static func setDefault(_ scope: Scope, uid: String) -> Bool {
        guard let device = list(scope).first(where: { $0.uid == uid }) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: selector(scope), mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    private static func selector(_ scope: Scope) -> AudioObjectPropertySelector {
        scope == .input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
    }

    private static func channelCount(_ id: AudioDeviceID, _ scope: Scope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope == .input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Applies the user's chosen devices for a call and puts the previous defaults back afterwards.
@MainActor
final class CallAudioRouting {
    private var previousInput: String?
    private var previousOutput: String?

    func apply(inputUID: String?, outputUID: String?) {
        if let inputUID, inputUID != AudioDevices.defaultUID(.input) {
            previousInput = AudioDevices.defaultUID(.input)
            AudioDevices.setDefault(.input, uid: inputUID)
        }
        if let outputUID, outputUID != AudioDevices.defaultUID(.output) {
            previousOutput = AudioDevices.defaultUID(.output)
            AudioDevices.setDefault(.output, uid: outputUID)
        }
    }

    func switchInput(to uid: String) {
        if previousInput == nil { previousInput = AudioDevices.defaultUID(.input) }
        AudioDevices.setDefault(.input, uid: uid)
    }

    func switchOutput(to uid: String) {
        if previousOutput == nil { previousOutput = AudioDevices.defaultUID(.output) }
        AudioDevices.setDefault(.output, uid: uid)
    }

    func restore() {
        if let previousInput { AudioDevices.setDefault(.input, uid: previousInput) }
        if let previousOutput { AudioDevices.setDefault(.output, uid: previousOutput) }
        previousInput = nil; previousOutput = nil
    }
}

enum MicrophonePermission {
    enum State { case granted, denied, notDetermined }

    static var state: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Asks only if macOS hasn't asked yet. Never captures audio.
    static func ensure() async -> Bool {
        switch state {
        case .granted: return true
        case .denied: return false
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Live microphone level for the Settings "Test microphone" meter. Runs only while visible.
@MainActor @Observable
final class InputLevelMeter {
    private(set) var level: Float = 0
    private(set) var isRunning = false
    private var engine: AVAudioEngine?

    func start() {
        guard !isRunning, MicrophonePermission.state == .granted else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(max(buffer.frameLength, 1)))
            let db = 20 * log10(max(rms, 0.000_01))
            let normalized = max(0, min(1, (db + 55) / 50))
            Task { @MainActor in self?.level = normalized }
        }
        do { try engine.start(); self.engine = engine; isRunning = true } catch { input.removeTap(onBus: 0) }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }
}
