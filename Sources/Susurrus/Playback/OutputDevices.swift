import AVFoundation
import CoreAudio
import Foundation
import Observation

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// The Mac's audio output devices (speakers, interfaces, AirPlay, Bluetooth), kept current as
/// devices come and go.
@MainActor
@Observable
final class OutputDevices {
    private(set) var devices: [AudioOutputDevice] = []

    init() {
        refresh()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        devices = Self.allDeviceIDs().compactMap { id in
            guard Self.hasOutput(id), let uid = Self.string(id, kAudioDevicePropertyDeviceUID),
                  let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    nonisolated static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    nonisolated static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : nil
    }

    private nonisolated static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private nonisolated static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private nonisolated static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// What the queue player's and the mixer's engines share about their output.
extension AVAudioEngine {
    /// Plays through `device` instead of the system output.
    func setOutputDevice(_ device: AudioDeviceID) {
        guard let unit = outputNode.audioUnit else { return }
        var device = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// Calls `handler` whenever the output device or its format changes (headphones unplugged, an
    /// AirPlay or Bluetooth switch, a new sample rate). The engine has stopped itself by then, and
    /// its nodes' clocks have stopped with it.
    func onConfigurationChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: self, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
