import Foundation

/// The app's own library database.
final class LibraryStore {
    static let schemaVersion = 5

    static var defaultURL: URL {
        supportDirectory.appendingPathComponent("susurrus/Library.sqlite")
    }

    /// ~/Library/Application Support, or `SUSURRUS_SUPPORT_DIR` to try a build against a throwaway
    /// library.
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["SUSURRUS_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static var isUsingSupportOverride: Bool { ProcessInfo.processInfo.environment["SUSURRUS_SUPPORT_DIR"]?.isEmpty == false }

    let url: URL
    let db: Database

    init(url: URL = LibraryStore.defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        db = try Database(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
        try LibraryStore.migrate(db)
    }

    static func migrate(_ db: Database) throws {
        let version = try db.prepare("PRAGMA user_version")
        try version.step()
        let current = version.int(0) ?? 0
        guard current < schemaVersion else { return }

        try db.transaction {
            if current < 1 { try createVersion1(db) }
            if current < 2 { try upgradeToVersion2(db) }
            if current < 3 { try upgradeToVersion3(db) }
            if current < 4 { try upgradeToVersion4(db) }
            if current < 5 { try upgradeToVersion5(db) }
            try db.execute("PRAGMA user_version = \(schemaVersion)")
        }
    }

    private static func createVersion1(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE track (
                id INTEGER PRIMARY KEY,
                source_id INTEGER UNIQUE,
                import_stamp REAL,
                title TEXT NOT NULL DEFAULT '',
                artist TEXT NOT NULL DEFAULT '',
                album TEXT NOT NULL DEFAULT '',
                album_artist TEXT NOT NULL DEFAULT '',
                genre TEXT NOT NULL DEFAULT '',
                composer TEXT NOT NULL DEFAULT '',
                grouping TEXT NOT NULL DEFAULT '',
                comment TEXT NOT NULL DEFAULT '',
                year INTEGER NOT NULL DEFAULT 0,
                track_number INTEGER NOT NULL DEFAULT 0,
                track_count INTEGER NOT NULL DEFAULT 0,
                disc_number INTEGER NOT NULL DEFAULT 0,
                disc_count INTEGER NOT NULL DEFAULT 0,
                duration REAL NOT NULL DEFAULT 0,
                bit_rate INTEGER NOT NULL DEFAULT 0,
                sample_rate INTEGER NOT NULL DEFAULT 0,
                bit_depth INTEGER NOT NULL DEFAULT 0,
                channels INTEGER NOT NULL DEFAULT 0,
                bpm INTEGER NOT NULL DEFAULT 0,
                file_size INTEGER NOT NULL DEFAULT 0,
                compilation INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                rating REAL NOT NULL DEFAULT 0,
                play_count INTEGER NOT NULL DEFAULT 0,
                date_added REAL,      -- Unix time
                last_played REAL,     -- Unix time
                date_modified REAL,   -- Unix time
                date_created REAL,    -- Unix time
                path TEXT NOT NULL,
                bookmark BLOB         -- macOS URL bookmark, used when `path` has moved
            );
            CREATE INDEX track_path ON track (path);

            CREATE TABLE playlist (
                id INTEGER PRIMARY KEY,
                source_id INTEGER UNIQUE,
                parent_id INTEGER REFERENCES playlist (id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                kind INTEGER NOT NULL DEFAULT 0,  -- Playlist.Kind
                position INTEGER NOT NULL DEFAULT 0,
                smart_predicate BLOB,             -- NSKeyedArchiver'd NSPredicate
                predicate_format TEXT
            );

            CREATE TABLE playlist_track (
                playlist_id INTEGER NOT NULL REFERENCES playlist (id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                track_id INTEGER NOT NULL REFERENCES track (id) ON DELETE CASCADE,
                PRIMARY KEY (playlist_id, position)
            );
            CREATE INDEX playlist_track_track ON playlist_track (track_id);
            """)
    }

    /// Version 2: a log of every play (for History), seeded with each track's last play, and the
    /// tag writes still waiting to go into files (so quitting doesn't drop them).
    private static func upgradeToVersion2(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE play_history (
                id INTEGER PRIMARY KEY,
                track_id INTEGER NOT NULL REFERENCES track (id) ON DELETE CASCADE,
                played_at REAL NOT NULL   -- Unix time
            );
            CREATE INDEX play_history_played_at ON play_history (played_at);
            CREATE INDEX play_history_track ON play_history (track_id);
            INSERT INTO play_history (track_id, played_at)
                SELECT id, last_played FROM track WHERE last_played IS NOT NULL ORDER BY last_played;

            CREATE TABLE tag_write_queue (
                path TEXT PRIMARY KEY,
                tag_values TEXT NOT NULL   -- JSON-encoded TagValues
            );
            """)
    }

    /// Version 3: every listen with the time actually spent playing and how it ended (for Stats
    /// and skip counts), and the MusicBrainz artist picked for each library artist name.
    private static func upgradeToVersion3(_ db: Database) throws {
        try db.execute("""
            CREATE TABLE listen (
                id INTEGER PRIMARY KEY,
                track_id INTEGER NOT NULL REFERENCES track (id) ON DELETE CASCADE,
                started_at REAL NOT NULL,  -- Unix time
                seconds REAL NOT NULL,     -- time spent playing (pauses and loading left out)
                position REAL NOT NULL,    -- where in the track it ended, in seconds
                outcome INTEGER NOT NULL   -- ListenOutcome
            );
            CREATE INDEX listen_started_at ON listen (started_at);
            CREATE INDEX listen_track ON listen (track_id);

            CREATE TABLE artist_link (
                name_key TEXT PRIMARY KEY,  -- ArtistIndex.key(for:)
                mbid TEXT NOT NULL
            );
            """)
    }

    /// Version 4: each track's musical key.
    private static func upgradeToVersion4(_ db: Database) throws {
        try db.execute("ALTER TABLE track ADD COLUMN musical_key TEXT NOT NULL DEFAULT ''")
    }

    /// Version 5: each file's modification date as of when its tags were last read, so a rescan can
    /// tell when another app changed it, and the files that couldn't be read, so rescans don't
    /// keep opening them.
    private static func upgradeToVersion5(_ db: Database) throws {
        try db.execute("""
            ALTER TABLE track ADD COLUMN file_mtime REAL;  -- Unix time; NULL until a rescan notes it
            CREATE TABLE unreadable_file (
                path TEXT PRIMARY KEY,
                file_mtime REAL,
                file_size INTEGER NOT NULL
            );
            """)
    }

    func loadTracks() throws -> [Track] {
        try loadTracks(where: nil, [])
    }

    /// The tracks with these IDs (ones no longer in the library are left out).
    func loadTracks(ids: some Collection<Int64>) throws -> [Track] {
        var tracks: [Track] = []
        let ids = Array(ids)
        for start in stride(from: 0, to: ids.count, by: 500) {
            let chunk = ids[start ..< min(start + 500, ids.count)]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            tracks += try loadTracks(where: "id IN (\(placeholders))", chunk.map { $0 as Any? })
        }
        return tracks
    }

    private func loadTracks(where condition: String?, _ values: [Any?]) throws -> [Track] {
        let columns = Track.columns
        let statement = try db.prepare("SELECT id, \(columns.map(\.name).joined(separator: ", ")) FROM track"
            + (condition.map { " WHERE \($0)" } ?? ""))
        try statement.bind(values)
        var tracks: [Track] = []
        while try statement.step() {
            let track = Track(id: statement.int(0)!)
            for (index, column) in columns.enumerated() {
                column.load(statement, Int32(index + 1), track)
            }
            tracks.append(track)
        }
        return tracks
    }

    /// Top-level playlists in sidebar order, with folder contents nested in `children`.
    func loadPlaylists() throws -> [Playlist] {
        let statement = try db.prepare("""
            SELECT id, name, kind, parent_id, position, predicate_format
            FROM playlist ORDER BY position, name
            """)
        var all: [Playlist] = []
        while try statement.step() {
            all.append(Playlist(
                id: statement.int(0)!,
                name: statement.string(1) ?? "",
                kind: Playlist.Kind(rawValue: Int(statement.int(2) ?? 0)) ?? .regular,
                parentID: statement.int(3),
                position: Int(statement.int(4) ?? 0),
                predicateFormat: statement.string(5)
            ))
        }

        let childrenByParent = Dictionary(grouping: all.filter { $0.parentID != nil }, by: { $0.parentID! })
        func attachChildren(_ playlist: Playlist) -> Playlist {
            var playlist = playlist
            if playlist.kind == .folder {
                playlist.children = (childrenByParent[playlist.id] ?? []).map(attachChildren)
            }
            return playlist
        }
        return all.filter { $0.parentID == nil }.map(attachChildren)
    }

    func trackIDs(inPlaylist playlistID: Int64) throws -> [Int64] {
        let statement = try db.prepare("SELECT track_id FROM playlist_track WHERE playlist_id = ? ORDER BY position")
        try statement.bind([playlistID])
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int(0)!) }
        return ids
    }

    func smartPredicateArchive(forPlaylist playlistID: Int64) throws -> Data? {
        let statement = try db.prepare("SELECT smart_predicate FROM playlist WHERE id = ?")
        try statement.bind([playlistID])
        return try statement.step() ? statement.data(0) : nil
    }

    func bookmark(forTrack trackID: Int64) throws -> Data? {
        let statement = try db.prepare("SELECT bookmark FROM track WHERE id = ?")
        try statement.bind([trackID])
        return try statement.step() ? statement.data(0) : nil
    }

    /// After susurrus rewrote a file's tags: its new size, and its modification date forgotten, so
    /// the next rescan takes the file as it is now instead of re-reading tags it wrote itself.
    func noteRewritten(path: String, size: Int64) throws {
        try db.prepare("UPDATE track SET file_size = ?, file_mtime = NULL WHERE path = ?").run([size, path])
    }

    /// Called when a bookmark resolved to a new location, so the next lookup is direct.
    func updatePath(_ path: String, bookmark: Data?, forTrack trackID: Int64) throws {
        let statement = try db.prepare("UPDATE track SET path = ?, bookmark = COALESCE(?, bookmark) WHERE id = ?")
        try statement.run([path, bookmark, trackID])
    }
}

/// One `track` column as loaded into `Track`: the single list that loading, refreshing and
/// copying tracks all go by. Immutable (closures over key paths), so safe to share.
struct LibraryColumn: @unchecked Sendable {
    let name: String
    let load: (Statement, Int32, Track) -> Void
    /// Copies the value from the first track to the second.
    let copy: (Track, Track) -> Void

    private init<Value>(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, Value>, read: @escaping (Statement, Int32) -> Value) {
        self.name = name
        load = { statement, index, track in track[keyPath: keyPath] = read(statement, index) }
        copy = { source, target in target[keyPath: keyPath] = source[keyPath: keyPath] }
    }

    static func text(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, String>) -> LibraryColumn {
        LibraryColumn(name, keyPath) { $0.string($1) ?? "" }
    }

    static func int(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, Int>) -> LibraryColumn {
        LibraryColumn(name, keyPath) { Int($0.int($1) ?? 0) }
    }

    static func int64(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, Int64>) -> LibraryColumn {
        LibraryColumn(name, keyPath) { $0.int($1) ?? 0 }
    }

    static func real(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, Double>) -> LibraryColumn {
        LibraryColumn(name, keyPath) { $0.double($1) ?? 0 }
    }

    static func flag(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, Bool>, default value: Bool = false) -> LibraryColumn {
        LibraryColumn(name, keyPath) { ($0.int($1) ?? (value ? 1 : 0)) != 0 }
    }

    /// Stored as Unix time.
    static func date(_ name: String, _ keyPath: ReferenceWritableKeyPath<Track, Date?>) -> LibraryColumn {
        LibraryColumn(name, keyPath) { $0.double($1).map { Date(timeIntervalSince1970: $0) } }
    }
}

extension Track {
    static let columns: [LibraryColumn] = [
        .text("title", \.title), .text("artist", \.artist), .text("album", \.album), .text("album_artist", \.albumArtist),
        .text("genre", \.genre), .text("composer", \.composer), .text("grouping", \.grouping), .text("comment", \.comment),
        .int("year", \.year), .int("track_number", \.trackNumber), .int("track_count", \.totalNumberOfTracks),
        .int("disc_number", \.discNumber), .int("disc_count", \.totalNumberOfDiscs), .real("duration", \.length),
        .int("bit_rate", \.bitRate), .int("sample_rate", \.sampleRate), .int("bit_depth", \.bitDepth),
        .int("channels", \.channels), .int("bpm", \.bpm), .text("musical_key", \.musicalKey), .int64("file_size", \.fileSize),
        .flag("compilation", \.compilation), .flag("enabled", \.enabled, default: true), .real("rating", \.rating),
        .int("play_count", \.playCount), .date("date_added", \.dateAdded), .date("last_played", \.lastPlayed),
        .date("date_modified", \.dateModified), .date("date_created", \.dateCreated), .text("path", \.path),
    ]
}
