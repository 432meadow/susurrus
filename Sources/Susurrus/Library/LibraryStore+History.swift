import Foundation

/// Play history, removing tracks, and the saved tag-write queue.
extension LibraryStore {
    // MARK: Play history

    /// Track IDs of the most recent plays, newest first (a track played twice is listed twice).
    func historyTrackIDs(limit: Int) throws -> [Int64] {
        let statement = try db.prepare("SELECT track_id FROM play_history ORDER BY played_at DESC, id DESC LIMIT ?")
        try statement.bind([limit])
        var ids: [Int64] = []
        while try statement.step() { ids.append(statement.int(0)!) }
        return ids
    }

    func clearHistory() throws {
        try db.execute("DELETE FROM play_history")
    }

    // MARK: Removing tracks

    /// Deletes tracks from the library (their playlist entries and history go with them).
    /// The files themselves are never touched.
    func deleteTracks(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let delete = try db.prepare("DELETE FROM track WHERE id = ?")
        try db.transaction {
            for id in ids { try delete.run([id]) }
        }
    }

    // MARK: Saved tag writes

    /// Tag writes that were still queued when susurrus last quit.
    func pendingTagWrites() throws -> [(path: String, values: TagValues)] {
        try tagWriteBacklog.load()
    }

    /// Saves (or, with nil, forgets) the write still waiting for `path`. Returns right away: the
    /// saving is batched and done in the background (see `TagWriteBacklog`).
    func savePendingTagWrite(_ values: TagValues?, forPath path: String) throws {
        tagWriteBacklog.save(values, forPath: path)
    }

    func clearPendingTagWrites() throws {
        try tagWriteBacklog.clear()
    }

    private var tagWriteBacklog: TagWriteBacklog { TagWriteBacklog.forLibrary(at: url) }
}
