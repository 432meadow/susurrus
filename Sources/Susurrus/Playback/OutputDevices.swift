import AVFoundation
import CoreAudio
import Foundation
import ObjCSupport
import Observation

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// The Mac's audio output devices (speakers, interfaces, AirPlay, Bluetooth), kept current as
/// devices come and go and the system's default output moves.
@MainActor
@Observable
final class OutputDevices {
    private(set) var devices: [AudioOutputDevice] = []

    /// The system's default output right now. Tests stand in for it: moving the real one would move
    /// the whole Mac's sound.
    @ObservationIgnored var systemDefault: () -> AudioDeviceID? = { OutputDevices.defaultOutputDeviceID() }
    /// Called when a device comes or goes, or the system's default output moves.
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        refresh()
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    self?.onChange?()
                }
            }
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
        return status == noErr && device != kAudioObjectUnknown ? device : nil
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
    /// The device it's playing through: nil if it has none (a device it was given wouldn't do).
    var outputDevice: AudioDeviceID? {
        guard let unit = outputNode.audioUnit else { return nil }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    /// Plays through `device` instead of whatever it's on. Once set, the engine no longer follows
    /// the system output by itself. False if the device won't do: the engine is then left without
    /// one, and won't start until it's given another.
    @discardableResult
    func setOutputDevice(_ device: AudioDeviceID) -> Bool {
        guard let unit = outputNode.audioUnit else { return false }
        var device = device
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// Calls `handler` whenever the output device or its format changes (headphones unplugged, an
    /// AirPlay or Bluetooth switch, a new sample rate). The engine has stopped itself by then, and
    /// its nodes' clocks have stopped with it.
    func onConfigurationChange(_ handler: @escaping @MainActor @Sendable () -> Void) {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: self, queue: .main) { notification in
            // Setting a device announces itself this way too, a moment later. If the engine has
            // been started on it since, there's nothing left to do.
            guard (notification.object as? AVAudioEngine)?.isRunning != true else { return }
            MainActor.assumeIsolated { handler() }
        }
    }

    /// `connect(_:to:format:)`, throwing what the engine said if it refuses (it raises an
    /// NSException, caught in ObjC). It can only change formats ahead of a mixer while running.
    func connectChecked(_ from: AVAudioNode, to: AVAudioNode, format: AVAudioFormat) throws {
        var error: NSError?
        guard MMConnectNodes(self, from, to, format, &error) else {
            throw error ?? CocoaError(.featureUnsupported)
        }
    }

    /// `connectChecked`, but if a running engine refuses, this logs why, stops it and tries again:
    /// a track that won't connect is skipped, and starting the engine again costs a moment.
    func connectStoppingIfRefused(_ from: AVAudioNode, to: AVAudioNode, format: AVAudioFormat) throws {
        do {
            try connectChecked(from, to: to, format: format)
        } catch {
            guard isRunning else { throw error }
            EventLog.shared.log("Audio engine refused \(format) while running, restarting it: \(error.localizedDescription)")
            stop()
            try connectChecked(from, to: to, format: format)
        }
    }
}
