import AVFoundation
import Foundation

/// One listen in progress, for the queue player and the mixer's decks alike: how long the track
/// has actually been heard, and whether that's enough to count as a play.
///
/// Plays count by time listened, not by where the playhead is, so seeking past the middle, resuming
/// a track restored past it, or auditioning a deck near the end doesn't count one.
struct ListenSession {
    let track: Track
    /// Whether this listen has been counted as a play (it's counted once).
    private(set) var isCounted = false
    private var listen: ListenRecord
    private var updatedAt: Date
    /// The audio clock at the last update that had one.
    private var clockAtUpdate: TimeInterval = 0

    /// A play is half the track, or this much of a long one.
    static let playThreshold: TimeInterval = 240
    /// The most one update can add. They come twice a second, so this only bites when a Mac wakes
    /// from sleep with a clock that kept counting.
    static let longestUpdate: TimeInterval = 5

    init(_ track: Track, now: Date = Date()) {
        self.track = track
        listen = ListenRecord(trackID: track.id, startedAt: now, seconds: 0, position: 0, outcome: .finished)
        updatedAt = now
    }

    /// Whether hearing `seconds` of a track `duration` long counts as playing it.
    static func countsAsPlay(_ seconds: TimeInterval, of duration: TimeInterval) -> Bool {
        duration > 0 && seconds >= min(duration / 2, playThreshold)
    }

    /// Adds what's been heard since the last update, if the track was audible all along (not paused,
    /// loading or waiting for data). Call before anything changes whether it's audible.
    ///
    /// `clock` is the node's `renderedSeconds`. Time only counts as far as that clock has moved, so
    /// a sleeping Mac or a stalled device isn't listening, and only as far as real time has passed,
    /// since the clock can jump ahead when the output comes back.
    mutating func update(audible: Bool, clock: TimeInterval?, now: Date = Date()) {
        defer { updatedAt = now }
        guard let clock else { return }
        defer { clockAtUpdate = clock }
        guard audible else { return }
        // The clock starts over whenever the node does.
        let played = clock >= clockAtUpdate ? clock - clockAtUpdate : clock
        listen.seconds += max(0, min(played, now.timeIntervalSince(updatedAt), Self.longestUpdate))
    }

    /// True the first time enough has been heard to count as a play.
    mutating func takePlay(duration: TimeInterval) -> Bool {
        guard !isCounted, Self.countsAsPlay(listen.seconds, of: duration) else { return false }
        isCounted = true
        return true
    }

    /// The listen as it ended, or nil if it was under a second (not worth keeping).
    func record(_ outcome: ListenOutcome, at position: TimeInterval) -> ListenRecord? {
        guard listen.seconds >= 1 else { return nil }
        var ended = listen
        ended.outcome = outcome
        ended.position = position
        return ended
    }
}

extension AVAudioPlayerNode {
    /// How much audio the node has rendered since it last started, by its own clock: what a listen
    /// goes by. nil while it isn't rendering (paused, or the engine stopped).
    var renderedSeconds: TimeInterval? {
        guard engine?.isRunning == true, let nodeTime = lastRenderTime,
              let playerTime = playerTime(forNodeTime: nodeTime) else { return nil }
        // It reads a little before the start until the node's first render after play.
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }
}
