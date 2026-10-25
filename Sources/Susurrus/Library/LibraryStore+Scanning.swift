import Foundation

/// A file's modification date (Unix time) and size, to tell whether it changed since it was read.
struct FileStamp: Equatable, Sendable {
    var modified: Double?
    var size: Int64

    init(modified: Date?, size: Int64) {
        self.modified = modified?.timeIntervalSince1970
        self.size = size
    }

    init(modified: Double?, size: Int64) {
        self.modified = modified
        self.size = size
    }
}

extension ScannedTrack {
    /// The file's stamp as it was when its tags were read.
    var stamp: FileStamp { FileStamp(modified: dateModified, size: fileSize) }

    /// Tag columns with this file's values, and whether the file really has each one: a tag that's
    /// empty or zero, or guessed from the file's name and folders, doesn't count.
    fileprivate var tags: [(column: String, value: Any, isSet: Bool)] {
        func text(_ column: String, _ value: String, guessedAs field: InferredFields = []) -> (String, Any, Bool) {
            (column, value, !value.isEmpty && (field.isEmpty || !inferred.contains(field)))
        }
        func number(_ column: String, _ value: Int) -> (String, Any, Bool) { (column, value, value != 0) }
        return [
            text("title", title, guessedAs: .title), text("artist", artist, guessedAs: .artist),
            text("album", album, guessedAs: .album), text("album_artist", albumArtist), text("genre", genre),
            text("composer", composer), text("comment", comment), number("year", year),
            number("track_number", trackNumber), number("track_count", trackCount), number("disc_number", discNumber),
            number("disc_count", discCount), number("bpm", bpm), text("musical_key", musicalKey),
            ("compilation", compilation, compilation),
        ]
    }

    /// Columns that describe the file itself, always taken as read.
    fileprivate var properties: [(column: String, value: Any?)] {
        let modified = dateModified?.timeIntervalSince1970
        return [
            ("duration", duration), ("bit_rate", bitRate), ("sample_rate", sampleRate), ("channels", channels),
            ("file_size", fileSize), ("date_modified", modified), ("file_mtime", modified),
        ]
    }
}

extension LibraryStore {
    // MARK: Adding files

    /// Inserts scanned files; paths already in the library are skipped. Returns the new tracks' IDs.
    @discardableResult
    func insert(_ scanned: [ScannedTrack], addedAt date: Date = Date()) throws -> [Int64] {
        var ids: [Int64] = []
        try db.transaction {
            let exists = try db.prepare("SELECT 1 FROM track WHERE path = ?")
            var insert: Statement?
            for track in scanned {
                try exists.bind([track.path])
                if try exists.step() { continue }
                let columns = track.tags.map { ($0.column, $0.value as Any?) } + track.properties + [
                    ("path", track.path), ("bookmark", track.bookmark), ("date_added", date.timeIntervalSince1970),
                    ("date_created", track.dateCreated?.timeIntervalSince1970),
                ]
                if insert == nil {
                    let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
                    insert = try db.prepare("INSERT INTO track (\(columns.map(\.0).joined(separator: ", "))) VALUES (\(placeholders))")
                }
                try insert?.run(columns.map(\.1))
                ids.append(db.lastInsertID)
            }
        }
        return ids
    }

    // MARK: Rescanning

    /// Every library file's track ID and its stamp as of when its tags were last read (no date:
    /// not noted yet).
    func fileStamps() throws -> [String: (id: Int64, stamp: FileStamp)] {
        let statement = try db.prepare("SELECT path, id, file_mtime, file_size FROM track")
        var stamps: [String: (id: Int64, stamp: FileStamp)] = [:]
        while try statement.step() {
            guard let path = statement.string(0), let id = statement.int(1) else { continue }
            stamps[path] = (id, FileStamp(modified: statement.double(2), size: statement.int(3) ?? 0))
        }
        return stamps
    }

    /// Notes the stamps files have now without reading their tags (files first seen since stamps
    /// were kept, or ones susurrus rewrote itself).
    func setFileStamps(_ stamps: [(id: Int64, stamp: FileStamp)]) throws {
        guard !stamps.isEmpty else { return }
        try db.transaction {
            let update = try db.prepare("UPDATE track SET file_mtime = ?, file_size = ? WHERE id = ?")
            for (id, stamp) in stamps { try update.run([stamp.modified, stamp.size, id]) }
        }
    }

    /// Takes the tags of files that changed since they were read (another app edited them). Tags
    /// the file has replace the library's; ones it lacks, or that were only guessed from its name,
    /// leave the library's alone, since those can be edits that were never written into the file.
    /// Returns the updated tracks' IDs.
    @discardableResult
    func updateTags(from scanned: [ScannedTrack]) throws -> [Int64] {
        var ids: [Int64] = []
        try db.transaction {
            let find = try db.prepare("SELECT id FROM track WHERE path = ?")
            var updates: [String: Statement] = [:]
            for track in scanned {
                try find.bind([track.path])
                guard try find.step(), let id = find.int(0) else { continue }
                let columns = track.tags.filter(\.isSet).map { ($0.column, $0.value as Any?) } + track.properties
                let sql = "UPDATE track SET \(columns.map { "\($0.0) = ?" }.joined(separator: ", ")) WHERE id = ?"
                let update = try updates[sql] ?? db.prepare(sql)
                updates[sql] = update
                try update.run(columns.map(\.1) + [id])
                ids.append(id)
            }
        }
        return ids
    }

    /// Files that couldn't be read as audio, with the stamp they had then.
    func unreadableFiles() throws -> [String: FileStamp] {
        let statement = try db.prepare("SELECT path, file_mtime, file_size FROM unreadable_file")
        var files: [String: FileStamp] = [:]
        while try statement.step() {
            if let path = statement.string(0) { files[path] = FileStamp(modified: statement.double(1), size: statement.int(2) ?? 0) }
        }
        return files
    }

    /// Remembers files that couldn't be read, so rescans leave them alone until they change.
    func noteUnreadable(_ files: [(path: String, stamp: FileStamp)]) throws {
        guard !files.isEmpty else { return }
        try db.transaction {
            let insert = try db.prepare("INSERT OR REPLACE INTO unreadable_file (path, file_mtime, file_size) VALUES (?, ?, ?)")
            for file in files { try insert.run([file.path, file.stamp.modified, file.stamp.size]) }
        }
    }

    func forgetUnreadable(_ paths: some Sequence<String>) throws {
        try db.transaction {
            let delete = try db.prepare("DELETE FROM unreadable_file WHERE path = ?")
            for path in paths { try delete.run([path]) }
        }
    }
}
