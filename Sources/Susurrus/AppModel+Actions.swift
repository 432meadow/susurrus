import AppKit

/// Editing actions: ratings, tags, play counts, playlists, queue, and saved playback state.
extension AppModel {
    // MARK: Plays, ratings and tags

    func recordPlay(_ track: Track) {
        let now = Date()
        guard performQuietly("Couldn't record a play", { try $0.recordPlay(trackID: track.id, at: now) }) != nil else { return }
        track.playCount += 1
        track.lastPlayed = now
        noteTracksChanged()
        if selection == .history || selection == .recentlyPlayed { loadSelection() }
    }

    func recordListen(_ listen: ListenRecord, of track: Track) {
        guard performQuietly("Couldn't record a listen", { try $0.recordListen(listen) }) != nil else { return }
        statsRevision += 1
        if listen.outcome == .skipped {
            track.skipCount += 1
            noteTracksChanged()
        }
    }

    func setRating(_ rating: Double, for tracks: [Track]) {
        update(TrackEdit(rating: rating.clamped(to: 0...5)), for: tracks, actionName: "Rating")
    }

    /// Saves tag edits to the library database and, with "Write tags to files" on, queues them
    /// to be written into the audio files.
    func update(_ edit: TrackEdit, for tracks: [Track], actionName: String = "Edit Info") {
        apply([(edit, tracks)], actionName: actionName)
    }

    /// Saves each edit for its tracks and registers an undo that puts back the values they
    /// replaced (undoing goes through here too, so it registers the redo).
    func apply(_ changes: [(edit: TrackEdit, tracks: [Track])], actionName: String, registersUndo: Bool = true) {
        let changes = changes.filter { !$0.edit.isEmpty && !$0.tracks.isEmpty }
        guard !changes.isEmpty else { return }
        var previous: [TrackEdit: [Track]] = [:]
        for change in changes {
            for track in change.tracks {
                previous[change.edit.currentValues(in: track), default: []].append(track)
            }
        }
        guard save(changes), registersUndo else { return }
        let inverse = previous.map { (edit: $0.key, tracks: $0.value) }
        registerUndo(actionName) { $0.apply(inverse, actionName: actionName) }
    }

    /// Registers `action` as the undo of what was just done, under `name` ("Undo Rating").
    func registerUndo(_ name: String, _ action: @escaping (AppModel) -> Void) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { action(model) }
        }
        undoManager.setActionName(name)
    }

    /// Saves edits all or nothing, then shows them and, with "Write tags to files" on, queues them
    /// for the files. Returns whether they were saved.
    @discardableResult
    private func save(_ changes: [(edit: TrackEdit, tracks: [Track])]) -> Bool {
        guard !changes.isEmpty else { return true }
        let saved: Void? = perform("Couldn't save changes") { store in
            try store.db.transaction {
                for change in changes { try store.update(change.edit, forTracks: change.tracks.map(\.id)) }
            }
        }
        guard saved != nil else { return false }
        for change in changes {
            for track in change.tracks { change.edit.apply(to: track) }
            guard writesTagsToFiles else { continue }
            for track in change.tracks {
                var values = TagValues(edit: change.edit, track: track)
                // MP4 has no standard key item; don't rewrite a file over the share for nothing.
                if Self.mp4Extensions.contains((track.path as NSString).pathExtension.lowercased()) { values.key = nil }
                tagWriter.enqueue(values, path: track.path)
            }
        }
        noteTracksChanged()
        if changes.contains(where: { $0.edit.changesArtists }) { artistIndex = nil }
        // Sorting, search matches and album grouping may all depend on what changed.
        refreshVisible()
        return true
    }

    // MARK: BPM detection

    /// Detects the tempo of the tracks that have no BPM yet, or of all of them when every one
    /// already has one (so the same command re-detects a selection).
    func detectBPM(for tracks: [Track]) {
        let missing = tracks.filter { $0.bpm == 0 }
        bpmAnalyzer.enqueue((missing.isEmpty ? tracks : missing).map { ($0.id, $0.path) })
    }

    /// Saves the BPM and key a deck found for a track that had neither, like detected ones.
    func fillIn(_ track: Track, from analysis: TrackAnalysis) {
        guard tracksByID[track.id] === track else { return }
        var edit = TrackEdit()
        if track.bpm == 0, let bpm = analysis.grid?.bpm { edit.bpm = Int(bpm.rounded()) }
        if track.musicalKey.isEmpty, let key = analysis.key { edit.musicalKey = key.name }
        guard !edit.isEmpty else { return }
        save([(edit, [track])])
    }

    private static let mp4Extensions: Set<String> = ["m4a", "m4b", "mp4", "aac", "alac"]

    /// Detects the key of the tracks that have none yet, or of all of them when every one already
    /// has one (so the same command re-detects a selection).
    func detectKey(for tracks: [Track]) {
        let missing = tracks.filter { $0.musicalKey.isEmpty }
        keyAnalyzer.enqueue((missing.isEmpty ? tracks : missing).map { ($0.id, $0.path) })
    }

    /// Saves a batch of detected keys like Get Info edits (so they're written into the files
    /// too when that's on), refreshing the list once per batch.
    func saveDetectedKeys(_ results: [(Int64, MusicalKey)]) {
        save(results.compactMap { id, key in
            guard let track = tracksByID[id], track.musicalKey != key.name else { return nil }
            return (TrackEdit(musicalKey: key.name), [track])
        })
    }

    /// Saves a batch of detected tempos like Get Info edits (so they're written into the files
    /// too when that's on), refreshing the list once per batch.
    func saveDetectedBPMs(_ results: [(Int64, Int)]) {
        save(results.compactMap { id, bpm in
            guard let track = tracksByID[id], track.bpm != bpm else { return nil }
            return (TrackEdit(bpm: bpm), [track])
        })
    }

    /// Keeps the library's file size in step after a tag write.
    func noteFileRewritten(path: String, size: Int64) {
        performQuietly("Couldn't note a rewritten file") { try $0.noteRewritten(path: path, size: size) }
        track(atPath: path)?.fileSize = size
    }

    // MARK: Queue

    func playNext(_ tracks: [Track]) { player.playNext(tracks) }
    func addToQueue(_ tracks: [Track]) { player.addToQueue(tracks) }

    // MARK: Playlists

    @discardableResult
    func createPlaylist(named name: String = "Untitled Playlist", with tracks: [Track] = [], in folderID: Int64? = nil) -> Int64? {
        guard let id = perform("Couldn't create the playlist", {
            try $0.createPlaylist(named: name, parentID: folderID, trackIDs: tracks.map(\.id))
        }) else { return nil }
        reloadPlaylists()
        selection = .playlist(id)
        registerUndo("New Playlist") { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: "New Playlist") }
        return id
    }

    @discardableResult
    func createFolder(named name: String = "Untitled Folder", in folderID: Int64? = nil) -> Int64? {
        guard let id = perform("Couldn't create the folder", {
            try $0.createPlaylist(named: name, kind: .folder, parentID: folderID)
        }) else { return nil }
        reloadPlaylists()
        registerUndo("New Folder") { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: "New Folder") }
        return id
    }

    /// New Playlist (⌘N) and the sidebar's +: an empty playlist with its name ready to type.
    func newPlaylist(with tracks: [Track] = [], in folderID: Int64? = nil) {
        renamingPlaylistID = createPlaylist(with: tracks, in: folderID)
    }

    /// New Playlist Folder: an empty folder with its name ready to type.
    func newFolder(in folderID: Int64? = nil) {
        renamingPlaylistID = createFolder(in: folderID)
    }

    @discardableResult
    func createSmartPlaylist(named name: String, predicate: NSPredicate, in folderID: Int64? = nil) -> Int64? {
        let archive: Data
        do {
            archive = try SmartPredicate.archive(predicate)
        } catch {
            report("Couldn't save the smart playlist", error)
            return nil
        }
        guard let id = perform("Couldn't create the smart playlist", {
            try $0.createPlaylist(named: name, kind: .smart, parentID: folderID, smartPredicate: archive,
                                  predicateFormat: predicate.predicateFormat)
        }) else { return nil }
        reloadPlaylists()
        selection = .playlist(id)
        registerUndo("New Smart Playlist") { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: "New Smart Playlist") }
        return id
    }

    func updateSmartPlaylist(_ id: Int64, name: String, predicate: NSPredicate) {
        let archive: Data
        do {
            archive = try SmartPredicate.archive(predicate)
        } catch {
            report("Couldn't save the smart playlist", error)
            return
        }
        let oldName = playlistsByID[id]?.name
        let oldPredicate = smartPredicate(forPlaylist: id)
        let saved: Void? = perform("Couldn't save the smart playlist") { store in
            try store.db.transaction {
                try store.renamePlaylist(id, to: name)
                try store.setSmartPredicate(archive, format: predicate.predicateFormat, forPlaylist: id)
            }
        }
        guard saved != nil else { return }
        reloadPlaylists()
        if selection == .playlist(id) { loadSelection() }
        if let oldName, let oldPredicate {
            registerUndo("Edit Smart Playlist") { $0.updateSmartPlaylist($0.resolvedPlaylistID(id), name: oldName, predicate: oldPredicate) }
        }
    }

    func smartPredicate(forPlaylist id: Int64) -> NSPredicate? {
        guard let data = performQuietly("Couldn't read a smart playlist", { try $0.smartPredicateArchive(forPlaylist: id) }) ?? nil
        else { return nil }
        return try? SmartPredicate.unarchive(data)
    }

    func renamePlaylist(_ id: Int64, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let oldName = playlistsByID[id]?.name, oldName != name,
              perform("Couldn't rename the playlist", { try $0.renamePlaylist(id, to: name) }) != nil else { return }
        reloadPlaylists()
        registerUndo("Rename Playlist") { $0.renamePlaylist($0.resolvedPlaylistID(id), to: oldName) }
    }

    /// Deletes a playlist (a folder with everything in it). Undo puts it back, contents and all.
    func deletePlaylist(_ id: Int64, actionName: String = "Delete Playlist") {
        guard let snapshot = snapshot(ofPlaylist: id),
              perform("Couldn't delete the playlist", { try $0.deletePlaylist(id) }) != nil else { return }
        reloadPlaylists()
        if case .playlist(let selected) = selection, playlistsByID[selected] == nil {
            selection = .allTracks
        }
        registerUndo(actionName) { $0.restore(snapshot, actionName: actionName) }
    }

    func movePlaylist(_ id: Int64, toFolder folderID: Int64?, position: Int) {
        guard id != folderID, let playlist = playlistsByID[id] else { return }
        // Don't allow moving a folder into its own descendant.
        if let folderID, isDescendant(folderID, of: id) { return }
        let oldParent = playlist.parentID
        let oldIndex = siblingIndex(of: playlist)
        guard perform("Couldn't move the playlist", { try $0.movePlaylist(id, toParent: folderID, position: position) }) != nil else { return }
        reloadPlaylists()
        registerUndo("Move Playlist") { model in
            model.movePlaylist(model.resolvedPlaylistID(id), toFolder: oldParent.map(model.resolvedPlaylistID), position: oldIndex)
        }
    }

    // MARK: Undoing playlist deletion

    /// Everything needed to recreate a deleted playlist.
    struct PlaylistSnapshot {
        let id: Int64
        let name: String
        let kind: Playlist.Kind
        let parentID: Int64?
        let index: Int
        let smartPredicate: Data?
        let predicateFormat: String?
        let entries: [Int64]
        let children: [PlaylistSnapshot]
    }

    func resolvedPlaylistID(_ id: Int64) -> Int64 {
        var id = id
        while let newer = playlistIDRemap[id] { id = newer }
        return id
    }

    private func siblingIndex(of playlist: Playlist) -> Int {
        let siblings = playlist.parentID.flatMap { playlistsByID[$0]?.children } ?? playlists
        return siblings.firstIndex { $0.id == playlist.id } ?? 0
    }

    private func snapshot(ofPlaylist id: Int64) -> PlaylistSnapshot? {
        guard let store, let playlist = playlistsByID[id] else { return nil }
        do {
            return PlaylistSnapshot(
                id: id, name: playlist.name, kind: playlist.kind, parentID: playlist.parentID,
                index: siblingIndex(of: playlist),
                smartPredicate: playlist.kind == .smart ? try store.smartPredicateArchive(forPlaylist: id) : nil,
                predicateFormat: playlist.predicateFormat,
                entries: playlist.kind == .regular ? try store.trackIDs(inPlaylist: id) : [],
                children: (playlist.children ?? []).compactMap { snapshot(ofPlaylist: $0.id) }
            )
        } catch {
            report("Couldn't read the playlist", error)
            return nil
        }
    }

    private func restore(_ snapshot: PlaylistSnapshot, actionName: String) {
        guard let id = insert(snapshot, parentID: snapshot.parentID.map(resolvedPlaylistID)) else {
            notify("Couldn't put “\(snapshot.name)” back", kind: .error)
            return
        }
        reloadPlaylists()
        registerUndo(actionName) { $0.deletePlaylist($0.resolvedPlaylistID(id), actionName: actionName) }
    }

    private func insert(_ snapshot: PlaylistSnapshot, parentID: Int64?) -> Int64? {
        guard let store else { return nil }
        // Tracks removed from the library since can't come back into the playlist.
        let entries = snapshot.entries.filter { tracksByID[$0] != nil }
        func create(under parent: Int64?) -> Int64? {
            try? store.createPlaylist(named: snapshot.name, kind: snapshot.kind, parentID: parent, trackIDs: entries,
                                      smartPredicate: snapshot.smartPredicate, predicateFormat: snapshot.predicateFormat)
        }
        // If its folder is gone too, it comes back at the top level.
        var parent = parentID
        guard let id = create(under: parent) ?? { parent = nil; return create(under: nil) }() else { return nil }
        performQuietly("Couldn't put a playlist back in place") { try $0.movePlaylist(id, toParent: parent, position: snapshot.index) }
        playlistIDRemap[snapshot.id] = id
        for child in snapshot.children {
            _ = insert(child, parentID: id)
        }
        return id
    }

    private func isDescendant(_ candidate: Int64, of ancestor: Int64) -> Bool {
        var current = playlistsByID[candidate]?.parentID
        while let id = current {
            if id == ancestor { return true }
            current = playlistsByID[id]?.parentID
        }
        return false
    }

    /// Regular playlists that tracks can be added to, with their folder path for menus.
    var editablePlaylists: [(playlist: Playlist, path: String)] {
        var result: [(Playlist, String)] = []
        func walk(_ items: [Playlist], prefix: String) {
            for item in items {
                switch item.kind {
                case .regular: result.append((item, prefix + item.name))
                case .folder: walk(item.children ?? [], prefix: prefix + item.name + " ▸ ")
                case .smart: break
                }
            }
        }
        walk(playlists, prefix: "")
        return result
    }

    func add(_ tracks: [Track], toPlaylist id: Int64) {
        guard !tracks.isEmpty, playlistsByID[id]?.kind == .regular,
              let entries = perform("Couldn't change the playlist", { try $0.trackIDs(inPlaylist: id) }) else { return }
        setEntries(entries + tracks.map(\.id), ofPlaylist: id, actionName: "Add to Playlist")
    }

    /// Replaces a playlist's contents; undo puts the old order back.
    func setEntries(_ ids: [Int64], ofPlaylist id: Int64, actionName: String) {
        guard let old = perform("Couldn't change the playlist", { try $0.trackIDs(inPlaylist: id) }) else { return }
        let ids = ids.filter { tracksByID[$0] != nil }
        guard ids != old, perform("Couldn't change the playlist", { try $0.replaceEntries(of: id, with: ids) }) != nil else { return }
        if selection == .playlist(id) { loadSelection() }
        registerUndo(actionName) { $0.setEntries(old, ofPlaylist: $0.resolvedPlaylistID(id), actionName: actionName) }
    }

    /// The playlist shown in the main list, if it's one whose contents can be edited.
    var editablePlaylistID: Int64? {
        guard case .playlist(let id) = selection, playlistsByID[id]?.kind == .regular else { return nil }
        return id
    }

    /// Removes every entry of `tracks` from the playlist being shown.
    func removeFromCurrentPlaylist(_ tracks: [Track]) {
        guard let id = editablePlaylistID,
              let entries = perform("Couldn't change the playlist", { try $0.trackIDs(inPlaylist: id) }) else { return }
        let ids = Set(tracks.map(\.id))
        selectedTrackIDs.subtract(ids)
        setEntries(entries.filter { !ids.contains($0) }, ofPlaylist: id, actionName: "Remove from Playlist")
    }

    /// Reorders the playlist being shown. Only meaningful in playlist order (no column sort or search).
    func moveInCurrentPlaylist(_ tracks: [Track], toPosition destination: Int) {
        guard let id = editablePlaylistID, sortOrder.isEmpty, searchText.isEmpty,
              let entries = perform("Couldn't change the playlist", { try $0.trackIDs(inPlaylist: id) }) else { return }
        let ids = Set(tracks.map(\.id))
        var moved = entries
        moved.move(fromOffsets: IndexSet(entries.indices.filter { ids.contains(entries[$0]) }), toOffset: destination)
        setEntries(moved, ofPlaylist: id, actionName: "Reorder Playlist")
    }

    // MARK: Saved playback state

    private static var playbackStateURL: URL {
        LibraryStore.defaultURL.deletingLastPathComponent().appendingPathComponent("PlaybackState.json")
    }

    func savePlaybackState() {
        guard let state = player.savedState, let data = try? JSONEncoder().encode(state) else {
            try? FileManager.default.removeItem(at: Self.playbackStateURL)
            return
        }
        do {
            try data.write(to: Self.playbackStateURL, options: .atomic)
        } catch {
            EventLog.shared.log("Couldn't save the queue: \(error.localizedDescription)")
        }
    }

    /// Puts back the queue and position from last time, paused. Tracks removed from the library
    /// since are left out; the entry that was playing is found by its place in the queue, since
    /// the same track can be queued more than once.
    func restorePlaybackState() {
        guard let data = try? Data(contentsOf: Self.playbackStateURL),
              let state = try? JSONDecoder().decode(Player.SavedState.self, from: data),
              state.trackIDs.indices.contains(state.index), tracksByID[state.trackIDs[state.index]] != nil else { return }
        let queue = state.trackIDs.compactMap { tracksByID[$0] }
        let index = state.trackIDs[..<state.index].filter { tracksByID[$0] != nil }.count
        player.restore(queue, index: index, position: state.position)
    }
}
