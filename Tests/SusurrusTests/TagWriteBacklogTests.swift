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

/// Writes that fail for a reason that can pass stay saved and go in later; ones that can't work are
/// reported. A stand-in writer plays the share: nothing here touches a real file.
@MainActor
@Suite struct TagWriteRetryTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TagWriteRetryTests-\(UUID().uuidString)")
    let store: LibraryStore

    init() throws {
        store = try LibraryStore(url: folder.appendingPathComponent("Library.sqlite"))
    }

    /// Records every attempt, and fails them with `error` while it's set.
    private final class Share: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: Error?
        private var tries: [(path: String, values: TagValues)] = []

        init(failingWith error: Error?) { failure = error }

        var attempts: [(path: String, values: TagValues)] { lock.withLock { tries } }

        func comeBack() { lock.withLock { failure = nil } }

        func write(_ values: TagValues, _ url: URL) throws -> TagFileWriter.Outcome {
            try lock.withLock {
                tries.append((url.path, values))
                if let failure { throw failure }
                return .written(fileSize: 1)
            }
        }
    }

    private func makeQueue(_ share: Share, waitingRetryDelay: Duration = .seconds(3600)) -> TagWriteQueue {
        let queue = TagWriteQueue(retryDelay: .milliseconds(10), waitingRetryDelay: waitingRetryDelay) { try share.write($0, $1) }
        queue.persist = { [store] path, values in try? store.savePendingTagWrite(values, forPath: path) }
        return queue
    }

    @Test func aShareThatDroppedCostsOneTryAndItsFilesGoInOnceItsBack() async throws {
        let share = Share(failingWith: POSIXError(.ENOTCONN))
        let queue = makeQueue(share)
        let paths = ["/Volumes/Share/a.mp3", "/Volumes/Share/b.mp3", "/Volumes/Other/c.mp3"]
        for path in paths { queue.enqueue(TagValues(title: path), path: path) }
        await queue.waitUntilIdle()

        #expect(share.attempts.map(\.path) == ["/Volumes/Share/a.mp3", "/Volumes/Other/c.mp3"], "one try per volume")
        #expect(Set(queue.waiting.keys) == Set(paths) && queue.failures.isEmpty)
        #expect(paths.allSatisfy(queue.isWriting), "their files can't be moved yet")

        // What the next launch would pick up.
        let reopened = try LibraryStore(url: folder.appendingPathComponent("Library.sqlite"))
        #expect(try reopened.pendingTagWrites().map(\.path).sorted() == paths.sorted())

        share.comeBack()
        queue.retryWaiting()
        await queue.waitUntilIdle()
        #expect(queue.waiting.isEmpty && queue.written == 3)
        #expect(try store.pendingTagWrites().isEmpty)
    }

    @Test func theWaitingAreTriedAgainOnTheirOwn() async throws {
        let share = Share(failingWith: POSIXError(.ETIMEDOUT))
        let queue = makeQueue(share, waitingRetryDelay: .milliseconds(20))
        queue.enqueue(TagValues(title: "A"), path: "/Volumes/Share/a.mp3")
        await queue.waitUntilIdle()
        #expect(!queue.waiting.isEmpty)
        share.comeBack()
        let deadline = Date().addingTimeInterval(10)
        while !queue.waiting.isEmpty || queue.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(queue.waiting.isEmpty && queue.written == 1)
    }

    @Test func anEditToAWaitingFileGoesInWithWhatItOwes() async throws {
        let share = Share(failingWith: POSIXError(.EHOSTDOWN))
        let queue = makeQueue(share)
        queue.enqueue(TagValues(title: "Old", rating: 3), path: "/Volumes/Share/a.mp3")
        await queue.waitUntilIdle()
        share.comeBack()
        queue.enqueue(TagValues(title: "New"), path: "/Volumes/Share/a.mp3")
        #expect(try store.pendingTagWrites().map(\.values) == [TagValues(title: "New", rating: 3)], "saved merged")
        await queue.waitUntilIdle()
        #expect(share.attempts.last?.values == TagValues(title: "New", rating: 3))
        #expect(queue.waiting.isEmpty)
    }

    @Test func anEditThatArrivedDuringAFailedWriteIsntWrittenWithoutIt() async throws {
        let gate = Gate()
        let writes = Share(failingWith: nil)
        var failNext = true
        let queue = TagWriteQueue(retryDelay: .milliseconds(10), waitingRetryDelay: .seconds(3600)) { values, url in
            let shouldFail = await MainActor.run { () -> Bool in
                defer { failNext = false }
                return failNext
            }
            if shouldFail {
                await gate.wait()
                throw POSIXError(.ENOTCONN)
            }
            return try writes.write(values, url)
        }
        queue.enqueue(TagValues(title: "A"), path: "/Volumes/Share/a.mp3")
        let deadline = Date().addingTimeInterval(10)
        while queue.currentPath == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        queue.enqueue(TagValues(rating: 4), path: "/Volumes/Share/a.mp3")
        gate.open()
        await queue.waitUntilIdle()
        #expect(writes.attempts.map(\.values) == [TagValues(title: "A", rating: 4)])
    }

    @Test func aFileThatKeepsChangingEndsUpReported() async throws {
        let share = Share(failingWith: TagWriteError.modifiedSinceRead)
        let queue = makeQueue(share, waitingRetryDelay: .milliseconds(10))
        queue.enqueue(TagValues(title: "A"), path: "/music/a.mp3")
        let deadline = Date().addingTimeInterval(10)
        while queue.failures.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        await queue.waitUntilIdle()
        #expect(share.attempts.count == 3)
        #expect(queue.failures.map(\.path) == ["/music/a.mp3"] && queue.waiting.isEmpty)
        #expect(try store.pendingTagWrites().isEmpty, "given up on, so not picked up again at every launch")
    }

    @Test func aWriteThatCantWorkIsReportedAndTryAgainStillHasItsValues() async throws {
        let share = Share(failingWith: TagWriteError.unsupportedFormat("WAV"))
        let queue = makeQueue(share)
        queue.enqueue(TagValues(rating: 5), path: "/music/a.wav")
        await queue.waitUntilIdle()
        #expect(queue.failures.map(\.path) == ["/music/a.wav"] && queue.waiting.isEmpty)
        #expect(try store.pendingTagWrites().isEmpty)

        share.comeBack()
        queue.retryFailures()
        #expect(try store.pendingTagWrites().map(\.values) == [TagValues(rating: 5)], "saved again while it's being tried")
        await queue.waitUntilIdle()
        #expect(queue.failures.isEmpty && queue.written == 1)
        #expect(share.attempts.last?.values == TagValues(rating: 5))
    }

    @Test func aNewEditCarriesWhatFailedBeforeAndReplacesItsRow() async throws {
        let share = Share(failingWith: TagWriteError.unsupportedFormat("WAV"))
        let queue = makeQueue(share)
        queue.enqueue(TagValues(rating: 5), path: "/music/a.wav")
        await queue.waitUntilIdle()
        queue.enqueue(TagValues(title: "New"), path: "/music/a.wav")
        await queue.waitUntilIdle()
        #expect(share.attempts.last?.values == TagValues(title: "New", rating: 5))
        #expect(queue.failures.count == 1, "one row per file")
    }

    @Test func forgettingTheWaitingDropsTheirSavedWrites() async throws {
        let share = Share(failingWith: POSIXError(.ENOTCONN))
        let queue = makeQueue(share)
        queue.enqueue(TagValues(title: "A"), path: "/Volumes/Share/a.mp3")
        await queue.waitUntilIdle()
        queue.forgetWaiting()
        #expect(queue.waiting.isEmpty && !queue.isWriting("/Volumes/Share/a.mp3"))
        #expect(try store.pendingTagWrites().isEmpty)
    }

    @Test func whatAFailureMeans() throws {
        let present = folder.appendingPathComponent("a.mp3").path  // not under /Volumes: its volume is there
        let gone = "/Volumes/NoSuchShare-\(UUID().uuidString)/a.mp3"
        func retry(_ error: Error, _ path: String) -> TagFileWriter.Retry { TagFileWriter.retry(after: error, path: path) }

        #expect(retry(TagWriteError.fileMissing, present) == .never, "the file itself is gone")
        #expect(retry(TagWriteError.fileMissing, gone) == .whenReachable, "its share is gone")
        #expect(retry(CocoaError(.fileReadNoSuchFile), present) == .never)
        #expect(retry(CocoaError(.fileReadNoSuchFile), gone) == .whenReachable)
        #expect(retry(POSIXError(.ENOENT), gone) == .whenReachable)
        #expect(retry(POSIXError(.ETIMEDOUT), present) == .whenReachable)
        #expect(retry(POSIXError(.ENOTCONN), gone) == .whenReachable)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTDOWN))])
        #expect(retry(wrapped, present) == .whenReachable, "however deep Foundation wrapped it")
        #expect(retry(TagWriteError.modifiedSinceRead, present) == .soon)
        #expect(retry(TagWriteError.partlyWritten, present) == .whenReachable, "another try repairs it")
        #expect(retry(TagWriteError.unsupportedFormat("WAV"), gone) == .never)
        #expect(retry(TagWriteError.malformed("x"), present) == .never)
        #expect(retry(TagWriteError.verificationFailed("x"), present) == .never)
        #expect(retry(POSIXError(.EACCES), present) == .never)
        #expect(!TagFileWriter.volumeIsGone(present))
        #expect(TagFileWriter.volumeIsGone(gone))
    }

    @Test func theWriterTellsAMissingFileFromAnUnreachableOne() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("plain")
        try Data([1]).write(to: file)
        await #expect(throws: TagWriteError.fileMissing) {
            try await TagFileWriter.write(TagValues(title: "A"), to: folder.appendingPathComponent("nothing.mp3"))
        }
        await #expect(throws: TagWriteError.fileMissing) {
            try await TagFileWriter.write(TagValues(title: "A"), to: file.appendingPathComponent("under-a-file.mp3"))
        }
    }

    @Test func withWritingOffOnlyDownloadsKeepTheirSavedWrites() async throws {
        let downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
        let kept = downloads.appendingPathComponent("Album/01.mp3").path
        try store.savePendingTagWrite(TagValues(title: "Kept"), forPath: kept)
        try store.savePendingTagWrite(TagValues(title: "Dropped"), forPath: folder.appendingPathComponent("Music/01.mp3").path)
        _ = try store.pendingTagWrites()
        defer { UserDefaults.standard.removeObject(forKey: "soulseek.downloadFolder") }
        UserDefaults.standard.set(downloads.path, forKey: "soulseek.downloadFolder")

        let model = AppModel(libraryURL: folder.appendingPathComponent("Library.sqlite"))
        #expect(!model.writesTagsToFiles)
        #expect(model.tagWriter.isWriting(kept))
        await model.tagWriter.waitUntilIdle()
        #expect(model.tagWriter.failures.map(\.path) == [kept], "the only one tried; the file isn't really there")
    }
}
