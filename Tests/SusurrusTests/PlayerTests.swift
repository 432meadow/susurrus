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

    @Test func playsThroughQueueGaplesslyAndCountsPlays() async throws {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        let queue = try await joining(from: 40, formats: [(44_100, 2), (44_100, 2), (44_100, 2)])
        player.play(queue, startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        let recording = AudioRecording()
        recording.start(on: player.equalizer.unit)

        #expect(await waitUntil { player.currentTrack?.id == 41 })
        #expect(await waitUntil { player.currentTrack?.id == 42 })
        #expect(await waitUntil { player.currentTrack == nil }, "stops at the end of the queue")
        recording.stop(on: player.equalizer.unit)
        #expect(played == [40, 41, 42])
        // Three seconds of one sine: restarting the node per track would add a gap each time.
        let heard = recording.toneContinuity()
        #expect(heard.seconds > 2.5, "heard \(heard.seconds)s")
        #expect(heard.slipInSamples < 2, "the sine slips \(heard.slipInSamples) samples")
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

    // MARK: Formats

    /// A track whose file is a 100 Hz tone in whole cycles, so tracks in any formats join up into
    /// one unbroken sine, and a gap between them shows as a slip in its phase.
    private func joining(_ id: Int64, sampleRate: Double = 44_100, channels: AVAudioChannelCount = 2,
                         seconds: Double = 1) async throws -> Track {
        let url = folder.appendingPathComponent("\(id).wav")
        try await ToneFile.make(at: url, seconds: seconds, frequency: AudioRecording.toneFrequency, sampleRate: sampleRate, channels: channels)
        let track = Track(id: id)
        track.title = "Tone \(id)"
        track.path = url.path
        track.length = seconds
        return track
    }

    /// Tracks made by `joining`, with ids from `firstID`.
    private func joining(from firstID: Int64, formats: [(Double, AVAudioChannelCount)], seconds: Double = 1) async throws -> [Track] {
        var tracks: [Track] = []
        for (offset, format) in formats.enumerated() {
            tracks.append(try await joining(firstID + Int64(offset), sampleRate: format.0, channels: format.1, seconds: seconds))
        }
        return tracks
    }

    /// What the installed app's log called "Unsupported audio format": any track started while the
    /// engine runs, in another sample rate or channel count than the last.
    @Test func aTrackInAnotherFormatPlaysWhileTheEngineRuns() async throws {
        let player = makePlayer()
        let queue = try await joining(from: 50, formats: [(44_100, 2), (48_000, 2), (96_000, 2), (44_100, 1), (48_000, 6), (22_050, 2)], seconds: 3)
        player.play(queue, startingAt: 0)
        for track in queue {
            #expect(await waitUntil { player.currentTrack?.id == track.id && player.isPlaying && player.currentTime > 0.2 }, "\(track.id) plays")
            #expect(player.errorMessage == nil, "\(player.errorMessage ?? "")")
            #expect(player.isEngineRunning)
            if track.id != queue.last?.id { player.next() }
        }
        player.stop()
    }

    @Test func chainsAcrossSampleRatesAndChannelCountsWithoutAGap() async throws {
        let player = makePlayer()
        var played: [Int64] = []
        player.onTrackPlayed = { played.append($0.id) }
        let queue = try await joining(from: 60, formats: [(44_100, 2), (48_000, 2), (96_000, 2), (44_100, 1), (22_050, 2), (192_000, 2), (44_100, 2)])
        let recording = AudioRecording()

        player.play(queue, startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        recording.start(on: player.equalizer.unit)
        #expect(await waitUntil { player.currentTrack == nil })
        recording.stop(on: player.equalizer.unit)

        #expect(player.errorMessage == nil, "\(player.errorMessage ?? "")")
        #expect(played == queue.map(\.id))
        let heard = recording.toneContinuity()
        #expect(heard.seconds > 5.5, "heard \(heard.seconds)s")
        // At the output's rate a sample is ~20 µs, so this is under 40 µs out at any join.
        #expect(heard.slipInSamples < 2, "the sine slips \(heard.slipInSamples) samples")
        #expect(heard.quietestAmplitude > 0.19, "the tone drops to \(heard.quietestAmplitude)")
    }

    /// Whatever the output's rate, a join between two tracks at one rate is as if they were one
    /// file: the node converts nothing, and the mixer's conversion runs straight through it.
    @Test func aJoinAtOneRateIsExact() async throws {
        let player = makePlayer()
        var tracks: [Track] = []
        for id in Int64(76)...77 {
            let url = folder.appendingPathComponent("\(id).wav")
            // A higher tone than the others': any fault at the join grows with the frequency.
            try await ToneFile.make(at: url, seconds: 1, frequency: 1_000)
            let track = Track(id: id)
            track.path = url.path
            tracks.append(track)
        }
        player.play(tracks, startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        let recording = AudioRecording()
        recording.start(on: player.equalizer.unit)
        #expect(await waitUntil { player.currentTrack == nil })
        recording.stop(on: player.equalizer.unit)
        let heard = recording.toneContinuity(frequency: 1_000)
        #expect(heard.seconds > 1.5, "heard \(heard.seconds)s")
        #expect(heard.slipInSamples < 0.1)
        // The node converting would make this about 0.001, on a tone 0.2 high.
        #expect(heard.worstDeviation < 0.0002, "strays \(heard.worstDeviation)")
    }

    @Test func aMonoTrackComesOutOfBothSpeakers() async throws {
        let player = makePlayer()
        player.play([try await joining(70, channels: 1, seconds: 2)], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && !player.isLoading })
        let recording = AudioRecording()
        recording.start(on: player.equalizer.unit)
        #expect(await waitUntil { player.currentTrack == nil })
        recording.stop(on: player.equalizer.unit)
        #expect(abs(recording.toneContinuity(channel: 0).quietestAmplitude - 0.2) < 0.01)
        #expect(abs(recording.toneContinuity(channel: 1).quietestAmplitude - 0.2) < 0.01)
    }

    @Test func aSurroundTrackIsMixedDownNotCutDown() async throws {
        // Only the centre channel sounds: a player that just took the first two would be silent.
        let url = folder.appendingPathComponent("71.wav")
        try await ToneFile.make(at: url, seconds: 2, frequency: AudioRecording.toneFrequency, sampleRate: 48_000, channels: 6, onlyChannel: 2)
        let surround = Track(id: 71)
        surround.path = url.path
        let player = makePlayer()
        // Between stereo tracks, so it takes rewiring both ways with the engine running.
        player.play([try await joining(72), surround, try await joining(73)], startingAt: 0)
        #expect(await waitUntil { player.currentTrack?.id == 71 && !player.isLoading })
        let recording = AudioRecording()
        recording.start(on: player.equalizer.unit)
        #expect(await waitUntil { player.currentTrack?.id == 73 })
        recording.stop(on: player.equalizer.unit)
        #expect(recording.toneContinuity(channel: 0).quietestAmplitude > 0.1)
        #expect(recording.toneContinuity(channel: 1).quietestAmplitude > 0.1)
        #expect(await waitUntil { player.currentTrack == nil })
        #expect(player.errorMessage == nil, "\(player.errorMessage ?? "")")
    }

    @Test func theClockAndTheListenKeepTimeAcrossAChainToAnotherRate() async throws {
        let player = makePlayer()
        var listens: [ListenRecord] = []
        player.onListenEnded = { listens.append($1) }
        player.play([try await joining(74, seconds: 2), try await joining(75, sampleRate: 96_000, seconds: 3)], startingAt: 0)
        #expect(await waitUntil { player.currentTrack?.id == 75 })
        let start = Date()
        #expect(player.currentTime < 0.3, "starts from the top, at \(player.currentTime)")
        try? await Task.sleep(for: .seconds(1.2))
        let elapsed = Date().timeIntervalSince(start)
        #expect(abs(player.currentTime - elapsed) < 0.25, "at \(player.currentTime) after \(elapsed)s")
        #expect(abs(player.duration - 3) < 0.01)
        player.seek(to: 0.4)
        #expect(await waitUntil { player.currentTime > 0.5 })
        #expect(player.currentTime < 1)
        player.stop()
        #expect(listens.map(\.trackID) == [74, 75])
        #expect((1.7...2.4).contains(listens.first?.seconds ?? 0), "\(listens)")
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

    /// An hour's sleep in the middle of a listen: the Date moves on, the audio clock doesn't.
    @Test func aSleepGapIsntListening() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let track = Track(id: 1)
        var session = ListenSession(track, now: start)
        session.update(audible: true, clock: 0, now: start)
        session.update(audible: true, clock: 2, now: start.addingTimeInterval(2))
        session.update(audible: true, clock: 2.1, now: start.addingTimeInterval(3602))
        let isAPlay = session.takePlay(duration: 60)
        #expect(!isAPlay, "an hour asleep doesn't award a play")
        session.update(audible: true, clock: 2.6, now: start.addingTimeInterval(3602.5))
        #expect(abs((session.record(.stopped, at: 0)?.seconds ?? 0) - 2.6) < 0.001)
    }

    @Test func aClockThatCountedThroughASleepIsCapped() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var session = ListenSession(Track(id: 1), now: start)
        session.update(audible: true, clock: 3, now: start.addingTimeInterval(3))
        session.update(audible: true, clock: 3603, now: start.addingTimeInterval(3603))
        let seconds = session.record(.stopped, at: 0)?.seconds ?? 0
        #expect(abs(seconds - (3 + ListenSession.longestUpdate)) < 0.001)
    }

    @Test func aStalledOutputIsntListening() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var session = ListenSession(Track(id: 1), now: start)
        session.update(audible: true, clock: 1, now: start.addingTimeInterval(1))
        // The device stops: updates go on with the clock standing still, or gone.
        session.update(audible: true, clock: 1, now: start.addingTimeInterval(1.5))
        session.update(audible: true, clock: nil, now: start.addingTimeInterval(2))
        #expect(abs((session.record(.stopped, at: 0)?.seconds ?? 0) - 1) < 0.001)
        // It comes back with the clock leapt ahead by the stall: only the half second since counts.
        session.update(audible: true, clock: 1.5, now: start.addingTimeInterval(2.5))
        session.update(audible: true, clock: 30, now: start.addingTimeInterval(3))
        #expect(abs((session.record(.stopped, at: 0)?.seconds ?? 0) - 2) < 0.001)
    }

    @Test func aRestartedClockCountsFromItsNewStart() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var session = ListenSession(Track(id: 1), now: start)
        session.update(audible: true, clock: 5, now: start.addingTimeInterval(5))
        session.update(audible: true, clock: 0.25, now: start.addingTimeInterval(5.5))
        #expect(abs((session.record(.stopped, at: 0)?.seconds ?? 0) - 5.25) < 0.001)
    }

    @Test func pausedTimeIsntListeningWhateverTheClockDoes() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var session = ListenSession(Track(id: 1), now: start)
        session.update(audible: true, clock: 2, now: start.addingTimeInterval(2))
        session.update(audible: false, clock: 2.5, now: start.addingTimeInterval(4))
        session.update(audible: true, clock: 3, now: start.addingTimeInterval(4.5))
        #expect(abs((session.record(.stopped, at: 0)?.seconds ?? 0) - 2.5) < 0.001)
    }

    /// What a stalled device does to the real engine, as near as a test can make it: audio stops
    /// coming while everything else carries on.
    @Test func anEngineThatStallsBooksNoListeningTime() async throws {
        let player = makePlayer()
        var listens: [ListenRecord] = []
        player.onListenEnded = { listens.append($1) }
        let track = try await joining(34, seconds: 8)
        let start = Date()
        player.play([track], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 0.5 })
        let engine = try #require(player.equalizer.unit.engine)
        engine.pause()
        let stalled = Date()
        try? await Task.sleep(for: .seconds(1.5))
        let stall = Date().timeIntervalSince(stalled)
        try engine.start()
        try? await Task.sleep(for: .seconds(1))
        player.stop()
        let played = Date().timeIntervalSince(start) - stall
        let seconds = listens.first?.seconds ?? 0
        #expect(seconds > 1)
        // At most the update that sees the output come back can take in a tick's worth of the stall.
        #expect(seconds <= played + 0.5, "\(seconds)s counted of \(played)s played; the \(stall)s stall shouldn't be")
    }

    @Test func aPauseStillCountsWhatWasHeardJustBefore() async throws {
        let player = makePlayer()
        var listens: [ListenRecord] = []
        player.onListenEnded = { listens.append($1) }
        player.play([try Self.tone(35, seconds: 4, in: folder)], startingAt: 0)
        #expect(await waitUntil { player.currentTime > 1.3 })
        player.togglePlayPause()
        let position = player.currentTime
        player.stop()
        #expect(abs((listens.first?.seconds ?? 0) - position) < 0.15, "\(listens) by \(position)")
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
