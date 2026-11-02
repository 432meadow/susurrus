import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// The queue player and the mixer working as one, in a whole `AppModel` with a throwaway library,
/// on generated audio at zero volume.
@MainActor
@Suite(.serialized) struct LiveMixTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// A model whose library holds a tone `seconds` long for each of `lengths`.
    private func makeModel(lengths: [Double]) async throws -> (AppModel, [Track]) {
        let model = AppModel(libraryURL: folder.appendingPathComponent("Library.sqlite"))
        model.player.volume = 0
        model.player.repeatMode = .off
        model.player.setShuffle(false)
        model.mixer.masterVolume = 0
        let store = try #require(model.store)
        // The model plays through the shared file cache, as other suites do: ids of their own.
        try store.insert((0..<100).map { ScannedTrack(path: "/nonexistent/\($0).wav", title: "") })
        var scanned: [ScannedTrack] = []
        for (number, seconds) in lengths.enumerated() {
            let url = folder.appendingPathComponent("\(number).wav")
            try await ToneFile.make(at: url, seconds: seconds, frequency: 220 * Double(number + 1))
            scanned.append(ScannedTrack(path: url.path, title: "Tone \(number)"))
        }
        try store.insert(scanned)
        try model.reload()
        return (model, try scanned.map { try #require(model.track(atPath: $0.path)) })
    }

    private func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: Continue in Mixer

    @Test func heardHalfInEachPlaceIsOneListenAndOnePlay() async throws {
        let (model, tracks) = try await makeModel(lengths: [4])
        let store = try #require(model.store)
        let player = model.player
        let start = Date()
        player.play(tracks, startingAt: 0)
        // Past half on the player, which counts the play.
        #expect(await waitUntil { player.currentTime > 2.2 })
        model.continueInMixer()
        let deck = model.mixer.a
        #expect(await waitUntil { deck.isPlaying })
        #expect(!player.isPlaying, "the deck takes over")
        // Back to where half of it is still to hear, and past half on the deck too.
        deck.seek(to: 1.5)
        #expect(await waitUntil { deck.currentTime > 3.8 })
        deck.eject()
        let elapsed = Date().timeIntervalSince(start)

        let listens = try store.listens(since: nil)
        #expect(listens.count == 1, "\(listens)")
        let seconds = listens.first?.seconds ?? 0
        #expect(seconds > 4 && seconds <= elapsed, "heard about 4.5 s in \(elapsed) s, counted \(seconds)")
        #expect(try store.plays(since: nil).count == 1)
        player.stop()
    }

    @Test func aPlayCanBeHeardPartlyInEachPlace() async throws {
        let (model, tracks) = try await makeModel(lengths: [8])
        let store = try #require(model.store)
        let player = model.player
        player.play(tracks, startingAt: 0)
        #expect(await waitUntil { player.currentTime > 1.8 })
        model.continueInMixer()
        let deck = model.mixer.a
        #expect(await waitUntil { deck.isPlaying })
        #expect(try store.plays(since: nil).isEmpty, "under half so far")
        // Half in all by 4.2 or so. The deck alone would have to get to about 5.8.
        #expect(await waitUntil { deck.currentTime > 4.2 })
        #expect(await waitUntil(timeout: 1) { (try? store.plays(since: nil).count) == 1 })
        #expect(deck.currentTime < 5.7)
        deck.eject()
        #expect(try store.listens(since: nil).count == 1)
        player.stop()
    }

    @Test func aPausedPlayerHandsOverToo() async throws {
        let (model, tracks) = try await makeModel(lengths: [6])
        let store = try #require(model.store)
        let player = model.player
        player.play(tracks, startingAt: 0)
        #expect(await waitUntil { player.currentTime > 1.2 })
        player.pause()
        let position = player.currentTime
        model.continueInMixer()
        let deck = model.mixer.a
        #expect(await waitUntil { deck.isReady })
        #expect(!deck.isPlaying, "cued where the player stopped, still paused")
        #expect(abs(deck.currentTime - position) < 0.05)
        deck.play()
        try? await Task.sleep(for: .seconds(1.1))
        deck.eject()
        let handedOver = try store.listens(since: nil)
        #expect(handedOver.count == 1)
        #expect((handedOver.first?.seconds ?? 0) > 2.1, "1.2 s on the player and 1.1 on the deck: counted \(handedOver.first?.seconds ?? 0)")

        // Back on the queue player it's a new listen, tracked like any other.
        player.togglePlayPause()
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        try? await Task.sleep(for: .seconds(1.1))
        player.stop()
        let listens = try store.listens(since: nil)
        #expect(listens.count == 2, "\(listens)")
        #expect((listens.last?.seconds ?? 0) > 0.9)
    }

    // MARK: Media keys

    /// `tracks[0]` paused on the queue player, `tracks[1]` playing on deck A.
    private func startMix(_ model: AppModel, _ tracks: [Track]) async throws -> Deck {
        model.player.play([tracks[0]], startingAt: 0)
        #expect(await waitUntil { model.player.isPlaying && !model.player.isLoading })
        var ready = false
        model.mixer.load(tracks[1], on: .a) { _ in ready = true }
        #expect(await waitUntil { ready })
        let deck = model.mixer.a
        deck.play()
        #expect(deck.isPlaying)
        #expect(!model.player.isPlaying, "one or the other")
        return deck
    }

    @Test func playPauseActsOnALiveMix() async throws {
        let (model, tracks) = try await makeModel(lengths: [8, 8])
        let player = model.player
        let deck = try await startMix(model, tracks)
        let center = try #require(player.nowPlaying)
        let queued = player.currentTime
        #expect(await waitUntil { deck.currentTime > 0.3 })
        #expect(center.shown?.track.id == tracks[1].id, "not the paused player's track")
        #expect(center.shown?.isPlaying == true)
        #expect(center.shown?.rate == 1)

        center.togglePlayPause()
        #expect(!deck.isPlaying)
        #expect(!player.isPlaying, "a pause, not a swap to the queue player")
        let position = deck.currentTime
        #expect(center.shown?.track.id == tracks[1].id)
        #expect(center.shown?.isPlaying == false)
        #expect(center.shown?.rate == 0)
        #expect(abs((center.shown?.elapsed ?? 0) - position) < 0.01)

        center.togglePlayPause()
        #expect(deck.isPlaying)
        #expect(!player.isPlaying)
        #expect(await waitUntil { deck.currentTime > position + 0.2 }, "carries on from there")
        #expect(deck.currentTime < position + 2)
        #expect(player.currentTime == queued, "the queue player hasn't moved")
        deck.eject()
        player.stop()
    }

    @Test func nextAndPreviousLeaveALiveMixAlone() async throws {
        let (model, tracks) = try await makeModel(lengths: [8, 8, 8])
        let player = model.player
        let deck = try await startMix(model, tracks)
        player.addToQueue([tracks[2]])
        let center = try #require(player.nowPlaying)

        center.next()
        center.previous()
        #expect(deck.isPlaying)
        #expect(!player.isPlaying)
        #expect(player.currentTrack?.id == tracks[0].id)

        center.seek(to: 3)
        #expect(deck.isPlaying)
        #expect((3...4).contains(deck.currentTime), "seeking goes to the deck, at \(deck.currentTime)")
        deck.eject()
        player.stop()
    }

    @Test func aMixPausedByHandHandsTheKeysBack() async throws {
        let (model, tracks) = try await makeModel(lengths: [8, 8])
        let player = model.player
        let deck = try await startMix(model, tracks)
        let center = try #require(player.nowPlaying)

        deck.pause()
        #expect(center.shown?.track.id == tracks[0].id)
        #expect(center.shown?.isPlaying == false)
        center.togglePlayPause()
        #expect(player.isPlaying)
        #expect(!deck.isPlaying)
        player.stop()
        deck.eject()
    }

    @Test func theQueuePlayerStartingEndsAMediaKeyPause() async throws {
        let (model, tracks) = try await makeModel(lengths: [8, 8])
        let player = model.player
        let deck = try await startMix(model, tracks)
        let center = try #require(player.nowPlaying)

        center.togglePlayPause()
        #expect(!deck.isPlaying)
        // The bar's own Play button.
        player.togglePlayPause()
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        #expect(center.shown?.track.id == tracks[0].id)
        center.togglePlayPause()
        #expect(!player.isPlaying)
        #expect(!deck.isPlaying)
        player.stop()
        deck.eject()
    }

    @Test func bothDecksPauseAndStartTogether() async throws {
        let (model, tracks) = try await makeModel(lengths: [8, 8, 8])
        let player = model.player
        let a = try await startMix(model, tracks)
        var ready = false
        model.mixer.load(tracks[2], on: .b) { _ in ready = true }
        #expect(await waitUntil { ready })
        let b = model.mixer.b
        b.play()
        #expect(await waitUntil { a.currentTime > 0.5 && b.currentTime > 0.3 })
        let center = try #require(player.nowPlaying)

        center.togglePlayPause()
        #expect(!a.isPlaying && !b.isPlaying)
        let apart = a.currentTime - b.currentTime
        center.togglePlayPause()
        #expect(a.isPlaying && b.isPlaying)
        #expect(await waitUntil { a.currentTime > 1 && b.currentTime > 0.8 })
        // Both clocks come off the same engine, so this is how far apart they really play.
        #expect(abs((a.currentTime - b.currentTime) - apart) < 0.03, "a pair that was beat-matched stays so")
        a.eject()
        b.eject()
        player.stop()
    }

    @Test func nowPlayingShowsTheDeckMostInTheMix() async throws {
        let (model, tracks) = try await makeModel(lengths: [8, 8, 8])
        let player = model.player
        let a = try await startMix(model, tracks)
        var ready = false
        model.mixer.load(tracks[2], on: .b) { _ in ready = true }
        #expect(await waitUntil { ready })
        let b = model.mixer.b
        b.play()
        let center = try #require(player.nowPlaying)

        model.mixer.moveCrossfader(to: 0)
        #expect(center.shown?.track.id == tracks[1].id)
        model.mixer.moveCrossfader(to: 1)
        #expect(center.shown?.track.id == tracks[2].id)
        // With its speed, so the widget's clock keeps up.
        b.tempo = 0.04
        #expect(abs((center.shown?.rate ?? 0) - 1.04) < 0.0001)
        b.tempo = 0
        a.eject()
        b.eject()
        player.stop()
    }
}
