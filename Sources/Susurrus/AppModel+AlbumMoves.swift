import Foundation

/// Where a download's files go once a release is applied to them.
enum DownloadFiling: Equatable {
    /// They stay where they are.
    case none
    /// Into "Artist/Album (Year)" in the download folder (its root given), right away.
    case sort(URL)
    /// Into "Artist/Album" in the library folder once their tags are written, and the
    /// downloaded copies are deleted (see `AppModel.moveDownloadedAlbums`).
    case library
}

/// The album being moved to the library folder, for the activity button.
struct AlbumMoveProgress: Equatable {
    var title: String
    var done = 0
    var total: Int
}

/// Moving matched Soulseek downloads to the library folder: each album is copied there as
/// "Artist/Album" and checked, the library is pointed at the copies, and then the download
/// is deleted. While the library folder isn't there (its share isn't mounted), albums wait, saved.
///
/// Once the copy is finished, what comes next is saved in the queue first (`AlbumMove.Commit`). A
/// move cut short after that is picked up by what it left: tracks already pointed at a finished
/// copy go forward, and anything earlier starts over from the download, which is only deleted
/// once the album is safely in its folder.
extension AppModel {
    /// Where albums go in the library: the folder picked in Settings ▸ Soulseek, else the
    /// library's first watched folder.
    var libraryFolder: URL? {
        let path = soulseek.albumFolderPath.isEmpty ? watchedFolders.first ?? "" : soulseek.albumFolderPath
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The library folder, if matched albums are set to move there on their own.
    var albumLibraryFolder: URL? {
        soulseek.matchedAlbums == .moveToLibrary ? libraryFolder : nil
    }

    /// What Settings ▸ Soulseek says to do with a matched download.
    var downloadFiling: DownloadFiling {
        switch soulseek.matchedAlbums {
        case .moveToLibrary: return albumLibraryFolder == nil ? .none : .library
        case .sort: return .sort(downloadFolder)
        case .leave: return .none
        }
    }

    var downloadFolder: URL { URL(fileURLWithPath: soulseek.downloadFolderPath, isDirectory: true) }

    /// Whether a file or folder is inside the download folder: a download that hasn't moved out.
    func isInDownloadFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(downloadFolder.standardizedFileURL.path + "/")
    }

    /// Where the queue is saved: next to the library.
    var albumMovesURL: URL? {
        store.map { $0.url.deletingLastPathComponent().appendingPathComponent("Album moves.json") }
    }

    // MARK: Queue

    /// Queues a download's album for the library folder, named after the release the way a sorted
    /// download is, and starts moving.
    func queueLibraryMove(of tracks: [Track], as match: ReleaseMatcher.Match) {
        let folders = Set(tracks.map { downloadAlbumFolder(for: URL(fileURLWithPath: $0.path).deletingLastPathComponent()).standardizedFileURL })
        guard folders.count == 1, let folder = folders.first, isInDownloadFolder(folder) else {
            EventLog.shared.log("Didn't move “\(match.release.title)” to the library: its files aren't one folder in the download folder")
            return
        }
        queueAlbumMove(albumMove(of: tracks, in: folder, as: match))
    }

    /// The move for an album with a release: the library's "Artist/Album" (or "Compilations/Album"),
    /// files named after the release.
    private func albumMove(of tracks: [Track], in folder: URL, as match: ReleaseMatcher.Match) -> AlbumMove {
        let release = match.release
        let artist = release.isVariousArtists ? "Various Artists" : release.artist
        var names: [Int64: String] = [:]
        for track in tracks {
            guard let pair = match.pairs[track.id] else { continue }
            names[track.id] = ReleaseMatcher.fileName(for: pair.slot, extension: (track.path as NSString).pathExtension)
        }
        return AlbumMove(folder: folder.path,
                         target: TagFiling.libraryPath(artist: artist, album: release.title, isCompilation: release.isVariousArtists),
                         title: "\(artist) – \(release.title)" + (release.year.map { " (\($0))" } ?? ""),
                         names: names)
    }

    /// Queues an album (in place of an earlier entry for its folder) and starts moving. A move
    /// that's already past its copy carries on as it was.
    func queueAlbumMove(_ move: AlbumMove) {
        guard !queuedAlbumMoves.contains(where: { $0.folder == move.folder && $0.commit != nil }) else { return }
        queuedAlbumMoves.removeAll { $0.folder == move.folder }
        queuedAlbumMoves.append(move)
        saveAlbumMoves()
        moveDownloadedAlbums()
    }

    /// Moves the queued albums, one at a time, unless that's under way. While the library folder
    /// isn't there they wait; a mount or the next launch calls this again.
    func moveDownloadedAlbums() {
        guard albumMoveTask == nil, !queuedAlbumMoves.isEmpty else { return }
        albumMoveTask = Task { [weak self] in
            await self?.runAlbumMoves()
            self?.albumMoveTask = nil
        }
    }

    /// Stops moving: the album being copied stays in the download folder, as do those waiting.
    /// One the library already follows has to reach its folder, so that goes on.
    func stopMovingAlbums() {
        queuedAlbumMoves.removeAll { move in move.commit.map { !isFollowed($0) } ?? true }
        saveAlbumMoves()
        isWaitingForLibraryFolder = false
        albumMoveTask?.cancel()
    }

    /// Settings ▸ Soulseek changed where matched albums go.
    func matchedAlbumsChanged() {
        if albumLibraryFolder == nil { stopMovingAlbums() } else { moveDownloadedAlbums() }
    }

    func saveAlbumMoves() {
        guard let url = albumMovesURL else { return }
        do {
            try AlbumMoveFiles.save(queuedAlbumMoves, to: url)
        } catch {
            EventLog.shared.log("Couldn't save the albums waiting to move: \(error.localizedDescription)")
        }
    }

    // MARK: Move to Library

    /// Whether a finished download's folder can be moved now: it's in the download folder, all
    /// its transfers are over, it's in the library, and it isn't on its way already.
    func canMoveDownloadToLibrary(folder: URL) -> Bool {
        let album = downloadAlbumFolder(for: folder).standardizedFileURL
        guard libraryFolder != nil, isInDownloadFolder(album), !preparingAlbumMoves.contains(album.path),
              !queuedAlbumMoves.contains(where: { $0.folder == album.path }),
              !soulseek.downloads.contains(where: { $0.isActive && $0.localURL.path.hasPrefix(album.path + "/") }) else { return false }
        return !tracks(under: album).isEmpty
    }

    /// The download folders of those tracks that can be moved now. Finished downloads aren't kept
    /// between launches, so older ones are only reachable through their tracks.
    func movableDownloadFolders(of tracks: [Track]) -> [URL] {
        let folders = Set(tracks.map { downloadAlbumFolder(for: URL(fileURLWithPath: $0.path).deletingLastPathComponent()).standardizedFileURL })
        return folders.filter(canMoveDownloadToLibrary).sorted { $0.path < $1.path }
    }

    /// Right-click ▸ Move to Library: files a download in the library folder and deletes the
    /// downloaded copy, whatever Settings ▸ Soulseek does with matched albums. With a sure
    /// MusicBrainz match the release's tags and cover go in first; without one the files go by
    /// their own tags, unchanged.
    func moveDownloadToLibrary(folder: URL) {
        guard canMoveDownloadToLibrary(folder: folder) else { return }
        let album = downloadAlbumFolder(for: folder).standardizedFileURL
        let tracks = tracks(under: album)
        preparingAlbumMoves.insert(album.path)
        cleanedDownloadFolders.insert(album.path)  // so it isn't matched and moved a second time
        Task {
            defer { preparingAlbumMoves.remove(album.path) }
            let inputs = tracks.map(ReleaseMatcher.Input.init)
            let terms = ReleaseMatcher.searchTerms(for: inputs, folderName: album.lastPathComponent)
            let best = try? await ReleaseIdentifier.candidates(for: inputs, artist: terms.artist, album: terms.album).first
            let match = best?.isConfident == true ? best : nil
            var cover: Data?
            if let match { cover = await Self.frontCover(for: match.release) }
            await fileDownload(album, tracks: tracks, match: match, cover: cover)
        }
    }

    /// Queues the album for the library folder, by the release when there is one, else by its tags.
    func fileDownload(_ album: URL, tracks: [Track], match: ReleaseMatcher.Match?, cover: Data?) async {
        if let match {
            await applyRelease(match, to: tracks, fields: .all, cover: cover, isDownload: true, registersUndo: false)
            queueAlbumMove(albumMove(of: tracks, in: album, as: match))
            return
        }
        switch TagFiling.plan(for: tracks.map(ReleaseMatcher.Input.init), isCompilation: tracks.contains(where: \.compilation),
                              folderName: album.lastPathComponent) {
        case .plan(let plan):
            queueAlbumMove(AlbumMove(folder: album.path, target: plan.target, title: plan.title, names: plan.names))
        case .noArtist:
            notify("Couldn't tell whose “\(album.lastPathComponent)” is",
                   "Its tags name no artist. Add one with Get Info, then move it again.", kind: .error)
        case .severalAlbums(let albums):
            notify("“\(album.lastPathComponent)” isn't one album",
                   "Its tags name \(albums.count) albums. Give the tracks one album with Get Info, then move it again.", kind: .error)
        }
    }

    // MARK: Moving

    private enum MoveOutcome {
        case done, offline, stopped
        /// Back to square one for this album: it's moved again.
        case startOver
    }

    private func runAlbumMoves() async {
        while let move = queuedAlbumMoves.first, !Task.isCancelled {
            // One that's past its copy goes where it started, whatever the setting says now.
            let committedRoot = move.commit.map { URL(fileURLWithPath: $0.staging).deletingLastPathComponent() }
            guard let root = committedRoot ?? libraryFolder else { return }
            let isThere = await BlockingIO.library.run { AlbumMoveFiles.isFolder(root) }
            isWaitingForLibraryFolder = !isThere
            guard isThere else {
                EventLog.shared.log("\(queuedAlbumMoves.count) album(s) wait for \(root.path)", level: .info)
                return
            }
            switch await moveAlbum(move, to: root) {
            case .done:
                queuedAlbumMoves.removeAll { $0.folder == move.folder }
                saveAlbumMoves()
            case .offline:
                isWaitingForLibraryFolder = true
                return
            case .stopped:
                return
            case .startOver:
                continue
            }
        }
    }

    /// Copies an album to the library folder, checks it, points the library at the copies, then
    /// deletes the downloaded files. It first waits for the album's tag writes (so each file
    /// crosses to the share once, finished) and for none of it to be playing.
    private func moveAlbum(_ move: AlbumMove, to root: URL) async -> MoveOutcome {
        let folder = URL(fileURLWithPath: move.folder, isDirectory: true)
        albumMoveProgress = AlbumMoveProgress(title: move.title, total: move.commit?.files.count ?? tracks(under: folder).count)
        defer { albumMoveProgress = nil }
        if let commit = move.commit { return await resumeMove(move, commit, root: root) }
        while tracks(under: folder).contains(where: { tagWriter.isWriting($0.path) || tagWriter.isInUse($0.path) }) {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return .stopped }
        }
        let albumTracks = tracks(under: folder)
        guard !albumTracks.isEmpty else {
            EventLog.shared.log("Didn't move “\(move.title)”: none of its tracks are in \(folder.path) any more")
            return .done
        }
        albumMoveProgress?.total = albumTracks.count
        let files = albumTracks.map { (id: $0.id, path: $0.path, name: move.names[$0.id] ?? URL(fileURLWithPath: $0.path).lastPathComponent) }
        let target = move.target
        let copied = await BlockingIO.library.run(cancellable: { [weak self] isCancelled in
            Result {
                try AlbumMoveFiles.copy(files, from: folder, to: root, target: target, isCancelled: isCancelled) { done in
                    Task { @MainActor in self?.albumMoveProgress?.done = done }
                }
            }
        })
        let copy: AlbumMoveFiles.Copy
        switch copied {
        case .success(let result): copy = result
        case .failure(is CancellationError): return .stopped
        case .failure(let error): return await moveFailed(move, root: root, error)
        }

        // Edits that came in during the copy went into the downloaded files, not the copy.
        if albumTracks.contains(where: { tagWriter.isWriting($0.path) }) {
            await BlockingIO.library.run { AlbumMoveFiles.discard(copy) }
            return Task.isCancelled ? .stopped : .startOver
        }
        // Stopped just as the copy finished.
        guard queuedAlbumMoves.contains(where: { $0.folder == move.folder }) else {
            await BlockingIO.library.run { AlbumMoveFiles.discard(copy) }
            return .stopped
        }

        let commit = AlbumMove.Commit(staging: copy.staging.path, destination: copy.destination.path,
                                      oldPaths: Dictionary(uniqueKeysWithValues: albumTracks.map { ($0.id, $0.path) }),
                                      files: Dictionary(uniqueKeysWithValues: copy.files.map { ($0.id, $0.name) }))
        do {
            try setCommit(commit, of: move)
        } catch {
            await BlockingIO.library.run { AlbumMoveFiles.discard(copy) }
            return await moveFailed(move, root: root, error)
        }
        return await finishMove(move, commit, stamps: copy.files.map { (id: $0.id, stamp: $0.stamp) }, root: root, isInPlace: false)
    }

    /// Picks up a move that was cut short after its copy was finished, by what it left.
    private func resumeMove(_ move: AlbumMove, _ commit: AlbumMove.Commit, root: URL) async -> MoveOutcome {
        switch await BlockingIO.library.run({ AlbumMoveFiles.progress(of: commit) }) {
        case .staged(let stamps):
            // The tracks still at the download can have changed since it was copied.
            guard isFollowed(commit) else { return await startOver(move, commit) }
            // Something else took that name meanwhile.
            let destination = URL(fileURLWithPath: commit.destination, isDirectory: true)
            var current = commit
            current.destination = await BlockingIO.library.run { AppModel.unusedURL(destination).path }
            do {
                try setCommit(current, of: move)
            } catch {
                return await moveFailed(move, root: root, error)
            }
            return await finishMove(move, current, stamps: stamps, root: root, isInPlace: false)
        case .inPlace(let stamps):
            return await finishMove(move, commit, stamps: stamps, root: root, isInPlace: true)
        case .lost:
            // A share that just dropped looks the same from here.
            guard await BlockingIO.library.run({ AlbumMoveFiles.isFolder(root) }) else { return .offline }
            EventLog.shared.log("The copy of “\(move.title)” is gone; moving it again")
            return await startOver(move, commit)
        }
    }

    /// Back to the downloaded files, which haven't been touched, for a fresh copy.
    private func startOver(_ move: AlbumMove, _ commit: AlbumMove.Commit) async -> MoveOutcome {
        let oldPaths = commit.oldPaths.filter { tracksByID[$0.key] != nil && tracksByID[$0.key]?.path != $0.value }
        guard oldPaths.isEmpty || relink(oldPaths, stamps: nil) else { return .stopped }
        let staging = URL(fileURLWithPath: commit.staging, isDirectory: true)
        await BlockingIO.library.run { try? FileManager.default.removeItem(at: staging) }
        do {
            try setCommit(nil, of: move)
        } catch {
            EventLog.shared.log("Couldn't save the albums waiting to move: \(error.localizedDescription)")
            return .stopped
        }
        return .startOver
    }

    /// From a finished copy to the album in its folder and the download gone. Every step can be
    /// done again, so it's safe to come back to after being cut short at any point.
    private func finishMove(_ move: AlbumMove, _ commit: AlbumMove.Commit, stamps: [(id: Int64, stamp: FileStamp)],
                            root: URL, isInPlace: Bool) async -> MoveOutcome {
        let staging = URL(fileURLWithPath: commit.staging, isDirectory: true)
        let destination = URL(fileURLWithPath: commit.destination, isDirectory: true)
        let folder = URL(fileURLWithPath: move.folder, isDirectory: true)
        let newPaths = commit.newPaths

        // The library follows the album before it appears in the library folder, so a rescan of
        // that folder right then finds its files already known instead of adding them again.
        guard relink(newPaths, stamps: stamps) else {
            if !isInPlace { await BlockingIO.library.run { try? FileManager.default.removeItem(at: staging) } }
            return .done
        }
        if !isInPlace, case .failure(let error) = await BlockingIO.library.run({
            Result { try AlbumMoveFiles.putInPlace(staging: staging, destination: destination) }
        }) {
            _ = relink(commit.oldPaths, stamps: nil)
            // The share dropped: it may have done the rename without saying so. The commit stays,
            // to look at what's there when it's back.
            guard await BlockingIO.library.run({ AlbumMoveFiles.isFolder(root) }) else { return .offline }
            await BlockingIO.library.run { try? FileManager.default.removeItem(at: staging) }
            try? setCommit(nil, of: move)
            return await moveFailed(move, root: root, error)
        }
        let bookmarks = await BlockingIO.library.run { newPaths.compactMapValues { try? URL(fileURLWithPath: $0).bookmarkData() } }
        performQuietly("Couldn't save bookmarks to the moved files") { store in
            try store.db.transaction {
                for (id, bookmark) in bookmarks {
                    guard let path = newPaths[id] else { continue }
                    try store.updatePath(path, bookmark: bookmark, forTrack: id)
                }
            }
        }
        let originals = Array(commit.oldPaths.values), downloads = downloadFolder
        await BlockingIO.library.run { AlbumMoveFiles.removeOriginals(originals, folder: folder, downloads: downloads) }

        var moved: [String: URL] = [:]
        for (id, path) in newPaths {
            if let old = commit.oldPaths[id] { moved[old] = URL(fileURLWithPath: path) }
        }
        soulseek.noteMoved(moved)
        soulseek.rescanShares()
        EventLog.shared.log("Moved “\(move.title)” to \(destination.path)", level: .info)
        if soulseek.postsNotifications {
            Notifier.post(title: "Moved “\(move.title)” to the library", body: destination.path)
        }
        return .done
    }

    /// Whether the library already points at this move's new files.
    private func isFollowed(_ commit: AlbumMove.Commit) -> Bool {
        let newPaths = commit.newPaths
        return newPaths.allSatisfy { id, path in tracksByID[id].map { $0.path == path } ?? true }
    }

    /// Saves where `move` has got to, before anything acts on it. Throws if it can't be saved.
    private func setCommit(_ commit: AlbumMove.Commit?, of move: AlbumMove) throws {
        guard let index = queuedAlbumMoves.firstIndex(where: { $0.folder == move.folder }) else { return }
        queuedAlbumMoves[index].commit = commit
        guard let url = albumMovesURL else { return }
        try AlbumMoveFiles.save(queuedAlbumMoves, to: url)
    }

    /// Points tracks at new paths, stamping their files (when given) so a rescan takes them as
    /// they are. False if the library couldn't be updated (that's reported).
    private func relink(_ paths: [Int64: String], stamps: [(id: Int64, stamp: FileStamp)]?) -> Bool {
        let saved: Void? = perform("Couldn't point the library at the moved album") { store in
            try store.db.transaction {
                for (id, path) in paths { try store.updatePath(path, bookmark: nil, forTrack: id) }
                if let stamps { try store.setFileStamps(stamps) }
            }
        }
        guard saved != nil else { return false }
        for (id, path) in paths { tracksByID[id]?.path = path }
        notePathsChanged()
        noteTracksChanged()
        return true
    }

    /// A move that failed before the library followed it. If the library folder went away
    /// meanwhile, the album waits for it; otherwise it stays in the download folder, and the error
    /// is shown.
    private func moveFailed(_ move: AlbumMove, root: URL, _ error: Error) async -> MoveOutcome {
        guard await BlockingIO.library.run({ AlbumMoveFiles.isFolder(root) }) else { return .offline }
        report("Couldn't move “\(move.title)” to the library; it stays in the download folder", error)
        return .done
    }
}
