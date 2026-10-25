import Foundation
import Testing
@testable import Susurrus

@Suite struct SearchQueryTests {
    private let aphex = Track(id: 1)

    init() {
        aphex.title = "Xtal"
        aphex.artist = "Aphex Twin"
        aphex.album = "Selected Ambient Works 85–92"
        aphex.genre = "Ambient"
        aphex.year = 1992
        aphex.bpm = 124
        aphex.rating = 4.5
        aphex.playCount = 3
        aphex.length = 291
        aphex.path = "/Volumes/Music/Aphex Twin/01 Xtal.flac"
        aphex.dateAdded = Date(timeIntervalSinceNow: -5 * 86_400)
    }

    @Test func plainWordsAllHaveToMatch() {
        #expect(SearchQuery("aphex ambient").matches(aphex))
        #expect(!SearchQuery("aphex techno").matches(aphex))
        #expect(SearchQuery("aphex -techno").matches(aphex))
        #expect(!SearchQuery("aphex -xtal").matches(aphex))
        #expect(SearchQuery("\"aphex twin\"").matches(aphex))
        #expect(!SearchQuery("\"twin aphex\"").matches(aphex))
    }

    @Test func keyScopesMatchTheKeyOrItsNeighbours() {
        aphex.musicalKey = "Am"
        #expect(SearchQuery("key:8A").matches(aphex))
        #expect(SearchQuery("key:am").matches(aphex))
        #expect(!SearchQuery("key:9A").matches(aphex))
        #expect(SearchQuery("key:~9A").matches(aphex))
        #expect(SearchQuery("key:~C").matches(aphex))
        #expect(!SearchQuery("key:~10A").matches(aphex))
        aphex.musicalKey = ""
        #expect(!SearchQuery("key:~8A").matches(aphex))
    }

    @Test func textScopesLookAtOneField() {
        #expect(SearchQuery("artist:\"aphex twin\"").matches(aphex))
        #expect(!SearchQuery("title:aphex").matches(aphex))
        #expect(SearchQuery("album:selected genre:amb").matches(aphex))
        #expect(SearchQuery("kind:flac").matches(aphex))
        #expect(!SearchQuery("-kind:flac").matches(aphex))
    }

    @Test func numberScopesCompare() {
        #expect(SearchQuery("bpm:120-128").matches(aphex))
        #expect(!SearchQuery("bpm:125-130").matches(aphex))
        #expect(SearchQuery("rating:>=4").matches(aphex))
        #expect(!SearchQuery("rating:5").matches(aphex))
        #expect(SearchQuery("year:<2000 plays:3").matches(aphex))
        #expect(SearchQuery("time:4:00-5:00").matches(aphex))
        #expect(!SearchQuery("time:>5:00").matches(aphex))
    }

    @Test func dateScopesMeasureAge() {
        #expect(SearchQuery("added:7d").matches(aphex))
        #expect(!SearchQuery("added:2d").matches(aphex))
        #expect(SearchQuery("added:>2d").matches(aphex))
        #expect(SearchQuery("played:>1y").matches(aphex), "never played counts as older than anything")
        #expect(!SearchQuery("played:30d").matches(aphex))
    }

    @Test func unknownScopesAreJustWords() {
        let query = SearchQuery("re:mix")
        #expect(query.terms == [.init(condition: .anywhere("re:mix"))])
        #expect(SearchQuery("bpm:fast").terms == [.init(condition: .anywhere("bpm:fast"))])
    }
}

@Suite struct DuplicatesTests {
    private func track(_ id: Int64, _ artist: String, _ title: String, length: Double) -> Track {
        let track = Track(id: id)
        track.artist = artist
        track.title = title
        track.length = length
        return track
    }

    @Test func groupsSameArtistAndTitleWithCloseLengths() {
        let tracks = [
            track(1, "Neu!", "Hallogallo", length: 600),
            track(2, "NEU", "Hallogallo.", length: 601.5),  // case, punctuation
            track(3, "Neu!", "Hallogallo", length: 400),    // a different edit
            track(4, "Can", "Vitamin C", length: 210),
            track(5, "Can", "Vitamin C", length: 211),
            track(6, "Can", "Halleluwah", length: 1110),
            track(7, "Somebody", "", length: 100),
            track(8, "Somebody", "", length: 100),          // no title: never a duplicate
        ]
        let found = Duplicates.find(in: tracks).map(\.id)
        #expect(found == [4, 5, 1, 2])
    }
}

@Suite struct MissingFilesTests {
    @Test func unmountedVolumesAreOfflineNotMissing() {
        let existing: Set<String> = ["/Volumes/Music", "/Volumes/Music/a.mp3", "/Users/me/b.mp3"]
        var checked: [String] = []
        let statuses = MissingFiles.check([
            (1, "/Volumes/Music/a.mp3"),
            (2, "/Volumes/Music/gone.mp3"),
            (3, "/Volumes/Share/x.mp3"),
            (4, "/Volumes/Share/y.mp3"),
            (5, "/Users/me/b.mp3"),
            (6, "/Users/me/c.mp3"),
        ], listFolder: { folder in
            existing.filter { ($0 as NSString).deletingLastPathComponent == folder }.map { ($0 as NSString).lastPathComponent }
        }, fileExists: { path in
            checked.append(path)
            return existing.contains(path)
        })
        #expect(statuses == [2: .missing, 3: .offline, 4: .offline, 6: .missing])
        #expect(checked.filter { $0.hasPrefix("/Volumes/Share") } == ["/Volumes/Share"], "one check per unmounted volume")
        #expect(!checked.contains("/Volumes/Music/a.mp3") && !checked.contains("/Users/me/b.mp3"), "listed files aren't asked for one by one")
    }

    @Test func listsEachFolderOnceAndAsksOnlyAboutUnlistedNames() {
        var listed: [String] = []
        var asked: [String] = []
        let statuses = MissingFiles.check([
            (1, "/music/Album/01 One.mp3"),
            (2, "/music/Album/02 Two.mp3"),
            (3, "/music/Album/03 Café.mp3"),   // listed in decomposed form
            (4, "/music/Album/04 Four.MP3"),   // listed in another case
            (5, "/music/Gone/01.mp3"),
            (6, "/music/Gone/02.mp3"),
        ], listFolder: { folder in
            listed.append(folder)
            return folder == "/music/Album" ? ["01 One.mp3", "02 Two.mp3", "03 Cafe\u{301}.mp3", "04 four.mp3"] : nil
        }, fileExists: { path in
            asked.append(path)
            return path == "/music/Album/04 Four.MP3"
        })
        #expect(statuses == [5: .missing, 6: .missing])
        #expect(listed.sorted() == ["/music/Album", "/music/Gone"])
        #expect(asked.sorted() == ["/music/Album/04 Four.MP3", "/music/Gone"])
    }
}

@Suite struct LibraryHousekeepingTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.sqlite")
    let store: LibraryStore
    let ids: [Int64]

    init() throws {
        store = try LibraryStore(url: url)
        try store.insert((1...3).map { ScannedTrack(path: "/music/\($0).mp3", title: "Track \($0)") })
        ids = try store.loadTracks().sorted { $0.title < $1.title }.map(\.id)
    }

    @Test func historyListsEveryPlayNewestFirst() throws {
        try store.recordPlay(trackID: ids[0], at: Date(timeIntervalSince1970: 100))
        try store.recordPlay(trackID: ids[1], at: Date(timeIntervalSince1970: 200))
        try store.recordPlay(trackID: ids[0], at: Date(timeIntervalSince1970: 300))
        #expect(try store.historyTrackIDs(limit: 10) == [ids[0], ids[1], ids[0]])
        #expect(try store.historyTrackIDs(limit: 2) == [ids[0], ids[1]])
        try store.clearHistory()
        #expect(try store.historyTrackIDs(limit: 10).isEmpty)
        #expect(try store.loadTracks().first { $0.id == ids[0] }?.playCount == 2, "clearing history keeps play counts")
    }

    @Test func upgradingSeedsHistoryFromLastPlayed() throws {
        try store.db.execute("""
            DROP TABLE play_history; DROP TABLE tag_write_queue; DROP TABLE listen; DROP TABLE artist_link;
            DROP TABLE unreadable_file; ALTER TABLE track DROP COLUMN musical_key; ALTER TABLE track DROP COLUMN file_mtime;
            UPDATE track SET last_played = 500 WHERE title = 'Track 2';
            PRAGMA user_version = 1;
            """)
        let reopened = try LibraryStore(url: url)
        #expect(try reopened.historyTrackIDs(limit: 10) == [ids[1]])
    }

    @Test func deletingTracksTakesTheirPlaylistEntriesAndHistory() throws {
        let playlist = try store.createPlaylist(named: "Mix", trackIDs: [ids[0], ids[1], ids[0]])
        try store.recordPlay(trackID: ids[0], at: Date())
        try store.deleteTracks([ids[0]])
        #expect(try store.loadTracks().map(\.id).sorted() == [ids[1], ids[2]])
        #expect(try store.trackIDs(inPlaylist: playlist) == [ids[1]])
        #expect(try store.historyTrackIDs(limit: 10).isEmpty)
    }

    @Test func pendingTagWritesRoundTrip() throws {
        let values = TagValues(title: "New", track: .init(number: 3, total: 12), rating: 4.5)
        try store.savePendingTagWrite(values, forPath: "/music/1.mp3")
        try store.savePendingTagWrite(TagValues(artist: "X"), forPath: "/music/2.mp3")
        try store.savePendingTagWrite(nil, forPath: "/music/2.mp3")
        let pending = try store.pendingTagWrites()
        #expect(pending.count == 1)
        #expect(pending.first?.path == "/music/1.mp3")
        #expect(pending.first?.values == values)
    }

    @Test func editsKnowTheValuesTheyReplace() {
        let track = Track(id: 1)
        track.title = "Old"
        track.rating = 2
        track.year = 1980
        let edit = TrackEdit(title: "New", rating: 5)
        #expect(edit.currentValues(in: track) == TrackEdit(title: "Old", rating: 2))
    }
}

@MainActor
@Suite struct TagWriteQueuePersistenceTests {
    @Test func savedEntriesFollowTheQueue() async {
        let queue = TagWriteQueue(retryDelay: .milliseconds(10)) { _, _ in
            try await Task.sleep(for: .milliseconds(20))
            return .written(fileSize: 1)
        }
        var saved: [String: TagValues] = [:]
        queue.persist = { path, values in saved[path] = values }

        queue.enqueue(TagValues(title: "A"), path: "/x/a.mp3")
        queue.enqueue(TagValues(rating: 3), path: "/x/a.mp3")
        #expect(saved["/x/a.mp3"] == TagValues(title: "A", rating: 3), "merged values are what's saved")
        await queue.waitUntilIdle()
        #expect(saved.isEmpty, "written files are forgotten")
    }
}

@Suite struct SharedFileListTests {
    private func payload(_ folders: [(String, [String])]) throws -> Data {
        var writer = SlskWriter()
        writer.u32(UInt32(folders.count))
        for (path, files) in folders {
            writer.string(path)
            writer.u32(UInt32(files.count))
            for name in files {
                writer.u8(1)
                writer.string(name)
                writer.u64(1000)
                writer.string("")
                writer.u32(2)
                writer.u32(0); writer.u32(320)
                writer.u32(1); writer.u32(200)
            }
        }
        writer.u32(0)
        return try SlskZlib.deflate(writer.data)
    }

    @Test func joinsBareFileNamesOntoTheirFolder() throws {
        let list = try SlskSharedFileList(parsing: try payload([
            (#"Music\Artist\Album"#, ["01 A.mp3", "02 B.mp3"]),
            (#"Music\Other"#, [#"Music\Other\03 C.mp3"#]),
        ]), username: "someone")
        #expect(list.folders.map(\.path) == [#"Music\Artist\Album"#, #"Music\Other"#])
        #expect(list.fileCount == 3)
        #expect(list.folders[0].files.map(\.path) == [#"Music\Artist\Album\01 A.mp3"#, #"Music\Artist\Album\02 B.mp3"#])
        #expect(list.folders[1].files[0].path == #"Music\Other\03 C.mp3"#, "full paths are kept as they are")
        #expect(list.folders[0].files[0].bitrate == 320)
        #expect(list.folders[0].files[0].username == "someone")
        #expect(Set(list.folders.flatMap(\.files).map(\.id)).count == 3, "ids are unique across folders")
    }

    @Test func readsSusurrusOwnSharePayload() throws {
        let file = SlskSharedFile(
            virtualPath: #"Music\Artist\Album\01 Song.mp3"#, url: URL(fileURLWithPath: "/tmp/x.mp3"), size: 10,
            bitrate: 256, durationSeconds: 100, sampleRate: nil, bitDepth: nil, isVBR: false, searchText: "")
        var writer = SlskWriter()
        writer.u32(1)
        writer.string(#"Music\Artist\Album"#)
        writer.u32(1)
        writer.fileInfo(file)
        writer.u32(0)
        let list = try SlskSharedFileList(parsing: try SlskZlib.deflate(writer.data), username: "me")
        #expect(list.folders[0].files[0].path == file.virtualPath)
    }

    @Test func formatFilterThresholds() {
        func result(_ name: String, bitrate: Int?) -> SlskSearchResult {
            SlskSearchResult(id: 0, username: "u", path: "x\\" + name, size: 1, bitrate: bitrate, isVBR: false,
                             durationSeconds: nil, sampleRate: nil, bitDepth: nil, slotFree: true, averageSpeed: 0, queueLength: 0)
        }
        let flac = result("a.flac", bitrate: nil)
        let mp3 = result("b.mp3", bitrate: 256)
        #expect(SoulseekModel.FormatFilter.lossless.matches(flac))
        #expect(!SoulseekModel.FormatFilter.lossless.matches(mp3))
        #expect(SoulseekModel.FormatFilter.kbps256.matches(mp3))
        #expect(!SoulseekModel.FormatFilter.kbps320.matches(mp3))
        #expect(SoulseekModel.FormatFilter.kbps320.matches(flac))
    }
}
