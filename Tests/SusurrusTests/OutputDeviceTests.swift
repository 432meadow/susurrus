import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import Susurrus

/// A real output device that can come and go: a private aggregate over the default output, which
/// only this process can see and which goes when it does. (Moving the system's default output for
/// real would move the whole Mac's sound, so tests stand in for that through `systemDefault`.)
@MainActor
final class TemporaryOutputDevice {
    let uid = "susurrus.tests.\(UUID().uuidString)"
    private(set) var id: AudioDeviceID = 0
    private let subDeviceUID: String

    init() throws {
        let system = try #require(OutputDevices.defaultOutputDeviceID())
        subDeviceUID = try #require(OutputDevices().devices.first { $0.id == system }?.uid)
        try add()
    }

    func add() throws {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "susurrus tests",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: subDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: subDeviceUID]],
        ]
        var device = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &device)
        try #require(status == noErr, "creating a temporary output device: \(status)")
        id = device
    }

    func remove() {
        AudioHardwareDestroyAggregateDevice(id)
    }
}

/// The output choice, on real engines at zero volume.
@MainActor
@Suite(.serialized) struct OutputDeviceTests {
    private static let savedChoice = "player.outputDeviceUID"
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func makePlayer() -> Player {
        let player = Player(files: PlaybackFileCache(directory: folder.appendingPathComponent("cache-\(UUID().uuidString)")))
        player.volume = 0
        player.repeatMode = .off
        player.setShuffle(false)
        return player
    }

    /// Picks a device without leaving the choice in the defaults, where a player another suite makes
    /// would find it. Nothing else on the main actor can run in between.
    private func choose(_ uid: String?, on player: Player) {
        player.setOutputDevice(uid)
        UserDefaults.standard.removeObject(forKey: Self.savedChoice)
    }

    private func tone(_ id: Int64, seconds: Double) async throws -> Track {
        let url = folder.appendingPathComponent("\(id).wav")
        try await ToneFile.make(at: url, seconds: seconds, frequency: 220)
        let track = Track(id: id)
        track.path = url.path
        return track
    }

    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func isCarryingOn(_ player: Player) async -> Bool {
        let position = player.currentTime
        return await waitUntil { player.isEngineRunning && player.isPlaying && player.currentTime > position + 0.2 }
    }

    // MARK: The system output

    @Test func theSystemOutputFollowsTheDefaultAfterADeviceHasBeenPicked() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let player = makePlayer()
        let system = try #require(OutputDevices.defaultOutputDeviceID())
        // Picking anything used to pin the engine, so that going back to the system output stayed
        // on whatever was the default at that moment.
        choose(device.uid, on: player)
        #expect(player.outputDevice == device.id)
        choose(nil, on: player)
        #expect(player.outputDevice == system)

        player.play([try await tone(80, seconds: 20)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.3 })
        player.outputs.systemDefault = { device.id }
        player.outputs.onChange?()
        #expect(player.outputDevice == device.id, "moves when the default does")
        #expect(player.outputDeviceUID == nil, "and that's still the system output")
        #expect(await isCarryingOn(player))
        #expect(player.currentTime > 0.3, "from where it was")

        player.outputs.systemDefault = { system }
        player.outputs.onChange?()
        #expect(player.outputDevice == system)
        #expect(await isCarryingOn(player))
        player.stop()
    }

    @Test func aChosenDeviceIgnoresTheDefault() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let player = makePlayer()
        choose(device.uid, on: player)
        player.outputs.systemDefault = { 0 }
        player.outputs.onChange?()
        #expect(player.outputDevice == device.id)
        #expect(player.outputDeviceUID == device.uid)
        player.stop()
    }

    @Test func theDefaultMovingWhileIdleStartsNothing() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let player = makePlayer()
        player.restore([try await tone(81, seconds: 2)], index: 0, position: 0.5)
        player.outputs.systemDefault = { device.id }
        player.outputs.onChange?()
        #expect(player.outputDevice == device.id)
        #expect(!player.isEngineRunning && !player.isPlaying)
        #expect(player.currentTime == 0.5)
        player.stop()
    }

    @Test func aDeviceChangeRestartsPlaybackOnce() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let player = makePlayer()
        player.play([try await tone(82, seconds: 20)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.3 })
        var starts = 0
        player.onStartedPlaying = { starts += 1 }
        choose(device.uid, on: player)
        #expect(starts == 1)
        // The engine announces a new device a moment after it's set. Restarting for that as well
        // would be a second dropout.
        try? await Task.sleep(for: .seconds(0.6))
        #expect(starts == 1)
        #expect(await isCarryingOn(player))

        // Choosing what it's already on is nothing at all.
        choose(device.uid, on: player)
        #expect(starts == 1)
        player.stop()
    }

    // MARK: A chosen device going away

    @Test func aChosenDeviceThatGoesAwayFallsBackAndIsPickedUpAgain() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let player = makePlayer()
        #expect(await waitUntil { player.outputs.devices.contains { $0.uid == device.uid } })
        choose(device.uid, on: player)
        #expect(player.outputDeviceUID == device.uid)
        player.play([try await tone(83, seconds: 30)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.5 })

        device.remove()
        #expect(await waitUntil { player.outputDeviceUID == nil }, "the menu's checkmark goes to System Output")
        #expect(await waitUntil { !player.outputs.devices.contains { $0.uid == device.uid } })
        #expect(await isCarryingOn(player))
        #expect(player.errorMessage == nil, "\(player.errorMessage ?? "")")
        #expect(player.outputDevice == OutputDevices.defaultOutputDeviceID())
        #expect(player.currentTime > 0.5, "from where it was")

        try device.add()
        #expect(await waitUntil { player.outputDeviceUID == device.uid }, "it's still the choice")
        #expect(player.outputDevice == device.id)
        #expect(await isCarryingOn(player))

        // Picking the system output while it's away means it stays away.
        device.remove()
        #expect(await waitUntil { player.outputDeviceUID == nil })
        choose(nil, on: player)
        try device.add()
        #expect(await waitUntil { player.outputs.devices.contains { $0.uid == device.uid } })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(player.outputDeviceUID == nil)
        player.stop()
    }

    @Test func aSavedDeviceThatIsntThereAtLaunchWaitsToBeBack() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        device.remove()
        #expect(await waitUntil { OutputDevices.deviceID(forUID: device.uid) == nil })
        UserDefaults.standard.set(device.uid, forKey: Self.savedChoice)
        let player = makePlayer()
        UserDefaults.standard.removeObject(forKey: Self.savedChoice)
        #expect(player.outputDeviceUID == nil, "nothing would be checked in the menu otherwise")
        #expect(player.outputDevice == OutputDevices.defaultOutputDeviceID())

        try device.add()
        #expect(await waitUntil { player.outputDeviceUID == device.uid })
        #expect(player.outputDevice == device.id)
    }

    @Test func theChoiceIsSavedWhileTheDeviceIsAway() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let player = makePlayer()
        player.setOutputDevice(device.uid)
        let saved = UserDefaults.standard.string(forKey: Self.savedChoice)
        UserDefaults.standard.removeObject(forKey: Self.savedChoice)
        #expect(saved == device.uid)
    }

    /// What's behind "Audio output failed": a device that won't do leaves the engine with none at
    /// all, and it won't start until it has one.
    @Test func anEngineLeftWithoutADeviceRecovers() async throws {
        let player = makePlayer()
        player.play([try await tone(84, seconds: 20)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.3 })
        let engine = try #require(player.equalizer.unit.engine)
        engine.stop()
        #expect(!engine.setOutputDevice(99_999))
        #expect(engine.outputDevice == nil)
        #expect(throws: (any Error).self) { try engine.start() }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(await waitUntil { player.isEngineRunning && player.isPlaying })
        #expect(player.outputDevice == OutputDevices.defaultOutputDeviceID())
        #expect(await isCarryingOn(player))
        player.stop()
    }

    @Test func playbackPicksUpWhenAWorkingDeviceTurnsUpSoonAfter() async throws {
        let player = makePlayer()
        player.play([try await tone(85, seconds: 20)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.3 })
        let system = try #require(OutputDevices.defaultOutputDeviceID())

        // No device anywhere for a moment, as when the last one is unplugged.
        player.outputs.systemDefault = { nil }
        let engine = try #require(player.equalizer.unit.engine)
        engine.stop()
        engine.setOutputDevice(99_999)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(await waitUntil { !player.isPlaying })
        #expect(player.errorMessage?.hasPrefix("Audio output failed") == true, "\(player.errorMessage ?? "")")

        player.outputs.systemDefault = { system }
        player.outputs.onChange?()
        #expect(await waitUntil { player.isPlaying && player.isEngineRunning })
        #expect(player.errorMessage == nil, "\(player.errorMessage ?? "")")
        #expect(await isCarryingOn(player))
        player.stop()
    }

    // MARK: The mixer

    /// A whole `AppModel`, since it's what ties the mixer's output to the queue player's.
    private func makeModel() -> AppModel {
        let model = AppModel(libraryURL: folder.appendingPathComponent("Library.sqlite"))
        model.player.volume = 0
        model.mixer.masterVolume = 0
        return model
    }

    @Test func theMixerFollowsAndALiveMixCarriesOn() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let model = makeModel()
        var ready = false
        model.mixer.load(try await tone(90, seconds: 30), on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        let deck = model.mixer.a
        let engine = try #require(deck.node.engine)
        let system = try #require(OutputDevices.defaultOutputDeviceID())
        deck.play()
        #expect(await waitUntil { deck.currentTime > 0.3 })

        func isCarryingOn() async -> Bool {
            let position = deck.currentTime
            return await waitUntil { engine.isRunning && deck.isPlaying && deck.currentTime > position + 0.2 }
        }

        choose(device.uid, on: model.player)
        #expect(engine.outputDevice == device.id)
        #expect(await isCarryingOn())

        // Going away, then the system's default moving: it goes wherever the player goes.
        device.remove()
        #expect(await waitUntil { model.player.outputDeviceUID == nil })
        #expect(await waitUntil { engine.outputDevice == system })
        #expect(await isCarryingOn())
        #expect(deck.currentTime > 0.3)

        try device.add()
        #expect(await waitUntil { engine.outputDevice == device.id })
        #expect(await isCarryingOn())
        choose(nil, on: model.player)
        #expect(engine.outputDevice == system)
        model.player.outputs.systemDefault = { device.id }
        model.player.outputs.onChange?()
        #expect(engine.outputDevice == device.id)
        #expect(await isCarryingOn())
        deck.eject()
    }

    @Test func aMixerSetUpLaterStartsOnTheCurrentOutput() async throws {
        let device = try TemporaryOutputDevice()
        defer { device.remove() }
        let model = makeModel()
        choose(device.uid, on: model.player)
        var ready = false
        model.mixer.load(try await tone(91, seconds: 2), on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        #expect(model.mixer.a.node.engine?.outputDevice == device.id)
        model.mixer.a.eject()
        choose(nil, on: model.player)
    }
}
