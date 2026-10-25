import Foundation
import Testing
@testable import Susurrus

@Suite struct SlskShareTests {
    private func makeShare() throws -> (folder: URL, cleanup: () -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurrus-share-test-\(UUID().uuidString)")
            .appendingPathComponent("My Music")
        let album = folder.appendingPathComponent("Neu!/Neu! 75")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: album.appendingPathComponent("01 Isi.flac"))
        try Data(repeating: 2, count: 2000).write(to: album.appendingPathComponent("02 Seeland (Live).mp3"))
        try Data(repeating: 3, count: 50).write(to: album.appendingPathComponent("cover.jpg"))  // not audio
        try Data(repeating: 4, count: 500).write(to: folder.appendingPathComponent("loose track.m4a"))
        let root = folder.deletingLastPathComponent()
        return (folder, { try? FileManager.default.removeItem(at: root) })
    }

    @Test func scansOnlyAudioAndBuildsVirtualPaths() throws {
        let (folder, cleanup) = try makeShare()
        defer { cleanup() }

        let snapshot = SlskShareScanner.scan(folder: folder) { path in
            path.hasSuffix(".flac") ? SlskFileAttributes(bitrate: nil, durationSeconds: 212, sampleRate: 44_100, bitDepth: 16) : nil
        }

        #expect(snapshot.files.count == 3)
        #expect(snapshot.folderCount == 2)
        let paths = Set(snapshot.files.map(\.virtualPath))
        #expect(paths.contains(#"My Music\Neu!\Neu! 75\01 Isi.flac"#))
        #expect(paths.contains(#"My Music\loose track.m4a"#))
        #expect(!paths.contains { $0.contains("cover.jpg") })

        let flac = try #require(snapshot.filesByVirtualPath[#"My Music\Neu!\Neu! 75\01 Isi.flac"#])
        #expect(flac.size == 1000)
        #expect(flac.sampleRate == 44_100)
        #expect(flac.bitDepth == 16)
        #expect(flac.isLossless)
    }

    @Test func matchingNeedsEveryWordAndHonorsExclusions() throws {
        let (folder, cleanup) = try makeShare()
        defer { cleanup() }
        let snapshot = SlskShareScanner.scan(folder: folder) { _ in nil }

        #expect(snapshot.matches(query: "neu isi", limit: 50).count == 1)
        #expect(snapshot.matches(query: "NEU! 75", limit: 50).count == 2)
        #expect(snapshot.matches(query: "neu 75 -live", limit: 50).count == 1)
        #expect(snapshot.matches(query: "rammstein", limit: 50).isEmpty)
        #expect(snapshot.matches(query: "a", limit: 50).isEmpty, "too-vague queries are ignored")
        #expect(snapshot.matches(query: "-live", limit: 50).isEmpty, "exclusions alone match nothing")
    }

    @Test func indexMatchesWholeWords() throws {
        let (folder, cleanup) = try makeShare()
        defer { cleanup() }
        let snapshot = SlskShareScanner.scan(folder: folder) { _ in nil }

        #expect(snapshot.matches(query: "seeland live", limit: 50).count == 1)
        #expect(snapshot.matches(query: "seel", limit: 50).isEmpty, "words match whole")
        #expect(snapshot.matches(query: "my music isi", limit: 50).count == 1)
        #expect(snapshot.matches(query: "neu 75 -seeland-live", limit: 50).count == 1)
        #expect(snapshot.matches(query: "neu", limit: 1).count == 1, "the limit holds")
        // Searches no one types aren't answered.
        #expect(snapshot.matches(query: "neu " + String(repeating: "x", count: 300), limit: 50).isEmpty)
        #expect(snapshot.matches(query: Array(repeating: "neu", count: 13).joined(separator: " "), limit: 50).isEmpty)
    }

    /// The share built from library tracks: no disk access (these paths don't exist), library
    /// details advertised, and only files inside the folder and not hidden.
    @Test func libraryTracksAreSharedWithoutTouchingTheDisk() throws {
        let folder = URL(fileURLWithPath: "/Volumes/Nowhere/Music")
        let library = [
            SlskLibraryFile(path: "/Volumes/Nowhere/Music/Artist/Album/01 One.flac", size: 30_000_000,
                            attributes: SlskFileAttributes(durationSeconds: 200, sampleRate: 44_100, bitDepth: 16)),
            SlskLibraryFile(path: "/Volumes/Nowhere/Music/Artist/Album/02 Two.mp3", size: 8_000_000,
                            attributes: SlskFileAttributes(bitrate: 320, durationSeconds: 180)),
            SlskLibraryFile(path: "/Volumes/Nowhere/Other/elsewhere.mp3", size: 1, attributes: SlskFileAttributes()),
            SlskLibraryFile(path: "/Volumes/Nowhere/Music/.hidden/x.mp3", size: 1, attributes: SlskFileAttributes()),
            // Size unknown to the library: left to a walk.
            SlskLibraryFile(path: "/Volumes/Nowhere/Music/Artist/Album/03 Three.mp3", size: 0, attributes: SlskFileAttributes()),
        ]
        let extra = [SlskFoundFile(path: "/Volumes/Nowhere/Music/Loose/track.ogg", size: 500)]

        let snapshot = SlskShareScanner.snapshot(folder: folder, library: library, extra: extra)

        #expect(snapshot.files.map(\.virtualPath) == [
            #"Music\Artist\Album\01 One.flac"#, #"Music\Artist\Album\02 Two.mp3"#, #"Music\Loose\track.ogg"#,
        ])
        #expect(snapshot.folderCount == 2)
        let flac = try #require(snapshot.filesByVirtualPath[#"Music\Artist\Album\01 One.flac"#])
        #expect(flac.size == 30_000_000)
        #expect(flac.sampleRate == 44_100)
        #expect(flac.bitDepth == 16)
        #expect(snapshot.filesByVirtualPath[#"Music\Artist\Album\02 Two.mp3"#]?.bitrate == 320)
        #expect(snapshot.matches(query: "artist two", limit: 10).count == 1)
        #expect(SlskShareScanner.knownPaths(library).count == 4, "all but the unknown size")
    }

    @Test func walksFindOnlyWhatTheLibraryDoesntHave() throws {
        let (folder, cleanup) = try makeShare()
        defer { cleanup() }
        let known = folder.appendingPathComponent("Neu!/Neu! 75/01 Isi.flac").standardizedFileURL.path

        let found = SlskShareScanner.walk(folder, skipping: [known])

        #expect(Set(found.map { ($0.path as NSString).lastPathComponent }) == ["02 Seeland (Live).mp3", "loose track.m4a"])
        #expect(found.first { $0.path.hasSuffix(".m4a") }?.size == 500)
    }

    @Test func walkFindingsAreKeptForTheNextLaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurrus-share-walk-\(UUID().uuidString)/Share.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let walk = SlskShareWalk(folder: "/Music", date: Date(timeIntervalSince1970: 1_700_000_000),
                                 files: [SlskFoundFile(path: "/Music/a.mp3", size: 12)])
        walk.save(to: url)

        let loaded = try #require(SlskShareWalk.load(from: url))
        #expect(loaded.folder == "/Music")
        #expect(loaded.date == walk.date)
        #expect(loaded.files.map(\.path) == ["/Music/a.mp3"])
        #expect(loaded.files.map(\.size) == [12])
    }

    @Test func browsePayloadListsFoldersAndFiles() throws {
        let (folder, cleanup) = try makeShare()
        defer { cleanup() }
        let snapshot = SlskShareScanner.scan(folder: folder) { _ in nil }

        var reader = SlskReader(try SlskZlib.inflate(snapshot.browsePayload))
        let folderCount = try reader.u32()
        #expect(folderCount == 2)
        var seenFiles: [String] = []
        for _ in 0 ..< folderCount {
            let folderPath = try reader.string()
            for _ in 0 ..< (try reader.u32()) {
                #expect(try reader.u8() == 1)
                let name = try reader.string()
                #expect(!name.contains("\\"), "browse entries carry bare file names")
                seenFiles.append(folderPath + "\\" + name)
                _ = try reader.u64()     // size
                _ = try reader.string()  // ext (empty)
                for _ in 0 ..< (try reader.u32()) {
                    _ = try reader.u32()
                    _ = try reader.u32()
                }
            }
        }
        #expect(try reader.u32() == 0)  // trailing unknown
        #expect(seenFiles.count == 3)
        #expect(seenFiles.contains(#"My Music\Neu!\Neu! 75\02 Seeland (Live).mp3"#))
        #expect(Set(seenFiles) == Set(snapshot.files.map(\.virtualPath)), "folder + name is each file's virtual path")

        // susurrus's own browse parser rebuilds the full paths.
        let list = try SlskSharedFileList(parsing: snapshot.browsePayload, username: "me")
        #expect(Set(list.folders.flatMap(\.files).map(\.path)) == Set(snapshot.files.map(\.virtualPath)))
    }

    @Test func emptySnapshotHasAValidBrowsePayload() throws {
        var reader = SlskReader(try SlskZlib.inflate(SlskShareSnapshot.empty.browsePayload))
        #expect(try reader.u32() == 0)
        #expect(try reader.u32() == 0)
    }

    @Test func searchResponseBuilderRoundTripsThroughTheParser() throws {
        let file = SlskSharedFile(
            virtualPath: #"Music\Artist\Album\01 Song.mp3"#,
            url: URL(fileURLWithPath: "/tmp/x.mp3"),
            size: 4_321_000,
            bitrate: 245, durationSeconds: 200, sampleRate: nil, bitDepth: nil, isVBR: true,
            searchText: "music artist album 01 song.mp3"
        )
        let frame = try SlskPeerMessage.fileSearchResponse(
            username: "me", token: 55, files: [file], slotFree: true, averageSpeed: 0, queueLength: 3)

        var frames = SlskFrameBuffer()
        frames.append(frame)
        let payload = try #require(try frames.nextFrame())
        var reader = SlskReader(payload)
        #expect(try reader.u32() == SlskPeerCode.fileSearchResponse.rawValue)

        let parsed = try SlskSearchResponse(parsing: Data(payload.dropFirst(4)))
        #expect(parsed.username == "me")
        #expect(parsed.token == 55)
        #expect(parsed.results.count == 1)
        #expect(parsed.results[0].path == file.virtualPath)
        #expect(parsed.results[0].size == file.size)
        #expect(parsed.results[0].bitrate == 245)
        #expect(parsed.results[0].isVBR)
        #expect(parsed.results[0].durationSeconds == 200)
        #expect(parsed.results[0].slotFree)
        #expect(parsed.results[0].queueLength == 3)
    }
}

@Suite struct SlskDistributedMessageTests {
    @Test func parsesSearchBranchLevelAndRoot() throws {
        var search = SlskWriter()
        search.u8(3)
        search.u32(0)
        search.string("wanter")
        search.u32(1234)
        search.string("some query")
        guard case .search(let user, let token, let query) = try SlskDistribMessage.parse(search.data) else {
            Issue.record("expected search")
            return
        }
        #expect(user == "wanter")
        #expect(token == 1234)
        #expect(query == "some query")

        var level = SlskWriter()
        level.u8(4)
        level.u32(2)
        guard case .branchLevel(2) = try SlskDistribMessage.parse(level.data) else {
            Issue.record("expected branch level 2")
            return
        }

        var root = SlskWriter()
        root.u8(5)
        root.string("rootuser")
        guard case .branchRoot("rootuser") = try SlskDistribMessage.parse(root.data) else {
            Issue.record("expected branch root")
            return
        }
    }

    @Test func parsesEmbeddedSearches() throws {
        var inner = SlskWriter()
        inner.u32(0)
        inner.string("wanter")
        inner.u32(9)
        inner.string("q")

        var embedded = SlskWriter()
        embedded.u8(93)
        embedded.u8(3)
        embedded.raw(inner.data)
        guard case .embedded(let code, let payload) = try SlskDistribMessage.parse(embedded.data),
              code == 3,
              case .search("wanter", 9, "q") = try SlskDistribMessage.parseSearch(payload) else {
            Issue.record("expected embedded search")
            return
        }
    }

    @Test func parsesPossibleParentsAndServerSearches() throws {
        var parents = SlskWriter()
        parents.u32(2)
        parents.string("alpha")
        parents.u32(0x0102_0304)
        parents.u32(2234)
        parents.string("beta")
        parents.u32(0x0A00_0001)
        parents.u32(2235)
        let parsed = try SlskPossibleParents(parsing: parents.data)
        #expect(parsed.parents.count == 2)
        #expect(parsed.parents[0].username == "alpha")
        #expect(parsed.parents[0].host == "1.2.3.4")
        #expect(parsed.parents[1].port == 2235)

        var search = SlskWriter()
        search.string("wanter")
        search.u32(31)
        search.string("artist album")
        let request = try SlskServerSearchRequest(parsing: search.data)
        #expect(request.username == "wanter")
        #expect(request.token == 31)
        #expect(request.query == "artist album")
    }

    @Test func parsesTransferResponses() throws {
        var allowed = SlskWriter()
        allowed.u32(42)
        allowed.bool(true)
        let yes = try SlskTransferResponse(parsing: allowed.data)
        #expect(yes.allowed)
        #expect(yes.token == 42)

        var denied = SlskWriter()
        denied.u32(43)
        denied.bool(false)
        denied.string("Queued")
        let no = try SlskTransferResponse(parsing: denied.data)
        #expect(!no.allowed)
        #expect(no.reason == "Queued")
    }
}
