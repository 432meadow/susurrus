import CryptoKit
import Foundation
import Testing
@testable import Susurrus

/// The saved tag-write queue, in a throwaway library database (covers in files next to it).
@Suite struct TagWriteBacklogTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TagWriteBacklogTests-\(UUID().uuidString)")
    let store: LibraryStore
    let cover = Artwork(data: Data(LargeCover.bytes), mimeType: "image/jpeg")

    init() throws {
        store = try LibraryStore(url: folder.appendingPathComponent("Library.sqlite"))
    }

    private var coverFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Queued Covers").path)) ?? []
    }

    private func value(_ sql: String) throws -> Int {
        let statement = try store.db.prepare(sql)
        return try statement.step() ? Int(statement.int(0) ?? 0) : 0
    }

    /// A row as versions before covers were kept in files saved it, image and all.
    private func saveTheOldWay(_ values: TagValues, forPath path: String) throws {
        let json = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        try store.db.prepare("INSERT INTO tag_write_queue (path, tag_values) VALUES (?, ?)").run([path, json])
    }

    @Test func aCoverIsStoredOnceAndRowsOnlyNameIt() throws {
        for n in 1...3 { try store.savePendingTagWrite(TagValues(artwork: cover), forPath: "/music/\(n).flac") }
        try store.savePendingTagWrite(TagValues(title: "Title"), forPath: "/music/4.flac")

        let pending = try store.pendingTagWrites()
        #expect(pending.map(\.path) == (1...4).map { "/music/\($0).flac" })
        #expect(pending.prefix(3).allSatisfy { $0.values == TagValues(artwork: cover) })
        #expect(pending.last?.values == TagValues(title: "Title"))
        #expect(coverFiles == [SHA256.hash(data: cover.data).map { String(format: "%02x", $0) }.joined()])
        #expect(try value("SELECT max(length(tag_values)) FROM tag_write_queue") < 200, "no image in the database")
    }

    @Test func coverFilesGoWithTheLastRowUsingThem() throws {
        let other = Artwork(data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        try store.savePendingTagWrite(TagValues(artwork: cover), forPath: "/music/1.flac")
        try store.savePendingTagWrite(TagValues(title: "Two", artwork: cover), forPath: "/music/2.flac")
        try store.savePendingTagWrite(TagValues(artwork: other), forPath: "/music/3.flac")
        _ = try store.pendingTagWrites()
        #expect(coverFiles.count == 2)

        try store.savePendingTagWrite(nil, forPath: "/music/1.flac")
        _ = try store.pendingTagWrites()
        #expect(coverFiles.count == 2, "track 2 still needs the cover")

        // Track 2's cover went in, its title is still to do; track 3 is done.
        try store.savePendingTagWrite(TagValues(title: "Two"), forPath: "/music/2.flac")
        try store.savePendingTagWrite(nil, forPath: "/music/3.flac")
        #expect(try store.pendingTagWrites().map(\.values) == [TagValues(title: "Two")])
        #expect(coverFiles.isEmpty)
    }

    @Test func rowsWithTheCoverInlineStillReadAndAreSavedAgainSmall() throws {
        let png = Artwork(data: Data([0x89, 0x50, 0x4E, 0x47] + LargeCover.bytes))
        try saveTheOldWay(TagValues(title: "Old", artwork: png), forPath: "/music/old.mp3")
        try saveTheOldWay(TagValues(artwork: .removed), forPath: "/music/bare.mp3")
        #expect(try value("SELECT max(length(tag_values)) FROM tag_write_queue") > 200_000)

        let pending = try store.pendingTagWrites()
        #expect(pending.map(\.path) == ["/music/old.mp3", "/music/bare.mp3"])
        #expect(pending.first?.values == TagValues(title: "Old", artwork: png))
        #expect(pending.last?.values == TagValues(artwork: .removed), "removing the cover is still a write")
        #expect(try value("SELECT max(length(tag_values)) FROM tag_write_queue") < 200)
        #expect(coverFiles.count == 1)
        #expect(try store.pendingTagWrites().map(\.values) == pending.map(\.values))
    }

    @Test func clearingForgetsRowsAndCovers() throws {
        try store.savePendingTagWrite(TagValues(title: "Title", artwork: cover), forPath: "/music/1.flac")
        _ = try store.pendingTagWrites()
        #expect(!coverFiles.isEmpty)
        try store.clearPendingTagWrites()
        #expect(try store.pendingTagWrites().isEmpty)
        #expect(coverFiles.isEmpty)
    }

    @Test func updatedWritesKeepTheirPlaceInLine() throws {
        try store.savePendingTagWrite(TagValues(title: "A"), forPath: "/music/a.mp3")
        try store.savePendingTagWrite(TagValues(title: "B"), forPath: "/music/b.mp3")
        _ = try store.pendingTagWrites()
        try store.savePendingTagWrite(TagValues(title: "A", rating: 5), forPath: "/music/a.mp3")
        let pending = try store.pendingTagWrites()
        #expect(pending.map(\.path) == ["/music/a.mp3", "/music/b.mp3"])
        #expect(pending.first?.values == TagValues(title: "A", rating: 5))
    }

    @Test func emptyingTheQueueCompactsADatabaseThatsMostlyUnused() throws {
        let backlog = TagWriteBacklog(databaseURL: folder.appendingPathComponent("Library.sqlite"), compactThreshold: 1 << 20)
        try saveTheOldWay(TagValues(artwork: Artwork(data: Data(repeating: 7, count: 2 << 20))), forPath: "/music/1.mp3")
        _ = try backlog.load()
        #expect(try value("PRAGMA freelist_count") * value("PRAGMA page_size") > 2 << 20, "the inline cover's space is unused now")

        backlog.save(nil, forPath: "/music/1.mp3")
        backlog.finishSaving()
        #expect(try value("PRAGMA freelist_count") == 0)
        let size = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("Library.sqlite").path)[.size] as? Int
        #expect((size ?? .max) < 1 << 20)
    }

    @MainActor @Test func aQuitWhileAFileIsWrittenLeavesEveryEditToItSaved() async throws {
        let gate = Gate()
        let queue = TagWriteQueue { _, _ in
            await gate.wait()
            return .written(fileSize: 1)
        }
        queue.persist = { [store] path, values in try? store.savePendingTagWrite(values, forPath: path) }
        queue.enqueue(TagValues(title: "A"), path: "/music/a.mp3")
        let deadline = Date().addingTimeInterval(10)
        while queue.currentPath == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        queue.enqueue(TagValues(rating: 4), path: "/music/a.mp3")

        // What the next launch would pick up.
        let reopened = try LibraryStore(url: folder.appendingPathComponent("Library.sqlite"))
        #expect(try reopened.pendingTagWrites().map(\.values) == [TagValues(title: "A", rating: 4)])

        gate.open()
        await queue.waitUntilIdle()
        #expect(try store.pendingTagWrites().isEmpty)
    }
}
