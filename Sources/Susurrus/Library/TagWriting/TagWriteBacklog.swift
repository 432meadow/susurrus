import AppKit
import CryptoKit
import Foundation

/// The tag writes still waiting to go into files, saved in the library database
/// (`tag_write_queue`) so that quitting doesn't drop them.
///
/// Saving returns at once; a background queue writes the saves, all those that piled up in one
/// transaction. A cover is kept once per image, in a file named after its SHA-256 in "Queued
/// Covers" next to the database (the same cover usually goes into every track of an album), and
/// rows refer to it by that hash. Cover files no row refers to any more are deleted. Rows saved by
/// older versions, with the cover inline, still read. Once nothing is queued, a database with a
/// lot of unused space (those inline covers ran to gigabytes) is compacted.
final class TagWriteBacklog: @unchecked Sendable {
    private let databaseURL: URL
    private let coversFolder: URL
    /// Unused space that makes compacting worthwhile (VACUUM rewrites the whole database).
    private let compactThreshold: Int
    private let queue = DispatchQueue(label: "susurrus.tag-write-backlog", qos: .utility)
    private let lock = NSLock()
    /// Saves not in the database yet, oldest first (nil: forget the path).
    private var unsaved: [(path: String, values: TagValues?)] = []
    /// A connection of its own, used on `queue`: the store's is in use on the main thread, and
    /// a transaction can't share a connection with other work.
    private var connection: Database?

    private static let backlogsLock = NSLock()
    private static var backlogs: [String: TagWriteBacklog] = [:]

    /// The backlog of the library database at `url`. Every LibraryStore opened on that file
    /// shares it, so their saves stay in order.
    static func forLibrary(at url: URL) -> TagWriteBacklog {
        backlogsLock.withLock {
            if let backlog = backlogs[url.path] { return backlog }
            let backlog = TagWriteBacklog(databaseURL: url)
            backlogs[url.path] = backlog
            return backlog
        }
    }

    init(databaseURL: URL, compactThreshold: Int = 64 << 20) {
        self.databaseURL = databaseURL
        coversFolder = databaseURL.deletingLastPathComponent().appendingPathComponent("Queued Covers", isDirectory: true)
        self.compactThreshold = compactThreshold
        // Saves still on their way to the database go in before the app exits.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.finishSaving()
        }
    }

    /// Saves (or, with nil, forgets) the values waiting for `path`.
    func save(_ values: TagValues?, forPath path: String) {
        let isFirst = lock.withLock {
            unsaved.append((path, values))
            return unsaved.count == 1
        }
        if isFirst {
            queue.async { if self.flush() { self.compactIfWorthwhile() } }
        }
    }

    /// Waits until every save so far is in the database.
    func finishSaving() {
        queue.sync { _ = flush() }
    }

    /// The saved writes, oldest first. Each cover is read once and shared by its tracks; rows an
    /// older version saved with the cover inline are saved again with it in a file.
    func load() throws -> [(path: String, values: TagValues)] {
        let saved = try queue.sync { () -> [(path: String, values: TagValues)] in
            _ = flush()
            let statement = try database().prepare("SELECT path, tag_values FROM tag_write_queue ORDER BY rowid")
            let decoder = JSONDecoder()
            var covers: [String: Data] = [:]
            var saved: [(path: String, values: TagValues)] = []
            var resave: [(path: String, values: TagValues?)] = []
            var missingCovers = 0
            while try statement.step() {
                guard let path = statement.string(0), let json = statement.string(1),
                      let row = try? decoder.decode(Row.self, from: Data(json.utf8)) else { continue }
                var values = row.values
                if let cover = row.cover {
                    if covers[cover.sha256] == nil {
                        covers[cover.sha256] = try? Data(contentsOf: coversFolder.appendingPathComponent(cover.sha256))
                    }
                    values.artwork = covers[cover.sha256].map { Artwork(data: $0, mimeType: cover.mimeType) }
                    if values.artwork == nil {
                        missingCovers += 1
                        if values.isEmpty { resave.append((path, nil)) }
                    }
                } else if let artwork = values.artwork, !artwork.data.isEmpty {
                    let hash = Self.hash(artwork.data)
                    values.artwork?.data = covers[hash] ?? artwork.data
                    covers[hash] = values.artwork?.data
                    resave.append((path, values))
                }
                if !values.isEmpty { saved.append((path, values)) }
            }
            if missingCovers > 0 {
                EventLog.shared.log("\(missingCovers) queued tag writes lost their cover (its file is gone)")
            }
            lock.withLock { unsaved.insert(contentsOf: resave, at: 0) }
            _ = flush()
            return saved
        }
        // With nothing queued, this is a good moment to give back the space older versions used.
        if saved.isEmpty { queue.async { self.compactIfWorthwhile() } }
        return saved
    }

    /// Forgets every saved write, and their covers.
    func clear() throws {
        try queue.sync {
            lock.withLock { unsaved.removeAll() }
            try database().execute("DELETE FROM tag_write_queue")
            try? FileManager.default.removeItem(at: coversFolder)
        }
        queue.async { self.compactIfWorthwhile() }
    }

    // MARK: On the queue

    private func database() throws -> Database {
        if let connection { return connection }
        let opened = try Database(path: databaseURL.path)
        connection = opened
        return opened
    }

    /// Writes the saves made so far in one transaction and deletes the covers no row refers to
    /// any more. True when nothing is queued afterwards.
    private func flush() -> Bool {
        let batch = lock.withLock {
            defer { unsaved.removeAll() }
            return unsaved
        }
        guard !batch.isEmpty else { return false }
        do {
            let db = try database()
            let encoder = JSONEncoder()
            let rows = try batch.map { path, values in (path, try values.map { try json(for: $0, encoder) }) }
            let upsert = try db.prepare("""
                INSERT INTO tag_write_queue (path, tag_values) VALUES (?, ?)
                ON CONFLICT (path) DO UPDATE SET tag_values = excluded.tag_values
                """)
            let delete = try db.prepare("DELETE FROM tag_write_queue WHERE path = ?")
            try db.transaction {
                for (path, json) in rows {
                    if let json { try upsert.run([path, json]) } else { try delete.run([path]) }
                }
            }
            try removeUnusedCovers(db)
            return try !db.prepare("SELECT 1 FROM tag_write_queue LIMIT 1").step()
        } catch {
            EventLog.shared.log("Couldn't save the queued tag writes: \(error.localizedDescription)")
            return false
        }
    }

    /// The row saved for `values`: their JSON with the cover replaced by its hash, its image going
    /// into `coversFolder` unless it's there already.
    private func json(for values: TagValues, _ encoder: JSONEncoder) throws -> String {
        var row = Row(values: values)
        if let artwork = values.artwork, !artwork.data.isEmpty {
            let hash = Self.hash(artwork.data)
            let file = coversFolder.appendingPathComponent(hash)
            if !FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.createDirectory(at: coversFolder, withIntermediateDirectories: true)
                try artwork.data.write(to: file, options: .atomic)
            }
            row.values.artwork = nil
            row.cover = Row.Cover(sha256: hash, mimeType: artwork.mimeType)
        }
        return String(decoding: try encoder.encode(row), as: UTF8.self)
    }

    private func removeUnusedCovers(_ db: Database) throws {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: coversFolder.path)) ?? []
        guard !files.isEmpty else { return }
        let statement = try db.prepare("""
            SELECT DISTINCT json_extract(tag_values, '$.cover.sha256') FROM tag_write_queue WHERE json_valid(tag_values)
            """)
        var used = Set<String>()
        while try statement.step() {
            if let hash = statement.string(0) { used.insert(hash) }
        }
        for file in files where !used.contains(file) {
            try? FileManager.default.removeItem(at: coversFolder.appendingPathComponent(file))
        }
    }

    /// Compacts the database when nothing is queued and enough of it is unused. Deleted rows
    /// leave free pages that the file never gives back by itself.
    private func compactIfWorthwhile() {
        do {
            let db = try database()
            guard try !db.prepare("SELECT 1 FROM tag_write_queue LIMIT 1").step() else { return }
            func pragma(_ name: String) throws -> Int {
                let statement = try db.prepare("PRAGMA \(name)")
                return try statement.step() ? Int(statement.int(0) ?? 0) : 0
            }
            let unused = try pragma("freelist_count") * pragma("page_size")
            guard unused >= compactThreshold else { return }
            try db.execute("VACUUM")
            // VACUUM went through the write-ahead log; empty that too.
            try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            EventLog.shared.log("Compacted the library database (\(unused / 1_048_576) MB unused)", level: .info)
        } catch {
            EventLog.shared.log("Couldn't compact the library database: \(error.localizedDescription)")
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A saved write as stored: one JSON object with the values' keys, plus the cover's file
    /// when there is one (older versions stored the image itself, as the values' artwork).
    private struct Row: Codable {
        struct Cover: Codable {
            var sha256: String
            var mimeType: String
        }

        var values: TagValues
        var cover: Cover?

        private enum CodingKeys: String, CodingKey { case cover }

        init(values: TagValues) {
            self.values = values
        }

        init(from decoder: Decoder) throws {
            values = try TagValues(from: decoder)
            cover = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Cover.self, forKey: .cover)
        }

        func encode(to encoder: Encoder) throws {
            try values.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(cover, forKey: .cover)
        }
    }
}
