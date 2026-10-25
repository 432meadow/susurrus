import Foundation

/// Tag fields the Get Info editor can change. nil means "leave as is".
struct TrackEdit: Hashable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var composer: String?
    var grouping: String?
    var comment: String?
    var year: Int?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var discCount: Int?
    var bpm: Int?
    var musicalKey: String?
    var compilation: Bool?
    var rating: Double?

    var isEmpty: Bool { self == TrackEdit() }

    /// Whether the edit can change which artists the library has (or their album counts).
    var changesArtists: Bool { artist != nil || albumArtist != nil || album != nil }

    /// Each field's column, its property here and on `Track`: the one list the rest goes by.
    /// Immutable (closures over key paths), so safe to share.
    private struct Field: @unchecked Sendable {
        let column: String
        let value: (TrackEdit) -> Any?
        /// Sets the field in the edit to the track's current value.
        let takeCurrent: (Track, inout TrackEdit) -> Void
        /// Sets the track's value to the edit's, if the edit has one.
        let apply: (TrackEdit, Track) -> Void

        init<Value>(_ column: String, _ edit: WritableKeyPath<TrackEdit, Value?>, _ track: ReferenceWritableKeyPath<Track, Value>) {
            self.column = column
            value = { $0[keyPath: edit].map { $0 as Any } }
            takeCurrent = { source, result in result[keyPath: edit] = source[keyPath: track] }
            apply = { changes, target in
                if let new = changes[keyPath: edit] { target[keyPath: track] = new }
            }
        }
    }

    private static let fields: [Field] = [
        Field("title", \.title, \.title), Field("artist", \.artist, \.artist), Field("album", \.album, \.album),
        Field("album_artist", \.albumArtist, \.albumArtist), Field("genre", \.genre, \.genre),
        Field("composer", \.composer, \.composer), Field("grouping", \.grouping, \.grouping),
        Field("comment", \.comment, \.comment), Field("year", \.year, \.year),
        Field("track_number", \.trackNumber, \.trackNumber), Field("track_count", \.trackCount, \.totalNumberOfTracks),
        Field("disc_number", \.discNumber, \.discNumber), Field("disc_count", \.discCount, \.totalNumberOfDiscs),
        Field("bpm", \.bpm, \.bpm), Field("musical_key", \.musicalKey, \.musicalKey),
        Field("compilation", \.compilation, \.compilation), Field("rating", \.rating, \.rating),
    ]

    /// (column, value) pairs for the fields that are set.
    fileprivate var assignments: [(String, Any)] {
        Self.fields.compactMap { field in field.value(self).map { (field.column, $0) } }
    }

    /// The track's current values for the fields this edit sets (what undoing it puts back).
    func currentValues(in track: Track) -> TrackEdit {
        var old = TrackEdit()
        for field in Self.fields where field.value(self) != nil { field.takeCurrent(track, &old) }
        return old
    }

    /// Applies the set fields to an in-memory track so the UI updates without a reload.
    func apply(to track: Track) {
        for field in Self.fields { field.apply(self, track) }
        track.tagsDidChange()
    }
}

extension LibraryStore {
    // MARK: Tracks

    func recordPlay(trackID: Int64, at date: Date) throws {
        try db.transaction {
            try db.prepare("UPDATE track SET play_count = play_count + 1, last_played = ? WHERE id = ?")
                .run([date.timeIntervalSince1970, trackID])
            try db.prepare("INSERT INTO play_history (track_id, played_at) VALUES (?, ?)")
                .run([trackID, date.timeIntervalSince1970])
        }
    }

    func update(_ edit: TrackEdit, forTracks ids: [Int64]) throws {
        let assignments = edit.assignments
        guard !assignments.isEmpty, !ids.isEmpty else { return }
        let sql = "UPDATE track SET \(assignments.map { "\($0.0) = ?" }.joined(separator: ", ")), date_modified = ? WHERE id = ?"
        let statement = try db.prepare(sql)
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for id in ids {
                try statement.run(assignments.map(\.1) + [now, id])
            }
        }
    }

    // MARK: Playlists

    private func nextPosition(under parentID: Int64?) throws -> Int {
        let statement = try db.prepare("SELECT COALESCE(MAX(position) + 1, 0) FROM playlist WHERE parent_id IS ?")
        try statement.bind([parentID])
        try statement.step()
        return Int(statement.int(0) ?? 0)
    }

    @discardableResult
    func createPlaylist(named name: String, kind: Playlist.Kind = .regular, parentID: Int64? = nil,
                        trackIDs: [Int64] = [], smartPredicate: Data? = nil, predicateFormat: String? = nil) throws -> Int64 {
        var id: Int64 = 0
        try db.transaction {
            let insert = try db.prepare("""
                INSERT INTO playlist (name, kind, parent_id, position, smart_predicate, predicate_format)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            try insert.run([name, kind.rawValue, parentID, try nextPosition(under: parentID), smartPredicate, predicateFormat])
            id = db.lastInsertID
            try insertEntries(trackIDs, into: id, startingAt: 0)
        }
        return id
    }

    func renamePlaylist(_ id: Int64, to name: String) throws {
        try db.prepare("UPDATE playlist SET name = ? WHERE id = ?").run([name, id])
    }

    /// Deletes a playlist; for folders, everything inside goes too (ON DELETE CASCADE).
    func deletePlaylist(_ id: Int64) throws {
        try db.prepare("DELETE FROM playlist WHERE id = ?").run([id])
    }

    func setSmartPredicate(_ archive: Data, format: String, forPlaylist id: Int64) throws {
        try db.prepare("UPDATE playlist SET smart_predicate = ?, predicate_format = ? WHERE id = ?").run([archive, format, id])
    }

    /// Moves a playlist into `parentID` (nil = top level) at `position`, shifting its new siblings.
    func movePlaylist(_ id: Int64, toParent parentID: Int64?, position: Int) throws {
        try db.transaction {
            var siblings: [Int64] = []
            let select = try db.prepare("SELECT id FROM playlist WHERE parent_id IS ? AND id != ? ORDER BY position, name")
            try select.bind([parentID, id])
            while try select.step() { siblings.append(select.int(0)!) }
            siblings.insert(id, at: max(0, min(position, siblings.count)))
            let update = try db.prepare("UPDATE playlist SET parent_id = ?, position = ? WHERE id = ?")
            for (index, sibling) in siblings.enumerated() {
                try update.run([sibling == id ? parentID : parentIDOf(sibling), index, sibling])
            }
        }
    }

    private func parentIDOf(_ id: Int64) throws -> Int64? {
        let statement = try db.prepare("SELECT parent_id FROM playlist WHERE id = ?")
        try statement.bind([id])
        return try statement.step() ? statement.int(0) : nil
    }

    func appendTracks(_ trackIDs: [Int64], toPlaylist id: Int64) throws {
        try db.transaction {
            // Positions can have gaps (removed tracks take their entries with them), so not COUNT(*).
            let next = try db.prepare("SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_track WHERE playlist_id = ?")
            try next.bind([id])
            try next.step()
            try insertEntries(trackIDs, into: id, startingAt: Int(next.int(0) ?? 0))
        }
    }

    /// Removes the entries at `positions` (indexes into the playlist's order).
    func removeEntries(at positions: IndexSet, fromPlaylist id: Int64) throws {
        var entries = try trackIDs(inPlaylist: id)
        entries.remove(atOffsets: positions)
        try replaceEntries(of: id, with: entries)
    }

    func moveEntries(at positions: IndexSet, to destination: Int, inPlaylist id: Int64) throws {
        var entries = try trackIDs(inPlaylist: id)
        entries.move(fromOffsets: positions, toOffset: destination)
        try replaceEntries(of: id, with: entries)
    }

    func replaceEntries(of playlistID: Int64, with trackIDs: [Int64]) throws {
        try db.transaction {
            try db.prepare("DELETE FROM playlist_track WHERE playlist_id = ?").run([playlistID])
            try insertEntries(trackIDs, into: playlistID, startingAt: 0)
        }
    }

    private func insertEntries(_ trackIDs: [Int64], into playlistID: Int64, startingAt start: Int) throws {
        let insert = try db.prepare("INSERT INTO playlist_track (playlist_id, position, track_id) VALUES (?, ?, ?)")
        for (offset, trackID) in trackIDs.enumerated() {
            try insert.run([playlistID, start + offset, trackID])
        }
    }
}

extension LibraryStore {
    // MARK: Adding files

    /// Every path already in the library.
    func allPaths() throws -> Set<String> {
        let statement = try db.prepare("SELECT path FROM track")
        var paths = Set<String>()
        while try statement.step() { if let path = statement.string(0) { paths.insert(path) } }
        return paths
    }
}
