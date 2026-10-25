import Foundation
import Testing
@testable import Susurrus

@Suite struct ListeningStatsTests {
    var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    var tracks: [Int64: ListeningStats.TrackInfo] {
        [
            1: .init(title: "One", artist: "A", album: "X", albumArtist: "A", length: 200),
            2: .init(title: "Two", artist: "A", album: "X", albumArtist: "A", length: 300),
            3: .init(title: "Three", artist: "B", album: "Y", albumArtist: "B", length: 100),
        ]
    }

    var listens: [ListenRecord] {
        [
            ListenRecord(trackID: 1, startedAt: date(10, 15, 9, 58), seconds: 200, position: 200, outcome: .finished),
            ListenRecord(trackID: 1, startedAt: date(10, 16, 9, 58), seconds: 190, position: 200, outcome: .finished),
            ListenRecord(trackID: 2, startedAt: date(10, 16, 22), seconds: 20, position: 20, outcome: .skipped),
            ListenRecord(trackID: 2, startedAt: date(10, 17, 8), seconds: 15, position: 15, outcome: .skipped),
        ]
    }

    var plays: [PlayRecord] {
        [
            PlayRecord(trackID: 3, playedAt: date(9, 1)),  // before listens were logged: estimated
            PlayRecord(trackID: 1, playedAt: date(10, 15, 10)),
            PlayRecord(trackID: 1, playedAt: date(10, 16, 10)),
        ]
    }

    func compute(_ range: ListeningStats.Range) -> ListeningStats {
        ListeningStats.compute(range: range, listens: listens, plays: plays, firstListen: date(10, 10, 0),
                               tracks: tracks, now: date(10, 17, 12), calendar: calendar)
    }

    @Test func weekUsesListenedTimeAndCountsSkips() {
        let stats = compute(.week)
        #expect(stats.totalSeconds == 425)
        #expect(stats.plays == 2)
        #expect(stats.skips == 2)
        #expect(stats.distinctTracks == 2)
        #expect(stats.topTracks.map(\.trackID) == [1, 2])
        #expect(stats.topTracks.first?.seconds == 390)
        #expect(stats.topTracks.first?.plays == 2)
        #expect(stats.topArtists.map(\.title) == ["A"])
        #expect(stats.topAlbums.map(\.title) == ["X"])
        #expect(stats.mostSkipped.map(\.trackID) == [2])
        #expect(stats.mostSkipped.first?.skips == 2)
        #expect(stats.hourly[9] == 390)
        #expect(stats.hourly[22] == 20)
        #expect(stats.hourly[8] == 15)
        // Seven days in the range, so each weekday occurs once and its average is its total.
        let thursday = calendar.component(.weekday, from: date(10, 15)) - 1
        #expect(stats.weekdayAverages[thursday] == 200)
        #expect(stats.estimatedBefore == date(10, 10, 0))
    }

    @Test func allTimeEstimatesPlaysFromBeforeTheListenLog() {
        let stats = compute(.all)
        #expect(stats.totalSeconds == 525, "425 s listened plus a 100 s track played before the log")
        #expect(stats.plays == 3)
        #expect(stats.topArtists.map(\.title) == ["A", "B"])
        #expect(stats.days[calendar.startOfDay(for: date(9, 1))] == 100)
        #expect(stats.days[calendar.startOfDay(for: date(10, 16))] == 210)
    }

    @Test func calendarAlwaysCoversTheLastYear() {
        let stats = compute(.week)
        #expect(stats.days[calendar.startOfDay(for: date(9, 1))] == 100, "outside the range, but in the calendar")
        #expect(stats.calendarStart <= calendar.date(byAdding: .day, value: -364, to: date(10, 17, 0))!)
        #expect(calendar.component(.weekday, from: stats.calendarStart) == calendar.firstWeekday)
    }

    @Test func emptyWithoutPlays() {
        let stats = ListeningStats.compute(range: .month, listens: [], plays: [], firstListen: nil, tracks: tracks,
                                           now: date(10, 17), calendar: calendar)
        #expect(stats.isEmpty)
        #expect(stats.estimatedBefore == nil)
    }
}

@Suite struct ArtistMatchingTests {
    @Test func normalizedTitlesIgnoreEditionsAndPunctuation() {
        #expect(DiscographyMatch.normalizedTitle("Geogaddi (Deluxe Edition)") == "geogaddi")
        #expect(DiscographyMatch.normalizedTitle("Tomorrow’s Harvest") == DiscographyMatch.normalizedTitle("Tomorrow's Harvest"))
        #expect(DiscographyMatch.normalizedTitle("Selected Ambient Works 85–92") == DiscographyMatch.normalizedTitle("Selected Ambient Works 85-92"))
        #expect(DiscographyMatch.normalizedTitle("Rock & Roll") == "rock and roll")
        #expect(DiscographyMatch.normalizedTitle("[Untitled]") == "untitled", "a title that's all brackets is kept")
    }

    @Test func matchesLibraryAlbums() {
        let library = DiscographyMatch.libraryTitles([
            "Music Has The Right To Children [Remastered]", "Twoism EP", "Hi", "Geogaddi",
        ])
        #expect(DiscographyMatch.match("Music Has the Right to Children", in: library) == "Music Has The Right To Children [Remastered]")
        #expect(DiscographyMatch.match("Twoism", in: library) == "Twoism EP", "one title starting with the other")
        #expect(DiscographyMatch.match("Geogaddi", in: library) == "Geogaddi")
        #expect(DiscographyMatch.match("Hi Scores", in: library) == nil, "too short a prefix to count")
        #expect(DiscographyMatch.match("The Campfire Headphase", in: library) == nil)
    }

    @Test func artistIndexMergesSpellings() {
        func track(_ id: Int64, artist: String, albumArtist: String = "", album: String = "") -> Track {
            let track = Track(id: id)
            track.artist = artist
            track.albumArtist = albumArtist
            track.album = album
            return track
        }
        let index = ArtistIndex(tracks: [
            track(1, artist: "Boards of Canada", album: "Geogaddi"),
            track(2, artist: "Boards of Canada", album: "Geogaddi"),
            track(3, artist: "boards of canada", album: "Twoism"),
            track(4, artist: "Beatles", albumArtist: "The Beatles", album: "Help!"),
            track(5, artist: "Guest", albumArtist: "Boards of Canada", album: "Remixes"),
        ])
        let boc = index.artist(named: "BOARDS OF CANADA")
        #expect(boc?.name == "Boards of Canada", "the most common spelling")
        #expect(boc?.trackCount == 4, "artist or album artist")
        #expect(boc?.albumCount == 3)
        #expect(index.artist(named: "The Beatles")?.trackCount == 1, "a leading The is ignored, and a track counts once")
        #expect(index.artists.map(\.name) == ["Beatles", "Boards of Canada", "Guest"])
    }

    @MainActor @Test func comparableNamesAndSoulseekQueries() {
        #expect(ArtistPageModel.comparableName("The Beatles") == ArtistPageModel.comparableName("Beatles"))
        #expect(ArtistPageModel.comparableName("AC/DC") == ArtistPageModel.comparableName("AC DC"))
        #expect(AppModel.soulseekQuery(artist: "Boards of Canada", title: "Tomorrow’s Harvest (Deluxe)") == "Boards of Canada Tomorrows Harvest")
        #expect(AppModel.soulseekQuery(artist: "A Tribe Called Quest", title: "Vol. 2") == "Tribe Called Quest Vol 2")
        #expect(AppModel.soulseekQuery(artist: "Aphex Twin", title: "") == "Aphex Twin")
    }

    @Test func releaseGroupsDecodeFromMusicBrainzJSON() throws {
        let json = """
            {"id":"a","title":"Geogaddi","primary-type":"Album","secondary-types":[],"first-release-date":"2002-02-18"}
            """
        let group = try JSONDecoder().decode(MBReleaseGroup.self, from: Data(json.utf8))
        #expect(group.year == 2002)
        #expect(group.isMainRelease)
        let live = try JSONDecoder().decode(MBReleaseGroup.self, from: Data("""
            {"id":"b","title":"Live","primary-type":"Album","secondary-types":["Live"]}
            """.utf8))
        #expect(!live.isMainRelease)
        #expect(live.typeLabel == "Album · Live")
    }
}

@Suite struct ListenLogTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.sqlite")
    let store: LibraryStore
    let ids: [Int64]

    init() throws {
        store = try LibraryStore(url: url)
        try store.insert((1...2).map { ScannedTrack(path: "/music/\($0).mp3", title: "Track \($0)") })
        ids = try store.loadTracks().sorted { $0.title < $1.title }.map(\.id)
    }

    @Test func listensRoundTripAndCountSkips() throws {
        let first = ListenRecord(trackID: ids[0], startedAt: Date(timeIntervalSince1970: 100), seconds: 12.5, position: 13, outcome: .skipped)
        try store.recordListen(first)
        try store.recordListen(ListenRecord(trackID: ids[0], startedAt: Date(timeIntervalSince1970: 200), seconds: 30, position: 30, outcome: .finished))
        try store.recordListen(ListenRecord(trackID: ids[1], startedAt: Date(timeIntervalSince1970: 300), seconds: 2, position: 2, outcome: .skipped))
        #expect(try store.listens(since: nil).first == first)
        #expect(try store.listens(since: Date(timeIntervalSince1970: 150)).map(\.startedAt.timeIntervalSince1970) == [200, 300])
        #expect(try store.skipCounts() == [ids[0]: 1, ids[1]: 1])
        #expect(try store.firstListenDate() == Date(timeIntervalSince1970: 100))
        try store.deleteTracks([ids[1]])
        #expect(try store.listens(since: nil).count == 2, "a removed track's listens go with it")
        try store.clearListens()
        #expect(try store.listens(since: nil).isEmpty)
    }

    @Test func artistLinksRoundTrip() throws {
        try store.setArtistMBID("abc", forKey: "boards of canada")
        #expect(try store.artistMBID(forKey: "boards of canada") == "abc")
        try store.setArtistMBID(nil, forKey: "boards of canada")
        #expect(try store.artistMBID(forKey: "boards of canada") == nil)
    }

    @Test func upgradingFromVersion2AddsTheListenLog() throws {
        try store.recordPlay(trackID: ids[0], at: Date(timeIntervalSince1970: 50))
        try store.db.execute("""
            DROP TABLE listen; DROP TABLE artist_link; DROP TABLE unreadable_file;
            ALTER TABLE track DROP COLUMN musical_key; ALTER TABLE track DROP COLUMN file_mtime; PRAGMA user_version = 2;
            """)
        let reopened = try LibraryStore(url: url)
        #expect(try reopened.listens(since: nil).isEmpty)
        #expect(try reopened.plays(since: nil).map(\.trackID) == [ids[0]], "history is kept")
    }

    @Test func skipsSearchScope() {
        let track = Track(id: 1)
        track.skipCount = 3
        #expect(SearchQuery("skips:>2").matches(track))
        #expect(!SearchQuery("skips:0").matches(track))
        #expect(SearchQuery("skipcount:3").matches(track))
    }
}

/// The player's listen log, on generated audio at zero volume.
@MainActor
@Suite(.serialized) struct PlayerListenTests {
    let tracks: [Track]

    init() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        tracks = try (1...2).map { number in
            let url = folder.appendingPathComponent("\(number).wav")
            try ToneFile.write(to: url, seconds: 3.0, frequency: 220 * Double(number))
            let track = Track(id: Int64(number))
            track.path = url.path
            track.length = 3.0
            return track
        }
    }

    private func waitUntil(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func makePlayer(_ log: @escaping (ListenRecord) -> Void) -> Player {
        let player = Player()
        player.volume = 0
        player.repeatMode = .off
        player.setShuffle(false)
        player.onListenEnded = { _, listen in log(listen) }
        return player
    }

    @Test func skippingThenFinishing() async {
        var listens: [ListenRecord] = []
        let player = makePlayer { listens.append($0) }
        player.play(tracks, startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 1.3 })
        player.next()
        #expect(await waitUntil { player.currentTrack == nil }, "plays the second track to the end")

        #expect(listens.map(\.trackID) == [1, 2])
        #expect(listens.map(\.outcome) == [.skipped, .finished])
        #expect((1.2...2.5).contains(listens[0].seconds), "listened \(listens[0].seconds)s before skipping")
        #expect((2.5...3.6).contains(listens[1].seconds), "listened \(listens[1].seconds)s of 3")
        #expect(listens[0].position < 2.5)
    }

    @Test func pausesDontCountAndStoppingEndsTheListen() async {
        var listens: [ListenRecord] = []
        let player = makePlayer { listens.append($0) }
        player.play([tracks[0]], startingAt: 0)
        #expect(await waitUntil { player.isPlaying && player.currentTime > 1.0 })
        player.togglePlayPause()
        try? await Task.sleep(for: .seconds(1.2))
        player.togglePlayPause()
        try? await Task.sleep(for: .seconds(0.4))
        player.stop()

        #expect(listens.count == 1)
        #expect(listens.first?.outcome == .stopped)
        let seconds = listens.first?.seconds ?? 0
        #expect((1.2...2.2).contains(seconds), "\(seconds)s counted; the 1.2 s pause shouldn't be")
    }

    @Test func listensUnderASecondAreDropped() async {
        var listens: [ListenRecord] = []
        let player = makePlayer { listens.append($0) }
        player.play(tracks, startingAt: 0)
        #expect(await waitUntil { player.isPlaying })
        player.next()
        #expect(await waitUntil { player.currentTrack?.id == 2 && player.isPlaying })
        player.stop()
        #expect(listens.isEmpty, "\(listens)")
    }
}
