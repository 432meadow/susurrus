import AppKit
import Observation

/// Finds the MusicBrainz releases a set of files could be.
enum ReleaseIdentifier {
    /// Searches by artist and album, fetches the track lists of the closest few hits (by track
    /// count), and returns them matched against `inputs`, best first.
    static func candidates(for inputs: [ReleaseMatcher.Input], artist: String, album: String, limit: Int = 4,
                           service: ArtistInfoService = .shared) async throws -> [ReleaseMatcher.Match] {
        var hits = try await service.searchReleases(artist: artist, album: album)
        if hits.isEmpty, !artist.isEmpty {
            hits = try await service.searchReleases(artist: "", album: album)
        }
        let count = inputs.count
        let shortlist = hits.filter { ($0.score ?? 100) >= 50 }
            .sorted { (abs($0.totalTracks - count), -($0.score ?? 0)) < (abs($1.totalTracks - count), -($1.score ?? 0)) }
            .prefix(limit)
        var matches: [ReleaseMatcher.Match] = []
        var lastError: Error?
        for hit in shortlist {
            try Task.checkCancellation()
            do {
                matches.append(ReleaseMatcher.match(inputs, to: try await service.release(hit.id)))
            } catch {
                lastError = error
            }
        }
        if matches.isEmpty, let lastError { throw lastError }
        return ReleaseMatcher.ranked(matches)
    }

    /// The release ID in a MusicBrainz link or a bare ID.
    static func releaseID(in text: String) -> String? {
        let pattern = #/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/#
        return text.firstMatch(of: pattern).map { String($0.output).lowercased() }
    }
}

/// The Look Up Album sheet: candidate releases for a set of tracks, the one picked, and what to apply.
@MainActor
@Observable
final class ReleaseLookup: Identifiable {
    enum Phase: Equatable {
        case searching
        case ready
        case failed(String)
    }

    let id = UUID()
    let tracks: [Track]
    let inputs: [ReleaseMatcher.Input]
    /// For a Soulseek download: where its files go when `organizes` (nil for other tracks).
    let filing: DownloadFiling?

    var artist: String
    var album: String
    var releaseLink = ""
    var phase: Phase = .searching
    var matches: [ReleaseMatcher.Match] = []
    var selectedID: String? {
        didSet { if selectedID != oldValue { loadCover() } }
    }
    var fields: ReleaseMatcher.Fields = .all
    var includesCover = true
    var organizes: Bool
    private(set) var cover: Data?
    private(set) var isLoadingCover = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var coverTask: Task<Void, Never>?

    init(tracks: [Track], filing: DownloadFiling?, organizes: Bool) {
        self.tracks = tracks
        inputs = tracks.map(ReleaseMatcher.Input.init)
        self.filing = filing
        self.organizes = organizes && filing != nil
        let folder = tracks.first.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent } ?? ""
        (artist, album) = ReleaseMatcher.searchTerms(for: inputs, folderName: folder)
    }

    var selected: ReleaseMatcher.Match? { matches.first { $0.id == selectedID } }

    func search() {
        searchTask?.cancel()
        phase = .searching
        let (inputs, artist, album) = (inputs, artist, album)
        searchTask = Task {
            do {
                let found = try await ReleaseIdentifier.candidates(for: inputs, artist: artist, album: album)
                guard !Task.isCancelled else { return }
                matches = found
                selectedID = found.first?.id
                phase = found.isEmpty ? .failed("MusicBrainz has no release called “\(album)”\(artist.isEmpty ? "" : " by \(artist)").") : .ready
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Adds the release a pasted MusicBrainz link (or ID) points at, and picks it.
    func useLink() {
        guard let mbid = ReleaseIdentifier.releaseID(in: releaseLink) else {
            phase = .failed("That isn't a MusicBrainz release link.")
            return
        }
        searchTask?.cancel()
        phase = .searching
        let inputs = inputs
        searchTask = Task {
            do {
                let match = ReleaseMatcher.match(inputs, to: try await ArtistInfoService.shared.release(mbid))
                guard !Task.isCancelled else { return }
                matches.removeAll { $0.id == match.id }
                matches.insert(match, at: 0)
                selectedID = match.id
                releaseLink = ""
                phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func loadCover() {
        coverTask?.cancel()
        cover = nil
        guard let release = selected?.release else { return }
        isLoadingCover = true
        coverTask = Task {
            let data = await AppModel.frontCover(for: release)
            guard !Task.isCancelled else { return }
            cover = data
            isLoadingCover = false
        }
    }

    func cancel() {
        searchTask?.cancel()
        coverTask?.cancel()
    }
}

/// Find Missing Covers' progress.
struct CoverSearch: Equatable {
    var done = 0
    var total: Int
    var found = 0
}

/// MusicBrainz album lookups, covers from the Cover Art Archive, and tidying Soulseek downloads.
extension AppModel {
    // MARK: Look Up Album

    /// Opens Look Up Album for the tracks (one track stands for its whole album). Files in the
    /// download folder are susurrus's own downloads, wherever the lookup starts: for those it
    /// offers what Settings ▸ Soulseek does with matched albums (moving them to the library
    /// folder, or sorting them into "Artist/Album (Year)").
    func lookUpAlbum(for tracks: [Track]) {
        var tracks = tracks
        if tracks.count == 1, !tracks[0].album.isEmpty { tracks = albumTracks(albumOf: tracks[0]) }
        guard !tracks.isEmpty else { return }
        let isDownload = tracks.allSatisfy { isInDownloadFolder(URL(fileURLWithPath: $0.path)) }
        let filing = downloadFiling
        let lookup = ReleaseLookup(tracks: tracks, filing: isDownload ? (filing == .none ? .sort(downloadFolder) : filing) : nil,
                                   organizes: filing != .none)
        releaseLookup = lookup
        lookup.search()
    }

    /// Look Up Album for a finished Soulseek download's folder.
    func lookUpDownload(folder: URL) {
        let tracks = tracks(under: downloadAlbumFolder(for: folder))
        guard !tracks.isEmpty else { return }
        lookUpAlbum(for: tracks)
    }

    func applyLookup(_ lookup: ReleaseLookup) {
        lookup.cancel()
        releaseLookup = nil
        guard let match = lookup.selected else { return }
        Task {
            await applyRelease(match, to: lookup.tracks, fields: lookup.fields, cover: lookup.includesCover ? lookup.cover : nil,
                               isDownload: lookup.filing != nil, filing: lookup.organizes ? lookup.filing ?? .none : .none)
        }
    }

    /// Applies a release to the tracks: tags (undoable, like Get Info), then the cover. A download
    /// (files susurrus fetched itself) has its tags written into the files even with "Write tags
    /// to files" off, gets a cover.jpg, and by `filing` is sorted into "Artist/Album (Year)"
    /// first, or queued for the library folder once all that is applied.
    /// Returns how many of the tracks (those still in the library) it was applied to.
    @discardableResult
    func applyRelease(_ match: ReleaseMatcher.Match, to tracks: [Track], fields: ReleaseMatcher.Fields, cover: Data?,
                      isDownload: Bool = false, filing: DownloadFiling = .none, registersUndo: Bool = true) async -> Int {
        let tracks = tracks.filter { tracksByID[$0.id] === $0 }
        guard !tracks.isEmpty else { return 0 }
        if case .sort(let root) = filing {
            await organize(tracks, as: match, under: root)
        }
        let edits = ReleaseMatcher.edits(for: match, inputs: tracks.map(ReleaseMatcher.Input.init), fields: fields)
        apply(tracks.compactMap { track in edits[track.id].map { ($0, [track]) } }, actionName: "Look Up Album",
              registersUndo: registersUndo)
        if isDownload, !writesTagsToFiles {
            for track in tracks {
                guard let edit = edits[track.id], !edit.isEmpty else { continue }
                tagWriter.enqueue(TagValues(edit: edit, track: track), path: track.path)
            }
        }
        if let cover {
            setCover(cover, for: tracks, writeToFiles: writesTagsToFiles || isDownload, saveInFolder: isDownload)
        }
        if filing == .library {
            queueLibraryMove(of: tracks, as: match)
        }
        return tracks.count
    }

    /// The Cover Art Archive's front cover for a release, else its release group's.
    nonisolated static func frontCover(for release: MBRelease) async -> Data? {
        if let data = try? await ArtistInfoService.shared.frontCover(mbid: release.id) { return data }
        guard let group = release.releaseGroup?.id else { return nil }
        return try? await ArtistInfoService.shared.frontCover(mbid: group, releaseGroup: true)
    }

    /// Shows `data` as the cover of the tracks' albums, and embeds it in their files and/or saves
    /// it as cover.jpg next to them.
    func setCover(_ data: Data, for tracks: [Track], writeToFiles: Bool, saveInFolder: Bool = false) {
        for key in Set(tracks.map(\.albumKey)) {
            do {
                try ArtworkStore.shared.setCover(data, for: key)
            } catch {
                EventLog.shared.log("Couldn't save a cover: \(error.localizedDescription)")
            }
        }
        if writeToFiles {
            for track in tracks where TagFormats.canWrite(path: track.path) {
                tagWriter.enqueue(TagValues(artwork: Artwork(data: data)), path: track.path)
            }
        }
        if saveInFolder {
            let artwork = Artwork(data: data)
            for folder in Set(tracks.map { ($0.path as NSString).deletingLastPathComponent }) where ArtworkStore.folderImage(in: folder) == nil {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(artwork.isPNG ? "cover.png" : "cover.jpg")
                do {
                    try data.write(to: url, options: .withoutOverwriting)
                } catch {
                    EventLog.shared.log("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Organizing downloads

    /// Moves the tracks into "Album Artist/Album (Year)" under `root`, renamed "03 Title.ext"
    /// after the release, and brings along the rest of their folders (cover, cue sheet, log) once
    /// no audio is left there. Skipped while any of them is playing. The moves run off the main
    /// thread: the download folder can be on a slow share.
    private func organize(_ tracks: [Track], as match: ReleaseMatcher.Match, under root: URL) async {
        guard !tracks.contains(where: { tagWriter.isInUse($0.path) }) else {
            EventLog.shared.log("Didn't move “\(match.release.title)”: a track is playing")
            return
        }
        let release = match.release
        let target = ReleaseMatcher.albumFolder(under: root, albumArtist: release.isVariousArtists ? "Various Artists" : release.artist,
                                                album: release.title, year: release.year)
        let files = tracks.map { track in
            (id: track.id, path: track.path,
             name: match.pairs[track.id].map { ReleaseMatcher.fileName(for: $0.slot, extension: (track.path as NSString).pathExtension) })
        }
        let moves = await BlockingIO.library.run { Self.moveFiles(files, into: target, root: root) }
        guard !moves.isEmpty else { return }
        let saved: Void? = perform("Couldn't note where the files moved") { store in
            try store.db.transaction {
                for move in moves { try store.updatePath(move.path, bookmark: move.bookmark, forTrack: move.id) }
            }
        }
        guard saved != nil else { return }
        var moved: [String: URL] = [:]
        for move in moves {
            guard let track = tracksByID[move.id] else { continue }
            moved[track.path] = URL(fileURLWithPath: move.path)
            track.path = move.path
        }
        notePathsChanged()
        noteTracksChanged()
        soulseek.noteMoved(moved)
    }

    /// Moves the files into `target` (renamed where a name is given), then the rest of their
    /// folders once no audio is left in them, and removes the folders that empties, up to `root`.
    /// Returns where each file went, with a bookmark to it.
    private nonisolated static func moveFiles(_ files: [(id: Int64, path: String, name: String?)], into target: URL,
                                              root: URL) -> [(id: Int64, path: String, bookmark: Data?)] {
        let fileManager = FileManager.default
        let sources = Set(files.map { URL(fileURLWithPath: $0.path).deletingLastPathComponent().standardizedFileURL })
        let target = sources.contains(target.standardizedFileURL) ? target : unusedURL(target)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            EventLog.shared.log("Couldn't create \(target.path): \(error.localizedDescription)")
            return []
        }

        var moves: [(id: Int64, path: String, bookmark: Data?)] = []
        for file in files {
            let old = URL(fileURLWithPath: file.path)
            var new = target.appendingPathComponent(file.name ?? old.lastPathComponent)
            guard new.standardizedFileURL != old.standardizedFileURL else { continue }
            new = unusedURL(new)
            do {
                try fileManager.moveItem(at: old, to: new)
                moves.append((file.id, new.path, try? new.bookmarkData()))
            } catch {
                EventLog.shared.log("Couldn't move \(old.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // Leftovers (cover images, .cue, .log, .nfo) follow once their folder has no audio left.
        for source in sources where source.standardizedFileURL != target.standardizedFileURL {
            let rest = (try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            guard !rest.contains(where: TagReader.isAudioFile) else { continue }
            for file in rest where !file.lastPathComponent.hasPrefix(".") {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: destination.path) { try? fileManager.moveItem(at: file, to: destination) }
            }
            removeEmptyFolders(from: source, upTo: root)
        }
        return moves
    }

    /// `url`, or "name (2).ext", "name (3).ext"… if something is already there. A folder URL
    /// has no extension: "Vol. 2 (2001)" becomes "Vol. 2 (2001) (2)".
    nonisolated static func unusedURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let isFolder = url.hasDirectoryPath
        let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let ext = isFolder ? "" : url.pathExtension
        for n in 2... {
            let name = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isFolder)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    /// Deletes `folder` and then its parents while they're empty (a .DS_Store doesn't count),
    /// stopping at `root`.
    nonisolated static func removeEmptyFolders(from folder: URL, upTo root: URL) {
        let fileManager = FileManager.default
        var current = folder.standardizedFileURL
        let stop = root.standardizedFileURL.path
        while current.path.hasPrefix(stop + "/") {
            let contents = (try? fileManager.contentsOfDirectory(atPath: current.path)) ?? ["?"]
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            guard (try? fileManager.removeItem(at: current)) != nil else { return }
            current = current.deletingLastPathComponent()
        }
    }

    // MARK: Cleaning up Soulseek downloads

    /// After finished downloads are imported: matches each album folder to a MusicBrainz release and,
    /// when every file fits, fixes the tags, fetches the cover and files it where Settings ▸ Soulseek
    /// says (the library folder, or "Artist/Album (Year)" in the download folder).
    /// Folders that don't match with certainty are left alone, with a notification.
    func cleanUpDownloads(in folders: [URL], after scan: Task<ScanResult, Never>) {
        let albums = Set(folders.map(downloadAlbumFolder))
        Task { [weak self] in
            _ = await scan.value  // the import of these folders
            for album in albums.sorted(by: { $0.path < $1.path }) {
                await self?.cleanUpDownload(album)
            }
        }
    }

    private func cleanUpDownload(_ folder: URL) async {
        guard !cleanedDownloadFolders.contains(folder.path) else { return }
        // Wait for the rest of the album: this runs again when its last file lands.
        guard !soulseek.downloads.contains(where: { $0.isActive && $0.localURL.path.hasPrefix(folder.path + "/") }) else { return }
        let tracks = tracks(under: folder)
        guard !tracks.isEmpty else { return }
        cleanedDownloadFolders.insert(folder.path)

        let inputs = tracks.map(ReleaseMatcher.Input.init)
        let terms = ReleaseMatcher.searchTerms(for: inputs, folderName: folder.lastPathComponent)
        var best: ReleaseMatcher.Match?
        do {
            best = try await ReleaseIdentifier.candidates(for: inputs, artist: terms.artist, album: terms.album).first
        } catch {
            EventLog.shared.log("MusicBrainz lookup for “\(folder.lastPathComponent)”: \(error.localizedDescription)")
        }
        guard let best, best.isConfident else {
            if soulseek.postsNotifications {
                Notifier.post(title: "Couldn't match “\(folder.lastPathComponent)” for sure",
                              body: "Its tags were left as they are. Right-click it in Downloads ▸ Look Up Album… to pick the release.")
            }
            return
        }
        let cover = await Self.frontCover(for: best.release)
        let applied = await applyRelease(best, to: tracks, fields: .all, cover: cover, isDownload: true,
                                         filing: downloadFiling, registersUndo: false)
        guard applied > 0 else {
            EventLog.shared.log("“\(folder.lastPathComponent)” matched on MusicBrainz, but its tracks left the library meanwhile")
            return
        }
        if soulseek.postsNotifications {
            let year = best.release.year.map { " (\($0))" } ?? ""
            Notifier.post(title: "Tagged “\(best.release.artist) – \(best.release.title)\(year)”",
                          body: "\(applied) \(applied == 1 ? "file" : "files") matched on MusicBrainz\(cover == nil ? "" : ", with its cover").")
        }
    }

    /// A download's album folder: "CD1"/"Disc 2" subfolders belong to their parent, unless the
    /// parent is the download folder itself.
    func downloadAlbumFolder(for folder: URL) -> URL {
        let root = URL(fileURLWithPath: soulseek.downloadFolderPath).standardizedFileURL
        let isDiscFolder = folder.lastPathComponent.range(of: #"^(cd|disc|disk)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
        let parent = folder.deletingLastPathComponent().standardizedFileURL
        return isDiscFolder && parent != root ? parent : folder
    }

    /// Library tracks at or under a folder.
    func tracks(under folder: URL) -> [Track] {
        let prefix = folder.standardizedFileURL.path + "/"
        return tracks.filter { $0.path.hasPrefix(prefix) }
    }

    // MARK: Find Missing Covers

    /// Find Missing Covers from the menus. With "Write tags to files" on, it first asks whether
    /// the covers should go into the files too, since that rewrites every track of every album
    /// that gets one (`pendingCoverSearch` drives the question).
    func requestMissingCovers(for albums: [Album]) {
        guard coverSearch == nil, !albums.isEmpty else { return }
        if writesTagsToFiles {
            pendingCoverSearch = albums
        } else {
            findMissingCovers(for: albums, writeToFiles: false)
        }
    }

    /// Looks up a cover for each album that has none (embedded, fetched, or an image in its folder)
    /// by its release group on MusicBrainz, in the background, and embeds what it finds in the
    /// files when `writeToFiles`.
    func findMissingCovers(for albums: [Album], writeToFiles: Bool) {
        pendingCoverSearch = nil
        guard coverSearch == nil, !albums.isEmpty else { return }
        coverSearch = CoverSearch(total: albums.count)
        coverSearchTask = Task { [weak self] in
            var withoutCover = 0
            for album in albums {
                guard !Task.isCancelled, let self else { break }
                if await !ArtworkStore.shared.hasArtwork(album.artworkRequest), !Task.isCancelled {
                    withoutCover += 1
                    if let data = await Self.findCover(for: album), !Task.isCancelled {
                        self.setCover(data, for: album.tracks, writeToFiles: writeToFiles)
                        self.coverSearch?.found += 1
                    }
                }
                self.coverSearch?.done += 1
            }
            guard let self else { return }
            let found = self.coverSearch?.found ?? 0
            self.coverSearch = nil
            self.coverSearchTask = nil
            self.notify(withoutCover == 0
                ? "Every album has a cover"
                : "Found \(found) of \(withoutCover) missing \(withoutCover == 1 ? "cover" : "covers")")
        }
    }

    func stopFindingCovers() {
        coverSearchTask?.cancel()
    }

    /// The albums the tracks belong to.
    func albums(of tracks: [Track]) -> [Album] {
        let keys = Set(tracks.filter { !$0.album.isEmpty }.map(\.albumKey))
        return Album.group(self.tracks.filter { keys.contains($0.albumKey) }, sortedBy: .artist)
    }

    /// The front cover of the release group with the album's exact (normalized) title by its artist.
    private nonisolated static func findCover(for album: Album) async -> Data? {
        let artist = album.artist == "Various Artists" ? "" : (album.pageArtist ?? album.artist)
        guard let groups = try? await ArtistInfoService.shared.searchReleaseGroups(artist: artist, album: album.title) else { return nil }
        let title = DiscographyMatch.normalizedTitle(album.title)
        let artistKey = ArtistIndex.key(for: artist)
        for group in groups.prefix(5) where (group.score ?? 0) >= 80 && DiscographyMatch.normalizedTitle(group.title) == title {
            if !artist.isEmpty, ArtistIndex.key(for: group.artistCredit?.text ?? "") != artistKey { continue }
            if let data = try? await ArtistInfoService.shared.frontCover(mbid: group.id, releaseGroup: true) { return data }
        }
        return nil
    }
}
