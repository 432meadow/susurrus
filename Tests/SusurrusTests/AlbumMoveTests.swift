import Foundation
import Testing
@testable import Susurrus

/// Matched downloads moving to the library folder: the copy and its checks, tidying the download
/// folder, the saved queue that waits for a library folder that isn't there, and applying a
/// release to a download. Generated files only; nothing goes to the network.
@MainActor
@Suite struct AlbumMoveTests {
    let base: URL
    let downloads: URL
    let library: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("AlbumMoveTests-\(UUID().uuidString)")
        downloads = base.appendingPathComponent("Downloads", isDirectory: true)
        library = base.appendingPathComponent("Library", isDirectory: true)
        for folder in [downloads, library] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    /// Files of `size` bytes at the paths, relative to `folder`.
    @discardableResult
    func makeFiles(_ paths: [String], in folder: URL, size: Int = 100) throws -> [URL] {
        try paths.map { path in
            let url = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: size).write(to: url)
            return url
        }
    }

    /// Every file under `folder`, hidden ones too, relative to it and sorted.
    func contents(of folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var result: [String] = []
        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            result.append(url.pathComponents.suffix(enumerator.level).joined(separator: "/"))
        }
        return result.sorted()
    }

    func makeModel() -> AppModel {
        let model = AppModel(libraryURL: base.appendingPathComponent("Support/Library.sqlite"))
        model.soulseek.downloadFolderPath = downloads.path
        model.soulseek.matchedAlbums = .moveToLibrary
        model.soulseek.albumFolderPath = library.path
        return model
    }

    /// The settings `makeModel` changes are saved in the test runner's own defaults; clear them.
    func forgetSettings() {
        for key in ["soulseek.downloadFolder", "soulseek.matchedAlbums", "soulseek.albumFolder"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Files

    @Test func copiesAnAlbumAndTidiesTheDownloadFolder() throws {
        let album = downloads.appendingPathComponent("Artist - Album [FLAC]")
        let files = try makeFiles(["CD1/01 a.flac", "CD2/01 b.flac", "cover.jpg", "CD1/cover.jpg", "Scans/front.png", ".DS_Store"], in: album)
        let copy = try AlbumMoveFiles.copy([(1, files[0].path, "1-01 One.flac"), (2, files[1].path, "2-01 Two.flac")],
                                           from: album, to: library, target: "Artist/Album (2004)", isCancelled: { false }, copied: { _ in })
        try AlbumMoveFiles.putInPlace(copy)
        #expect(copy.destination.path == library.appendingPathComponent("Artist/Album (2004)").path)
        #expect(contents(of: copy.destination) == ["1-01 One.flac", "2-01 Two.flac", "Scans/front.png", "cover.jpg"],
                "disc folders flattened, other folders kept, hidden files left out")
        #expect(copy.files.map(\.name) == ["1-01 One.flac", "2-01 Two.flac"] && copy.files.allSatisfy { $0.stamp.size == 100 })
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path) == ["Artist"], "no hidden copy left behind")

        AlbumMoveFiles.removeOriginals(files.prefix(2).map(\.path), folder: album, downloads: downloads)
        #expect(!FileManager.default.fileExists(atPath: album.path), "its covers, scans and .DS_Store went with it")
        #expect(FileManager.default.fileExists(atPath: downloads.path))
    }

    @Test func audioThatDidntMatchKeepsItsDownloadFolder() throws {
        let album = downloads.appendingPathComponent("Album")
        let files = try makeFiles(["01 a.mp3", "02 b.mp3", "cover.jpg"], in: album)
        let copy = try AlbumMoveFiles.copy([(1, files[0].path, "01 A.mp3")], from: album, to: library, target: "A/B",
                                           isCancelled: { false }, copied: { _ in })
        try AlbumMoveFiles.putInPlace(copy)
        AlbumMoveFiles.removeOriginals([files[0].path], folder: album, downloads: downloads)
        #expect(contents(of: album) == ["02 b.mp3", "cover.jpg"])
        #expect(contents(of: copy.destination) == ["01 A.mp3", "cover.jpg"])
    }

    @Test func takenFoldersGetANumberAndStoppedCopiesLeaveNothing() throws {
        let album = downloads.appendingPathComponent("Album")
        let files = try makeFiles(["01 a.mp3"], in: album)
        try FileManager.default.createDirectory(at: library.appendingPathComponent("A/Vol. 2 (2001)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appendingPathComponent(".susurrus-moving-old"), withIntermediateDirectories: true)
        let copy = try AlbumMoveFiles.copy([(1, files[0].path, "01 A.mp3")], from: album, to: library, target: "A/Vol. 2 (2001)",
                                           isCancelled: { false }, copied: { _ in })
        #expect(copy.destination.lastPathComponent == "Vol. 2 (2001) (2)")
        AlbumMoveFiles.discard(copy)
        #expect(throws: CancellationError.self) {
            try AlbumMoveFiles.copy([(1, files[0].path, "01 A.mp3")], from: album, to: library, target: "A/B",
                                    isCancelled: { true }, copied: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.path) == ["A"], "no hidden copies, old or new")

        let outside = try makeFiles(["x.mp3"], in: library)[0]
        AlbumMoveFiles.removeOriginals([outside.path], folder: library, downloads: downloads)
        #expect(FileManager.default.fileExists(atPath: outside.path), "nothing outside the download folder is deleted")
    }

    // MARK: The queue

    @Test func aQueuedAlbumMovesAndTheLibraryFollows() async throws {
        defer { forgetSettings() }
        let model = makeModel()
        let store = try #require(model.store)
        let album = downloads.appendingPathComponent("Artist - Album")
        let files = try makeFiles(["a.wav", "b.wav", "cover.jpg"], in: album)
        let ids = try store.insert(files.prefix(2).map { ScannedTrack(path: $0.path, title: $0.lastPathComponent) })
        try model.reload()
        let first = try #require(model.tracksByID[ids[0]])

        model.queueAlbumMove(AlbumMove(folder: album.path, target: "Artist/Album (2001)", title: "Artist – Album (2001)",
                                       names: [ids[0]: "01 One.wav", ids[1]: "02 Two.wav"]))
        await model.albumMoveTask?.value
        let destination = library.appendingPathComponent("Artist/Album (2001)")
        #expect(contents(of: destination) == ["01 One.wav", "02 Two.wav", "cover.jpg"])
        #expect(first.path == destination.appendingPathComponent("01 One.wav").path, "the same track, at its new place")
        #expect(try store.loadTracks().map(\.path).sorted() == ["01 One.wav", "02 Two.wav"].map { destination.appendingPathComponent($0).path })
        #expect(try store.fileStamps()[first.path]?.stamp.size == 100, "a rescan takes the copies as they are")
        #expect(!FileManager.default.fileExists(atPath: album.path))
        #expect(model.queuedAlbumMoves.isEmpty && model.albumMoveProgress == nil)
    }

    @Test func albumsWaitForALibraryFolderThatIsntThere() async throws {
        defer { forgetSettings() }
        let model = makeModel()
        let share = base.appendingPathComponent("Share/Music", isDirectory: true)  // not mounted yet
        model.soulseek.albumFolderPath = share.path
        let album = downloads.appendingPathComponent("Album")
        let files = try makeFiles(["a.wav"], in: album)
        let ids = try #require(model.store).insert([ScannedTrack(path: files[0].path, title: "A")])
        try model.reload()

        model.queueAlbumMove(AlbumMove(folder: album.path, target: "A/B", title: "A – B", names: [ids[0]: "01 A.wav"]))
        await model.albumMoveTask?.value
        #expect(model.isWaitingForLibraryFolder && model.queuedAlbumMoves.count == 1)
        #expect(model.activities.contains { $0.id == "move" })
        #expect(FileManager.default.fileExists(atPath: files[0].path))
        let saved = try #require(model.albumMovesURL)
        #expect(AlbumMoveFiles.load(from: saved) == model.queuedAlbumMoves, "kept for the next launch")

        try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
        model.moveDownloadedAlbums()  // as a mount does
        await model.albumMoveTask?.value
        #expect(!model.isWaitingForLibraryFolder && model.queuedAlbumMoves.isEmpty)
        #expect(FileManager.default.fileExists(atPath: share.appendingPathComponent("A/B/01 A.wav").path))
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }

    @Test func stoppingLeavesWaitingAlbumsWhereTheyAre() async throws {
        defer { forgetSettings() }
        let model = makeModel()
        model.soulseek.albumFolderPath = base.appendingPathComponent("Nowhere").path
        let album = downloads.appendingPathComponent("Album")
        let files = try makeFiles(["a.wav"], in: album)
        _ = try #require(model.store).insert([ScannedTrack(path: files[0].path, title: "A")])
        try model.reload()

        model.queueAlbumMove(AlbumMove(folder: album.path, target: "A/B", title: "A – B", names: [:]))
        await model.albumMoveTask?.value
        model.stopMovingAlbums()
        #expect(model.queuedAlbumMoves.isEmpty && !model.isWaitingForLibraryFolder)
        #expect(!FileManager.default.fileExists(atPath: try #require(model.albumMovesURL).path))
        #expect(FileManager.default.fileExists(atPath: files[0].path))
    }

    @Test func applyingAReleaseToADownloadMovesItOnceItsTagsAreWritten() async throws {
        defer { forgetSettings() }
        let model = makeModel()
        let store = try #require(model.store)
        let release = try ReleaseLookupTests.release()
        let album = downloads.appendingPathComponent("Aphex Twin - SAW")
        let files = try makeFiles(["CD1/01.wav", "CD1/02.wav", "CD1/03.wav", "CD2/01.wav", "CD2/02.wav"], in: album)
        let titles = ["Cliffs", "Radiator", "Rhubarb", "Hankie", "Grass"], lengths = [445.0, 300, 466, 210, 400]
        let ids = try store.insert(files.indices.map { index in
            ScannedTrack(path: files[index].path, title: titles[index], trackNumber: index < 3 ? index + 1 : index - 2,
                         discNumber: index < 3 ? 1 : 2, duration: lengths[index])
        })
        try model.reload()
        let tracks = ids.compactMap { model.tracksByID[$0] }
        let match = ReleaseMatcher.match(tracks.map(ReleaseMatcher.Input.init), to: release)
        #expect(match.isConfident)

        await model.applyRelease(match, to: tracks, fields: .all, cover: nil, isDownload: true, filing: .library, registersUndo: false)
        #expect(model.queuedAlbumMoves.count == 1)
        await model.albumMoveTask?.value
        let destination = library.appendingPathComponent(
            ReleaseMatcher.albumFolderPath(albumArtist: "Aphex Twin", album: release.title, year: release.year))
        #expect(contents(of: destination) == ["1-01 Cliffs.wav", "1-02 Radiator.wav", "1-03 Rhubarb.wav", "2-01 Hankie.wav", "2-02 Grass (Live).wav"])
        #expect(tracks.allSatisfy { $0.path.hasPrefix(destination.path + "/") })
        #expect(tracks.allSatisfy { !model.tagWriter.isWriting($0.path) }, "the tags went into the downloaded files first")
        #expect(!FileManager.default.fileExists(atPath: album.path))
    }

    // MARK: Settings and the tag queue

    @Test func theChoiceFromBeforeThereWasOne() {
        #expect(SoulseekModel.matchedAlbums(stored: nil, sorted: nil) == .moveToLibrary)
        #expect(SoulseekModel.matchedAlbums(stored: nil, sorted: true) == .sort)
        #expect(SoulseekModel.matchedAlbums(stored: nil, sorted: false) == .leave)
        #expect(SoulseekModel.matchedAlbums(stored: "leave", sorted: true) == .leave)
        #expect(SoulseekModel.matchedAlbums(stored: "nonsense", sorted: nil) == .moveToLibrary)
    }

    @Test func theTagQueueKnowsWhichFilesItIsWriting() async {
        let queue = TagWriteQueue(retryDelay: .milliseconds(10)) { _, _ in
            try await Task.sleep(for: .milliseconds(100))
            return .unchanged
        }
        queue.enqueue(TagValues(title: "A"), path: "/a.mp3")
        #expect(queue.isWriting("/a.mp3") && !queue.isWriting("/b.mp3"))
        await queue.waitUntilIdle()
        #expect(!queue.isWriting("/a.mp3"))
    }
}
