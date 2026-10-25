import Foundation
import Testing
@testable import Susurrus

/// Scans and reloads against a throwaway library: tracks keep their objects, rescans take only
/// files that changed (and only the tags they have), and adds made during a scan wait their turn.
@MainActor
@Suite struct LibraryScanningTests {
    let folder: URL
    let model: AppModel
    let store: LibraryStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model = AppModel(libraryURL: folder.appendingPathComponent("Library.sqlite"))
        store = try #require(model.store)
    }

    @Test func reloadingKeepsTheTrackObjects() throws {
        let ids = try store.insert([ScannedTrack(path: "/music/a.mp3", title: "A"), ScannedTrack(path: "/music/b.mp3", title: "B")])
        try model.reload()
        let a = try #require(model.tracksByID[ids[0]])

        try store.update(TrackEdit(title: "A2"), forTracks: [ids[0]])
        try model.reload()
        #expect(model.tracksByID[ids[0]] === a, "the player and open sheets hold on to this object")
        #expect(a.title == "A2")

        let added = try store.insert([ScannedTrack(path: "/music/c.mp3", title: "C")])
        model.refreshTracks(added)
        #expect(model.tracks.count == 3)
        #expect(model.tracksByID[ids[0]] === a)
    }

    @Test func rescansReadOnlyChangedFilesAndKeepTagsTheyLack() async throws {
        let music = folder.appendingPathComponent("Artist/Album")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let one = music.appendingPathComponent("01 One.wav"), two = music.appendingPathComponent("02 Two.wav")
        try ToneFile.write(to: one, seconds: 0.5)
        try ToneFile.write(to: two, seconds: 0.5)

        let first = await model.addToLibrary([folder]).value
        #expect(first.added.count == 2)
        let tracks = first.added.compactMap { model.tracksByID[$0] }.sorted { $0.title < $1.title }
        #expect(tracks.map(\.title) == ["One", "Two"])
        // Edits that live only in the library (the files have no BPM or title tags).
        model.update(TrackEdit(title: "Renamed", bpm: 120), for: tracks, actionName: "Edit Info")

        #expect(await model.addToLibrary([folder]).value.updated.isEmpty, "nothing changed on disk")

        try ToneFile.write(to: two, seconds: 1)
        let second = await model.addToLibrary([folder]).value
        #expect(second.added.isEmpty)
        #expect(second.updated == [tracks[1].id])
        #expect(abs(tracks[1].length - 1) < 0.01, "audio details come from the file")
        #expect(tracks[1].bpm == 120 && tracks[1].title == "Renamed", "the file has no BPM or title of its own to replace them")
        #expect(abs(tracks[0].length - 0.5) < 0.01)
    }

    @Test func unreadableFilesWaitUntilTheyChange() async throws {
        let bad = folder.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: bad)
        #expect(await model.addToLibrary([folder]).value.added.isEmpty)
        // The temp dir is reached through the /var → /private/var symlink, so compare resolved paths.
        #expect(try store.unreadableFiles().keys.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == [bad.resolvingSymlinksInPath().path])

        try ToneFile.write(to: bad, seconds: 0.5)
        #expect(await model.addToLibrary([folder]).value.added.count == 1)
        #expect(try store.unreadableFiles().isEmpty)
    }

    @Test func addsMadeDuringAScanWaitTheirTurn() async throws {
        let a = folder.appendingPathComponent("a"), b = folder.appendingPathComponent("b")
        for (url, name) in [(a, "one.wav"), (b, "two.wav")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try ToneFile.write(to: url.appendingPathComponent(name), seconds: 0.3)
        }
        let first = model.addToLibrary([a])
        let second = model.addToLibrary([b])
        #expect(model.isScanning)
        #expect(await first.value.added.count == 1)
        #expect(await second.value.added.count == 1)
        #expect(model.tracks.count == 2)
        #expect(!model.isScanning)
    }
}

@Suite struct LibraryStoreScanningTests {
    let store: LibraryStore

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.sqlite")
        store = try LibraryStore(url: url)
    }

    @Test func changedFilesOnlyReplaceTagsTheyHave() throws {
        let id = try #require(try store.insert([ScannedTrack(path: "/music/a.mp3", title: "Title", artist: "Artist", genre: "Ambient")]).first)
        try store.update(TrackEdit(bpm: 128), forTracks: [id])

        var reread = ScannedTrack(path: "/music/a.mp3", title: "a", artist: "", genre: "Techno", duration: 61)
        reread.inferred = [.title]
        #expect(try store.updateTags(from: [reread]) == [id])
        let track = try #require(try store.loadTracks().first)
        #expect(track.title == "Title", "a title guessed from the file name doesn't replace a real one")
        #expect(track.artist == "Artist" && track.bpm == 128, "tags the file lacks leave the library's alone")
        #expect(track.genre == "Techno" && track.length == 61)
    }

    @Test func stampsAndUnreadableFiles() throws {
        let id = try #require(try store.insert([ScannedTrack(path: "/music/a.mp3")]).first)
        #expect(try store.fileStamps()["/music/a.mp3"]?.stamp.modified == nil)
        try store.setFileStamps([(id, FileStamp(modified: 100.0, size: 5))])
        #expect(try store.fileStamps()["/music/a.mp3"]?.stamp == FileStamp(modified: 100.0, size: 5))
        try store.noteRewritten(path: "/music/a.mp3", size: 6)
        #expect(try store.fileStamps()["/music/a.mp3"]?.stamp == FileStamp(modified: nil as Double?, size: 6),
                "a file susurrus rewrote is taken as it is at the next rescan")

        try store.noteUnreadable([("/music/x.mp3", FileStamp(modified: 1.0, size: 2))])
        #expect(try store.unreadableFiles() == ["/music/x.mp3": FileStamp(modified: 1.0, size: 2)])
        try store.forgetUnreadable(["/music/x.mp3"])
        #expect(try store.unreadableFiles().isEmpty)
    }

    @Test func nestedTransactionsRollBackOnTheirOwn() throws {
        struct Failure: Error {}
        try store.db.transaction {
            try store.createPlaylist(named: "Kept")
            try? store.db.transaction {
                try store.createPlaylist(named: "Dropped")
                throw Failure()
            }
        }
        #expect(try store.loadPlaylists().map(\.name) == ["Kept"])
    }
}

@Suite struct TextKeyTests {
    @Test func searchIgnoresAccentsAndCase() {
        let track = Track(id: 1)
        track.artist = "Björk"
        track.title = "Jóga"
        #expect(SearchQuery("bjork joga").matches(track))
        #expect(SearchQuery("BJÖRK").matches(track))
        #expect(!SearchQuery("-bjork").matches(track))
    }

    @Test func foldingRules() {
        #expect(TextKey.folded("Ｂｊöｒｋ") == "bjork")
        #expect(TextKey.alphanumerics("AC/DC") == "acdc")
        #expect(TextKey.words("Ain't It Fun?") == "ain t it fun")
        #expect(DiscographyMatch.normalizedTitle("Rock ＆ Roll (Deluxe)") == "rock and roll")
    }

    @Test func snapshotsAreIndependentCopies() {
        let track = Track(id: 7)
        track.title = "Before"
        track.skipCount = 2
        let copy = track.snapshot()
        track.title = "After"
        #expect(copy !== track && copy.id == 7 && copy.title == "Before" && copy.skipCount == 2)
    }
}
