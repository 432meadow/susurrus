import Foundation

/// Listening stats for the Stats view: totals, top lists, when you listen, and a year of days.
///
/// Time comes from the listen log (time actually spent playing). Plays from before susurrus kept
/// that log only exist as counted plays, so for those the track's length stands in.
struct ListeningStats: Sendable {
    enum Range: String, CaseIterable, Identifiable, Sendable {
        case week = "Last 7 Days"
        case month = "Last 30 Days"
        case year = "Last 12 Months"
        case all = "All Time"

        var id: Self { self }

        /// Start of the range (midnight, so whole days are covered); nil for all time.
        func start(now: Date, calendar: Calendar) -> Date? {
            let today = calendar.startOfDay(for: now)
            return switch self {
            case .week: calendar.date(byAdding: .day, value: -6, to: today)
            case .month: calendar.date(byAdding: .day, value: -29, to: today)
            case .year: calendar.date(byAdding: .month, value: -12, to: today)
            case .all: nil
            }
        }
    }

    /// What the stats need to know about a track, copied off the main actor.
    struct TrackInfo: Sendable {
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var length: Double

        init(title: String, artist: String, album: String, albumArtist: String, length: Double) {
            self.title = title
            self.artist = artist
            self.album = album
            self.albumArtist = albumArtist
            self.length = length
        }

        init(_ track: Track) {
            self.init(title: track.displayTitle, artist: track.displayArtist, album: track.album,
                      albumArtist: track.albumGroupArtist, length: track.length)
        }
    }

    /// One row of a top list.
    struct Entry: Identifiable, Equatable, Sendable {
        var id: String
        var title: String
        var subtitle: String
        var seconds: Double
        var plays: Int
        var skips: Int
        /// A track to play, or to take artwork from.
        var trackID: Int64
    }

    var range: Range = .month
    var totalSeconds = 0.0
    var plays = 0
    var skips = 0
    var distinctTracks = 0
    var topArtists: [Entry] = []
    var topAlbums: [Entry] = []
    var topTracks: [Entry] = []
    var mostSkipped: [Entry] = []
    /// Seconds listened in each hour of the day, 0–23.
    var hourly: [Double] = Array(repeating: 0, count: 24)
    /// Average seconds per day for each weekday, indexed by `Calendar` weekday − 1 (Sunday first).
    var weekdayAverages: [Double] = Array(repeating: 0, count: 7)
    /// Seconds listened per day over the last 12 months (whatever the range), keyed by start of day.
    var days: [Date: Double] = [:]
    /// First day of the calendar grid.
    var calendarStart = Date()
    /// Time before this date is estimated from track lengths (nil when none of it is).
    var estimatedBefore: Date?

    var isEmpty: Bool { plays == 0 && totalSeconds < 1 }

    static let topCount = 10

    /// The earliest date `compute` needs listens and plays from, for `range`.
    static func loadStart(for range: Range, now: Date, calendar: Calendar) -> Date? {
        guard let start = range.start(now: now, calendar: calendar) else { return nil }
        return min(start, calendarGridStart(now: now, calendar: calendar))
    }

    /// The calendar shows 53 weeks, starting on the first day of the week.
    static func calendarGridStart(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let yearAgo = calendar.date(byAdding: .day, value: -52 * 7, to: today)!
        return calendar.dateInterval(of: .weekOfYear, for: yearAgo)?.start ?? yearAgo
    }

    static func compute(
        range: Range,
        listens: [ListenRecord],
        plays: [PlayRecord],
        firstListen: Date?,
        tracks: [Int64: TrackInfo],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ListeningStats {
        var stats = ListeningStats()
        stats.range = range
        stats.calendarStart = calendarGridStart(now: now, calendar: calendar)
        let rangeStart = range.start(now: now, calendar: calendar)

        // Listening time: from listens where there are any, estimated from counted plays before that.
        struct TimeEvent {
            var trackID: Int64
            var date: Date
            var seconds: Double
        }
        var events: [TimeEvent] = listens.map { TimeEvent(trackID: $0.trackID, date: $0.startedAt, seconds: $0.seconds) }
        let estimated = plays.filter { firstListen == nil || $0.playedAt < firstListen! }
        events += estimated.compactMap { play in
            tracks[play.trackID].map { TimeEvent(trackID: play.trackID, date: play.playedAt, seconds: $0.length) }
        }
        if !estimated.isEmpty { stats.estimatedBefore = firstListen ?? now }

        func inRange(_ date: Date) -> Bool { (rangeStart.map { date >= $0 } ?? true) && date <= now }

        for event in events where event.date >= stats.calendarStart && event.date <= now {
            stats.days[calendar.startOfDay(for: event.date), default: 0] += event.seconds
        }

        var trackSeconds: [Int64: Double] = [:]
        var trackPlays: [Int64: Int] = [:]
        var trackSkips: [Int64: Int] = [:]
        var weekdayTotals = Array(repeating: 0.0, count: 7)
        var firstEvent: Date?
        for event in events where inRange(event.date) {
            trackSeconds[event.trackID, default: 0] += event.seconds
            stats.totalSeconds += event.seconds
            stats.hourly[calendar.component(.hour, from: event.date)] += event.seconds
            weekdayTotals[calendar.component(.weekday, from: event.date) - 1] += event.seconds
            firstEvent = min(firstEvent ?? event.date, event.date)
        }
        for play in plays where inRange(play.playedAt) {
            trackPlays[play.trackID, default: 0] += 1
            stats.plays += 1
        }
        for listen in listens where listen.outcome == .skipped && inRange(listen.startedAt) {
            trackSkips[listen.trackID, default: 0] += 1
            stats.skips += 1
        }
        stats.distinctTracks = Set(trackSeconds.keys).union(trackPlays.keys).count

        // Average per weekday: each weekday's total over how many of that weekday the range spans.
        if let first = rangeStart ?? firstEvent {
            var counts = Array(repeating: 0, count: 7)
            var day = calendar.startOfDay(for: first)
            let lastDay = calendar.startOfDay(for: now)
            while day <= lastDay {
                counts[calendar.component(.weekday, from: day) - 1] += 1
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
            stats.weekdayAverages = zip(weekdayTotals, counts).map { $1 > 0 ? $0 / Double($1) : 0 }
        }

        // Top lists, by listening time (plays break ties).
        struct Bucket {
            var title: String
            var subtitle: String
            var seconds = 0.0
            var plays = 0
            var skips = 0
            var trackID: Int64
            var bestTrackSeconds = -1.0
        }
        var artists: [String: Bucket] = [:]
        var albums: [String: Bucket] = [:]
        var trackEntries: [Entry] = []
        for id in Set(trackSeconds.keys).union(trackPlays.keys) {
            guard let info = tracks[id] else { continue }
            let seconds = trackSeconds[id] ?? 0
            let playCount = trackPlays[id] ?? 0
            let skipCount = trackSkips[id] ?? 0
            trackEntries.append(Entry(id: "t\(id)", title: info.title, subtitle: info.artist,
                                      seconds: seconds, plays: playCount, skips: skipCount, trackID: id))

            func add(to buckets: inout [String: Bucket], key: String, title: String, subtitle: String) {
                var bucket = buckets[key] ?? Bucket(title: title, subtitle: subtitle, trackID: id)
                bucket.seconds += seconds
                bucket.plays += playCount
                bucket.skips += skipCount
                if seconds > bucket.bestTrackSeconds {
                    bucket.bestTrackSeconds = seconds
                    bucket.trackID = id
                }
                buckets[key] = bucket
            }
            if !info.artist.isEmpty {
                add(to: &artists, key: ArtistIndex.key(for: info.artist), title: info.artist, subtitle: "")
            }
            if !info.album.isEmpty {
                // The same album identity as the Albums grid (`Track.albumKey`).
                add(to: &albums, key: ArtworkStore.indexKey(artist: info.albumArtist, album: info.album),
                    title: info.album, subtitle: info.albumArtist)
            }
        }

        func ranked(_ entries: [Entry]) -> [Entry] {
            Array(entries.sorted {
                ($0.seconds, $0.plays, $1.title) > ($1.seconds, $1.plays, $0.title)
            }.prefix(topCount))
        }
        func entries(_ buckets: [String: Bucket], prefix: String) -> [Entry] {
            buckets.map { key, bucket in
                Entry(id: prefix + key, title: bucket.title, subtitle: bucket.subtitle, seconds: bucket.seconds,
                      plays: bucket.plays, skips: bucket.skips, trackID: bucket.trackID)
            }
        }
        stats.topTracks = ranked(trackEntries)
        stats.topArtists = ranked(entries(artists, prefix: "ar"))
        stats.topAlbums = ranked(entries(albums, prefix: "al"))
        stats.mostSkipped = Array(trackEntries.filter { $0.skips > 0 }.sorted {
            ($0.skips, $1.plays, $1.title) > ($1.skips, $0.plays, $0.title)
        }.prefix(topCount))
        return stats
    }
}
