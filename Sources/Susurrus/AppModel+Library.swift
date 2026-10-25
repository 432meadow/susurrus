import AppKit

/// Library housekeeping: Go to Current Track, missing files, removing tracks, history, and
/// tag writes saved from the last session.
extension AppModel {
    // MARK: Go to Current Track

    /// Selects the playing track in the list and scrolls to it, switching to All Tracks (and
    /// clearing the search) when the current list doesn't show it.
    func goToCurrentTrack() {
        guard let track = player.currentTrack, tracksByID[track.id] != nil else { return }
        reveal(track)
    }

    /// Selects a track in the list and scrolls to it, switching to All Tracks (and clearing the
    /// search) when the current list doesn't show it.
    func reveal(_ track: Track) {
        let showsTrackList = selection != nil && selection != .albums && selection?.isCustomView != true
        if !showsTrackList || !visibleTracks.contains(where: { $0.id == track.id }) {
            if !searchText.isEmpty { searchText = "" }
            if selection == .browser {
                browse(genre: nil)
            } else if selection != .allTracks {
                selection = .allTracks
            }
        }
        selectedTrackIDs = [track.id]
        requestReveal(of: track.id)
    }

    // MARK: Missing files

    /// Checks every track's file in the background, or only the tracks on `volume` when one
    /// was just mounted or unmounted. Each folder is listed once rather than every file asked
    /// for, which matters over a slow network share. Files that moved but can still be found
    /// through their bookmark get their path updated.
    func checkForMissingFiles(onVolume volume: URL? = nil) {
        guard store != nil, !tracks.isEmpty else { return }
        guard missingFilesCheck == nil else {
            needsMissingFilesCheck = true  // something changed meanwhile: look again once this is done
            return
        }
        let prefix = volume.map { $0.standardizedFileURL.path + "/" }
        let paths = tracks.lazy.filter { prefix == nil || $0.path.hasPrefix(prefix!) }.map { (id: $0.id, path: $0.path) }
        guard !paths.isEmpty else { return }
        let checked = Array(paths)
        let locate = player.locate
        isCheckingForMissingFiles = true
        missingFilesCheck = Task { [weak self] in
            let found = await BlockingIO.library.run {
                var statuses = MissingFiles.check(checked)
                for (id, path) in checked where statuses[id] == .missing {
                    if locate(TrackRef(id: id, path: path)) != nil { statuses[id] = nil }
                }
                return statuses
            }
            guard let self else { return }
            self.missingFilesCheck = nil
            self.isCheckingForMissingFiles = false
            var statuses = prefix == nil ? [:] : self.unavailableTracks
            for (id, _) in checked { statuses[id] = found[id] }
            self.setUnavailable(statuses)
            if self.needsMissingFilesCheck {
                self.needsMissingFilesCheck = false
                self.checkForMissingFiles()
            }
        }
    }

    /// Stops the check for missing files.
    func stopCheckingForMissingFiles() {
        missingFilesCheck?.cancel()
        missingFilesCheck = nil
        isCheckingForMissingFiles = false
        needsMissingFilesCheck = false
    }

    /// Playback couldn't open the file: show the track as missing (or offline) straight away.
    /// The check runs off the main thread, since the file is likely on a share that's struggling.
    func noteUnplayable(_ track: Track) {
        let (id, path) = (track.id, track.path)
        Task { [weak self] in
            let status = await BlockingIO.library.run { MissingFiles.check([(id, path)])[id] ?? .missing }
            guard let self else { return }
            var statuses = self.unavailableTracks
            statuses[id] = status
            self.setUnavailable(statuses)
        }
    }

    /// Asks where a missing file went. Other missing files from the same folder are looked for
    /// in the chosen file's folder too, since they usually moved together.
    func locate(_ track: Track) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Locate"
        panel.message = "Where is “\(track.displayTitle)”? It was at \(track.path)"
        let oldFolder = (track.path as NSString).deletingLastPathComponent
        panel.directoryURL = URL(fileURLWithPath: oldFolder, isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.relink(track, to: url, lookingFor: oldFolder) }
        }
    }

    private func relink(_ track: Track, to url: URL, lookingFor oldFolder: String) {
        let neighbours = tracks
            .filter { $0.id != track.id && unavailableTracks[$0.id] != nil && ($0.path as NSString).deletingLastPathComponent == oldFolder }
            .map { (id: $0.id, name: $0.fileName) }
        let newFolder = url.deletingLastPathComponent()
        let trackID = track.id
        Task { [weak self] in
            // Bookmarks and file checks touch the (possibly slow) volume, so not on the main thread.
            let found = await BlockingIO.library.run { () -> [(id: Int64, path: String, bookmark: Data?)] in
                var found = [(id: trackID, path: url.path, bookmark: try? url.bookmarkData())]
                for neighbour in neighbours {
                    let candidate = newFolder.appendingPathComponent(neighbour.name)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        found.append((neighbour.id, candidate.path, try? candidate.bookmarkData()))
                    }
                }
                return found
            }
            guard let self else { return }
            let saved: Void? = self.perform("Couldn't relink the file") { store in
                try store.db.transaction {
                    for file in found { try store.updatePath(file.path, bookmark: file.bookmark, forTrack: file.id) }
                }
            }
            guard saved != nil else { return }
            for file in found { self.tracksByID[file.id]?.path = file.path }
            self.notePathsChanged()
            self.markAvailable(found.map(\.id))
        }
    }

    // MARK: Removing tracks

    /// Asks for confirmation (the alert calls `removeFromLibrary`).
    func confirmRemoveFromLibrary(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        pendingRemoval = tracks
    }

    /// Removes tracks from the library database. The files stay where they are.
    func removeFromLibrary(_ removed: [Track]) {
        let ids = Set(removed.map(\.id))
        guard !ids.isEmpty, perform("Couldn't remove tracks", { try $0.deleteTracks(Array(ids)) }) != nil else { return }
        forgetTracks(ids)
    }

    /// Every track whose file is missing (its volume is there, the file isn't).
    var missingTracks: [Track] {
        tracks.filter { unavailableTracks[$0.id] == .missing }
    }

    // MARK: History

    func clearHistory() {
        let cleared: Void? = perform("Couldn't clear the history") { store in
            try store.db.transaction {
                try store.clearHistory()
                try store.clearListens()
            }
        }
        guard cleared != nil else { return }
        for track in tracks where track.skipCount > 0 { track.skipCount = 0 }
        statsRevision += 1
        noteTracksChanged()
        if selection == .history { loadSelection() }
    }

    // MARK: Saved tag writes

    /// Picks up tag writes that were still queued when susurrus quit.
    func restorePendingTagWrites() {
        guard let store, let pending = try? store.pendingTagWrites(), !pending.isEmpty else { return }
        guard writesTagsToFiles else {
            try? store.clearPendingTagWrites()
            return
        }
        tagWriter.resume(pending)
    }
}
