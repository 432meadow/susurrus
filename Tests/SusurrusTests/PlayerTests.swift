import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// Plays real (generated) audio through AVAudioEngine at zero volume.
@MainActor
@Suite(.serialized) struct PlayerTests {
    let folder: URL
    let tracks: [Track]

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folder = folder
        tracks = try (1...4).map { try Self.tone(Int64($0), seconds: 1.0, in: folder) }
    }

    /// A track whose file is a generated tone `seconds` long.
    private static func tone(_ id: Int64, seconds: Double, in folder: URL) throws -> Track {
        let url = folder.appendingPathComponent("\(id).wav")
        try ToneFile.write(to: url, seconds: seconds, frequency: 110 * Double(id % 8 + 1))
        let track = Track(id: id)
        track.title = "Tone \(id)"
        track.path = url.path
        track.length = seconds
        return track
    }

    /// A track whose file isn't there.
    private static func missing(_ id: Int64) -> Track {
        let track = Track(id: id)
        track.path = "/nonexistent/\(id).mp3"
        return track
    }

    /// A player with a file cache of its own (other suites play other files under the same track ids).
    private func makePlayer(files: PlaybackFileCache? = nil) -> Player {
        let player = Player(files: files ?? PlaybackFileCache(directory: folder.appendingPathComponent("cache-\(UUID().uuidString)")))
        player.volume = 0
        player.repeatMode = .off
        player.setShuffle(false)
        return player
    }

    /// A cache that takes every file for one on the network share: tracks started now stream from
    /// it, tracks fetched ahead are copied.
    private func shareCache() -> PlaybackFileCache {
        PlaybackFileCache(directory: folder.appendingPathComponent("share-cache"), isLocal: { _ in false })
    }

    /// Waits until `condition` holds, polling the main actor.
    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    // MARK: Queue

    @Test func playsThroughQueueGaplesslyAndCountsPlays() async {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        player.play(Array(tracks.prefix(3)), startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        let start = Date()

        #expect(await waitUntil { player.currentTrack?.id == 2 })
        #expect(await waitUntil { player.currentTrack?.id == 3 })
        #expect(await waitUntil { player.currentTrack == nil }, "stops at the end of the queue")
        let elapsed = Date().timeIntervalSince(start)
        // Three 1-second files back to back. Restarting the node per track would add a gap each time.
        #expect(elapsed < 3.5, "took \(elapsed)s for 3s of audio")
        #expect(played == [1, 2, 3])
        player.stop()
    }

    @Test func playNextAndAddToQueueOrder() async {
        let player = makePlayer()
        player.play([tracks[0], tracks[1]], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        player.addToQueue([tracks[3]])
        player.playNext([tracks[2]])
        // Play Next goes first, then queued tracks, then the rest of the original list.
        #expect(player.upNext.map(\.id) == [3, 4, 2])
        #expect(player.queuedAheadCount == 2)

        player.next()
        #expect(await waitUntil { player.currentTrack?.id == 3 })
        #expect(player.queuedAheadCount == 1)
        player.removeFromUpNext(at: [0])
        #expect(player.upNext.map(\.id) == [2])
        player.stop()
    }

    @Test func jumpingToTheFirstQueuedTrackUsesUpOnlyThatOne() {
        let player = makePlayer()
        player.play([tracks[0]], startingAt: 0)
        player.addToQueue([tracks[1], tracks[2]])
        #expect(player.queuedAheadCount == 2)
        player.jump(toUpNext: 0)
        #expect(player.currentTrack?.id == 2)
        #expect(player.queuedAheadCount == 1, "the other queued track is still marked as queued")
        player.jump(toUpNext: 0)
        #expect(player.queuedAheadCount == 0)
        player.stop()
    }

    @Test func shuffleKeepsCurrentTrackFirstAndRestoresOrder() async {
        let player = makePlayer()
        player.play(tracks, startingAt: 2)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        player.setShuffle(true)
        #expect(player.currentTrack?.id == 3)
        #expect(Set(player.upNext.map(\.id)) == [1, 2, 4])
        player.setShuffle(false)
        #expect(player.currentTrack?.id == 3)
        #expect(player.upNext.map(\.id) == [4])
        player.stop()
    }

    @Test func turningShuffleOffFollowsEditsMadeWhileShuffled() {
        let player = makePlayer()
        player.play(Array(tracks.prefix(3)), startingAt: 0)
        player.addToQueue([tracks[3]])
        player.setShuffle(true)
        #expect(player.currentTrack?.id == 1)
        #expect(player.upNext.first?.id == 4 && player.queuedAheadCount == 1, "what was queued stays next")

        // Track 2 queued a second time, and its first entry removed from the shuffled rest.
        player.playNext([tracks[1]])
        let shuffledTwo = player.upNext.indices.first { $0 >= player.queuedAheadCount && player.upNext[$0].id == 2 }
        player.removeFromUpNext(at: IndexSet(integer: shuffledTwo ?? 0))
        player.setShuffle(false)
        #expect(player.currentTrack?.id == 1)
        #expect(player.upNext.map(\.id) == [2, 4, 3])
        #expect(player.queuedAheadCount == 2)

        // Clearing Up Next while shuffled doesn't bring it all back when shuffle goes off.
        player.setShuffle(true)
        player.clearUpNext()
        player.setShuffle(false)
        #expect(player.currentTrack?.id == 1 && player.upNext.isEmpty)
        player.stop()
    }

    @Test func repeatOneReplaysAndNextStillAdvances() async {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        player.repeatMode = .one
        player.play([tracks[0], tracks[1]], startingAt: 0)
        #expect(await waitUntil { played.count >= 2 })
        #expect(played.prefix(2) == [1, 1])
        #expect(player.currentTrack?.id == 1)
        player.next()
        #expect(await waitUntil { player.currentTrack?.id == 2 })
        player.repeatMode = .off
        player.stop()
    }

    // MARK: Pausing and seeking

    @Test func seekWhilePausedStaysPaused() async {
        let player = makePlayer()
        player.play([tracks[0]], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        player.togglePlayPause()
        player.seek(to: 0.5)
        #expect(!player.isPlaying)
        #expect(abs(player.currentTime - 0.5) < 0.05)
        player.stop()
    }

    @Test func pausingWhileATrackLoadsIsKept() async {
        let player = makePlayer()
        player.locate = { ref in
            Thread.sleep(forTimeInterval: 0.5)  // a slow share
            return URL(fileURLWithPath: ref.path)
        }
        var started = 0
        player.onStartedPlaying = { started += 1 }
        player.play([tracks[0]], startingAt: 0)
        #expect(player.isLoading && player.isPlaying)
        player.pause()
        #expect(player.isLoading && !player.isPlaying, "Pause is taken while the file loads")

        #expect(await waitUntil { !player.isLoading })
        #expect(!player.isPlaying && started == 0, "the file opens paused, and the mixer's decks aren't stopped")
        #expect(!player.isEngineRunning)
        player.togglePlayPause()
        #expect(player.isPlaying && started == 1)
        player.stop()
    }

    @Test func aPausedPlayerLetsTheOutputDeviceGo() async throws {
        let player = makePlayer()
        player.engineIdleDelay = .milliseconds(300)
        player.play([try Self.tone(31, seconds: 2, in: folder)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.5 })
        player.togglePlayPause()
        let position = player.currentTime
        #expect(player.isEngineRunning, "a short pause keeps the engine, for an instant resume")
        #expect(await waitUntil { !player.isEngineRunning })
        #expect(player.currentTime == position)

        player.togglePlayPause()
        #expect(player.isEngineRunning && player.isPlaying)
        #expect(player.currentTime >= position - 0.01, "resumes where it paused")
        #expect(await waitUntil { player.currentTrack == nil }, "and plays on to the end")
    }

    @Test func anOutputChangeCarriesOnWhereItWas() async throws {
        let player = makePlayer()
        player.play([try Self.tone(32, seconds: 3, in: folder)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 1.2 })
        // What happens when headphones are unplugged: the engine stops itself, then says so.
        let engine = try #require(player.equalizer.unit.engine)
        engine.stop()
        let position = player.currentTime
        #expect(position > 0.3, "the position outlives the engine's clock")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)

        #expect(await waitUntil { player.isEngineRunning && player.isPlaying })
        #expect(player.currentTrack?.id == 32, "the engine stopping isn't taken for the end of the track")
        #expect(player.currentTime >= position - 0.01, "carries on rather than starting over")
        #expect(await waitUntil { player.currentTrack == nil })
    }

    // MARK: Plays and listens

    @Test func aPlayIsHalfTheTrackHeardOrFourMinutes() {
        #expect(!ListenSession.countsAsPlay(2.9, of: 6))
        #expect(ListenSession.countsAsPlay(3, of: 6))
        #expect(!ListenSession.countsAsPlay(239, of: 3600))
        #expect(ListenSession.countsAsPlay(240, of: 3600))
        #expect(!ListenSession.countsAsPlay(10, of: 0), "unknown length")
    }

    @Test func seekingPastTheMiddleDoesntCountAPlay() async throws {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        player.play([try Self.tone(33, seconds: 6, in: folder)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        player.seek(to: 4.5)
        try? await Task.sleep(for: .seconds(0.8))
        #expect(played.isEmpty, "the playhead is past halfway, but under a second has been heard")
        #expect(await waitUntil { player.currentTrack == nil })
        #expect(played.isEmpty, "reaching the end after skipping most of it isn't a play either")
    }

    // MARK: The network share

    @Test func startingAPreparedTrackClearsTheSpinner() async throws {
        let player = makePlayer(files: shareCache())
        var listens: [(Int64, ListenRecord)] = []
        player.onListenEnded = { listens.append(($0.id, $1)) }
        let folder = folder
        player.play(try [21, 22].map { try Self.tone($0, seconds: 3, in: folder) }, startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        // Meanwhile the next track is copied, then opened.
        let copies = folder.appendingPathComponent("share-cache")
        #expect(await waitUntil {
            ((try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []).contains { $0.hasPrefix("22-") && $0.hasSuffix(".wav") }
        })
        try? await Task.sleep(for: .milliseconds(200))

        player.seek(to: 0.5)
        #expect(player.isLoading, "a seek in a streamed track waits for its probe")
        player.next()
        #expect(player.isPlaying && !player.isLoading && !player.isWaitingForShare, "the copied next track plays at once")
        #expect(await waitUntil { player.currentTrack == nil })
        #expect(listens.last?.0 == 22)
        #expect((listens.last?.1.seconds ?? 0) > 2.5, "and its listening time counts")
    }

    @Test func resumingAfterASeekWhilePausedWaitsForTheShare() async throws {
        let player = makePlayer(files: shareCache())
        player.play([try Self.tone(23, seconds: 3, in: folder)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        player.togglePlayPause()
        player.seek(to: 1.5)
        player.togglePlayPause()
        #expect(player.isLoading, "the probe holds the clock until audio from there has played")
        #expect(player.currentTime == 1.5)
        #expect(await waitUntil { !player.isLoading })
        player.stop()
    }

    @Test func aChainedTrackKeepsItsStreamingFlag() async throws {
        let player = makePlayer(files: shareCache())
        // With nowhere to copy to, the next track falls back to streaming from the share too.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("share-cache"))
        let folder = folder
        player.play(try [24, 25].map { try Self.tone($0, seconds: $0 == 24 ? 1 : 3, in: folder) }, startingAt: 0)
        #expect(await waitUntil { player.currentTrack?.id == 25 && !player.isLoading })
        player.seek(to: 1)
        #expect(player.isLoading, "a seek in the streamed track waits for its probe")
        player.stop()
    }

    @Test func missingFilesAreSkippedThenPlaybackWaitsWhereItBegan() async {
        let player = makePlayer()
        var unplayable: [Int64] = []
        player.onUnplayable = { unplayable.append($0.id) }
        player.play((10...14).map(Self.missing), startingAt: 0)
        #expect(await waitUntil { !player.isLoading && !player.isPlaying }, "gives up after a few failures instead of walking the whole queue")
        #expect(unplayable == [10, 11, 12])
        // The share is probably gone: back to where it began, paused, with the queue kept.
        #expect(player.currentTrack?.id == 10)
        #expect(player.upNextCount == 4)
        #expect(player.errorMessage != nil)
        #expect(player.savedState?.index == 0)
    }

    // MARK: Restoring at launch

    @Test func restoreOpensNothingUntilPlay() async {
        let player = makePlayer()
        var started = 0
        player.onStartedPlaying = { started += 1 }
        player.restore([tracks[0], tracks[1]], index: 1, position: 0.5)
        #expect(player.currentTrack?.id == 2)
        #expect(!player.isPlaying && !player.isLoading)
        #expect(player.currentTime == 0.5)
        #expect(player.savedState?.trackIDs == [1, 2])
        #expect(player.savedState?.index == 1 && player.savedState?.position == 0.5)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!player.isEngineRunning, "a restored queue doesn't keep the output device running")

        player.togglePlayPause()
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        #expect(player.isEngineRunning && started == 1)
        #expect(player.currentTime >= 0.5, "picks up where it was")
        #expect(await waitUntil { player.currentTrack == nil })
    }

    @Test func aRestoredQueueSurvivesAShareThatIsntThere() async {
        let player = makePlayer()
        var unplayable: [Int64] = []
        player.onUnplayable = { unplayable.append($0.id) }
        player.restore([Self.missing(10), Self.missing(11), Self.missing(12), tracks[0]], index: 0, position: 42)
        player.togglePlayPause()
        #expect(await waitUntil { !player.isLoading && !player.isPlaying })
        #expect(unplayable == [10, 11, 12])
        // Back where it was, paused, so the queue and position are saved for next time.
        #expect(player.currentTrack?.id == 10)
        #expect(player.savedState?.index == 0 && player.savedState?.position == 42)
        #expect(!player.isEngineRunning)
        player.stop()
    }

    @Test func skippingARestoredTrackThatWontOpenDoesntStartTheMusic() async {
        let player = makePlayer()
        var started = 0
        player.onStartedPlaying = { started += 1 }
        player.restore([Self.missing(10), tracks[1]], index: 0, position: 0)
        player.seek(to: 0.3)
        #expect(await waitUntil { player.currentTrack?.id == 2 && !player.isLoading })
        #expect(!player.isPlaying && started == 0)
        #expect(!player.isEngineRunning)
        player.stop()
    }
}
