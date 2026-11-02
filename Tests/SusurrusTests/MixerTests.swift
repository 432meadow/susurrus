import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// Plays real (generated) audio through the mixer's engine at zero volume.
@MainActor
@Suite(.serialized) struct MixerTests {
    let folder: URL
    let tracks: [Track]

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder
        tracks = try (1...2).map { try Self.tone(Int64($0), seconds: 1.0, in: folder) }
    }

    /// A track whose file is a generated tone `seconds` long.
    private static func tone(_ id: Int64, seconds: Double, in folder: URL) throws -> Track {
        let url = folder.appendingPathComponent("\(id).wav")
        try ToneFile.write(to: url, seconds: seconds, frequency: 220 * Double(id))
        let track = Track(id: id)
        track.title = "Tone \(id)"
        track.path = url.path
        track.length = seconds
        return track
    }

    /// A mixer with a file cache of its own (other suites play other files under the same track ids).
    private func makeMixer() -> Mixer {
        let mixer = Mixer(files: PlaybackFileCache(directory: folder.appendingPathComponent("cache-\(UUID().uuidString)")))
        mixer.masterVolume = 0
        return mixer
    }

    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    @Test func crossfaderKeepsPowerConstant() {
        #expect(Mixer.crossfadeGains(0) == (1, 0))
        let end = Mixer.crossfadeGains(1)
        #expect(abs(end.a) < 0.0001 && end.b == 1)
        for position in stride(from: 0.0, through: 1.0, by: 0.1) {
            let (a, b) = Mixer.crossfadeGains(position)
            #expect(abs(a * a + b * b - 1) < 0.0001)
        }
        let middle = Mixer.crossfadeGains(0.5)
        #expect(abs(middle.a - middle.b) < 0.0001)
    }

    @Test func eqKnobRunsFromBoostToKill() {
        #expect(Deck.eqGain(0) == 0)
        #expect(Deck.eqGain(1) == 6)
        #expect(Deck.eqGain(-1) == -40)
        #expect(Deck.eqGain(-0.5) > -15, "gentle near the middle")
    }

    @Test func deckPlaysToTheEndAndStops() async {
        let mixer = makeMixer()
        var started = 0
        mixer.onStartedPlaying = { started += 1 }
        var ready = false
        mixer.load(tracks[0], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        #expect(mixer.a.track?.id == 1)
        #expect(abs(mixer.a.duration - 1) < 0.01)

        mixer.a.play()
        #expect(mixer.a.isPlaying)
        #expect(started == 1, "tells the queue player to pause")
        #expect(await waitUntil { mixer.a.currentTime > 0.2 })
        #expect(await waitUntil { !mixer.a.isPlaying }, "stops at the end")
        #expect(abs(mixer.a.currentTime - 1) < 0.01)
        #expect(!mixer.b.isPlaying)
    }

    @Test func cueSetsAndReturns() async {
        let mixer = makeMixer()
        var ready = false
        mixer.load(tracks[0], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        let deck = mixer.a

        deck.seek(to: 0.4)
        deck.cue()  // paused: the cue point moves here
        #expect(abs(deck.cuePoint - 0.4) < 0.001)
        deck.play()
        #expect(await waitUntil { deck.currentTime > 0.6 })
        deck.cue()  // playing: back to the cue point, paused
        #expect(!deck.isPlaying)
        #expect(abs(deck.currentTime - 0.4) < 0.001)
        deck.eject()
        #expect(deck.track == nil && !deck.isReady)
    }

    @Test func matchTempoFindsTheNearestMultiple() async {
        let mixer = makeMixer()
        tracks[0].bpm = 126
        tracks[1].bpm = 120
        var loaded = 0
        mixer.load(tracks[0], on: .a) { _ in loaded += 1 }
        mixer.load(tracks[1], on: .b) { _ in loaded += 1 }
        #expect(await waitUntil { loaded == 2 })

        mixer.b.matchTempo(to: mixer.a)
        #expect(abs(mixer.b.tempo - 0.05) < 0.0001)
        #expect(abs((mixer.b.effectiveBPM ?? 0) - 126) < 0.001)

        // Half-time: 64 BPM matches 126 by playing at 63.
        tracks[1].bpm = 64
        mixer.b.tempo = 0
        mixer.b.matchTempo(to: mixer.a)
        #expect(abs(mixer.b.tempo - (63.0 / 64 - 1)) < 0.0001)

        // Out of the ±8% range: no match.
        tracks[1].bpm = 100
        #expect(mixer.b.tempoMatching(mixer.a) == nil)
    }

    @Test func autoFadeGlidesAcrossAndStartsTheIncomingDeck() async {
        let mixer = makeMixer()
        mixer.autoFadeSeconds = 0.3
        var ready = false
        mixer.load(tracks[1], on: .b) { _ in ready = true }
        #expect(await waitUntil { ready })
        mixer.moveCrossfader(to: 0)

        mixer.autoFade()
        #expect(mixer.b.isPlaying, "the incoming deck starts")
        #expect(await waitUntil { !mixer.isAutoFading })
        #expect(mixer.crossfader == 1)
        mixer.pauseAll()
        mixer.autoFadeSeconds = 8
    }

    @Test func deckListensAreRecordedWithoutSkips() async {
        let mixer = makeMixer()
        var listens: [(Int64, ListenRecord)] = []
        mixer.onListenEnded = { listens.append(($0.id, $1)) }
        var ready = false
        mixer.load(tracks[0], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })

        // A short audition, then something else on the deck: too short to keep.
        mixer.a.play()
        try? await Task.sleep(for: .milliseconds(300))
        ready = false
        mixer.load(tracks[1], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        #expect(listens.isEmpty)

        // Played to the end: a finished listen of about a second, ended by the next load.
        mixer.a.play()
        #expect(await waitUntil { !mixer.a.isPlaying })
        mixer.a.eject()
        #expect(listens.count == 1)
        #expect(listens.first?.0 == 2)
        #expect(listens.first?.1.outcome == .finished)
        #expect(abs((listens.first?.1.seconds ?? 0) - 1) < 0.25)
    }

    @Test func auditioningPastTheMiddleIsntAPlay() async throws {
        let mixer = makeMixer()
        var played: [Int64] = []
        mixer.onTrackPlayed = { played.append($0.id) }
        var listens: [ListenRecord] = []
        mixer.onListenEnded = { listens.append($1) }
        var ready = false
        mixer.load(try Self.tone(5, seconds: 4, in: folder), on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })

        // Clicked into the second half of the waveform and listened for a bit over a second.
        mixer.a.seek(to: 2.5)
        mixer.a.play()
        try? await Task.sleep(for: .seconds(1.2))
        mixer.a.eject()
        #expect(played.isEmpty, "past halfway, but only a second was heard")
        #expect(listens.count == 1 && listens.first?.outcome == .stopped, "an audition, not a finished listen")
    }

    @Test func anOutputChangeCarriesOnWhereTheDeckWas() async throws {
        let mixer = makeMixer()
        var ready = false
        mixer.load(try Self.tone(6, seconds: 3, in: folder), on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        mixer.a.play()
        #expect(await waitUntil { mixer.a.currentTime > 1.2 })
        // What happens when headphones are unplugged: the engine stops itself, then says so.
        let engine = try #require(mixer.a.node.engine)
        engine.stop()
        let position = mixer.a.currentTime
        #expect(position > 0.3, "the position outlives the engine's clock")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)

        #expect(await waitUntil { engine.isRunning })
        #expect(mixer.a.isPlaying)
        #expect(mixer.a.currentTime >= position - 0.01, "carries on rather than going back to where play was pressed")
        mixer.pauseAll()
    }

    @Test func aDeckThatStallsBooksNoListeningTime() async throws {
        let mixer = makeMixer()
        var listens: [ListenRecord] = []
        mixer.onListenEnded = { listens.append($1) }
        let url = folder.appendingPathComponent("7.wav")
        try await ToneFile.make(at: url, seconds: 8)
        let track = Track(id: 7)
        track.path = url.path
        var ready = false
        mixer.load(track, on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        let start = Date()
        mixer.a.play()
        #expect(await waitUntil { mixer.a.currentTime > 0.5 })
        let engine = try #require(mixer.a.node.engine)
        engine.pause()
        let stalled = Date()
        try? await Task.sleep(for: .seconds(1.5))
        let stall = Date().timeIntervalSince(stalled)
        try engine.start()
        try? await Task.sleep(for: .seconds(1))
        mixer.a.eject()
        let played = Date().timeIntervalSince(start) - stall
        let seconds = listens.first?.seconds ?? 0
        #expect(seconds > 1)
        // At most the update that sees the output come back can take in a tick's worth of the stall.
        #expect(seconds <= played + 0.5, "\(seconds)s counted of \(played)s played; the \(stall)s stall shouldn't be")
    }
}

/// What used to skip tracks: the EQ straight after the player node, as it was.
@Suite(.serialized) struct EngineConnectionTests {
    private let cd = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private let other = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!

    private func runningEngine() throws -> (AVAudioEngine, AVAudioPlayerNode, AVAudioUnitEQ) {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 10)
        engine.attach(node)
        engine.attach(eq)
        engine.mainMixerNode.outputVolume = 0
        try engine.connectChecked(node, to: eq, format: cd)
        try engine.connectChecked(eq, to: engine.mainMixerNode, format: cd)
        try engine.start()
        return (engine, node, eq)
    }

    @Test func aRefusalComesBackInTheEnginesOwnWords() {
        // Asking outright, with a node it doesn't have, since nothing playable is refused any more.
        let engine = AVAudioEngine()
        #expect {
            try engine.connectChecked(AVAudioPlayerNode(), to: engine.mainMixerNode, format: cd)
        } throws: { error in
            error.localizedDescription.contains("required condition")
        }
    }

    @Test func aRunningEngineWontChangeTheFormatOfAnEffect() throws {
        let (engine, node, eq) = try runningEngine()
        defer { engine.stop() }
        engine.disconnectNodeOutput(node)
        #expect(throws: (any Error).self) { try engine.connectChecked(node, to: eq, format: other) }
        #expect(engine.isRunning, "and carries on: it was only the connection that failed")
    }

    @Test func stoppingItIsWhatLetsItThrough() throws {
        let (engine, node, eq) = try runningEngine()
        defer { engine.stop() }
        engine.disconnectNodeOutput(node)
        try engine.connectStoppingIfRefused(node, to: eq, format: other)
        #expect(!engine.isRunning)
        engine.disconnectNodeOutput(eq)
        try engine.connectChecked(eq, to: engine.mainMixerNode, format: other)
        try engine.start()
    }

    @Test func aMixerAheadOfItTakesAnyFormatWhileRunning() throws {
        let engine = AVAudioEngine(), node = AVAudioPlayerNode(), input = AVAudioMixerNode(), eq = AVAudioUnitEQ(numberOfBands: 10)
        for attached in [node, input, eq] { engine.attach(attached) }
        engine.mainMixerNode.outputVolume = 0
        try engine.connectChecked(node, to: input, format: cd)
        try engine.connectChecked(input, to: eq, format: cd)
        try engine.connectChecked(eq, to: engine.mainMixerNode, format: cd)
        try engine.start()
        defer { engine.stop() }
        for rate in [48_000.0, 96_000, 22_050] {
            engine.disconnectNodeOutput(node)
            try engine.connectChecked(node, to: input, format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!)
            #expect(engine.isRunning)
        }
    }
}
