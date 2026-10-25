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

    /// A play is half the track, or this much of a long one.
    static let playThreshold: TimeInterval = 240

    init(_ track: Track, now: Date = Date()) {
        self.track = track
        listen = ListenRecord(trackID: track.id, startedAt: now, seconds: 0, position: 0, outcome: .finished)
        updatedAt = now
    }

    /// Whether hearing `seconds` of a track `duration` long counts as playing it.
    static func countsAsPlay(_ seconds: TimeInterval, of duration: TimeInterval) -> Bool {
        duration > 0 && seconds >= min(duration / 2, playThreshold)
    }

    /// Adds the time since the last update if the track was audible all along (not paused, loading
    /// or waiting for data). Call before anything changes whether it's audible.
    mutating func update(audible: Bool, now: Date = Date()) {
        if audible { listen.seconds += now.timeIntervalSince(updatedAt) }
        updatedAt = now
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
