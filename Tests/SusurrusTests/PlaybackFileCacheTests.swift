import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// The playback file cache, with every file taken for one on the network share, and a named pipe
/// standing in for a share that's slow to send.
@MainActor
@Suite(.serialized) struct PlaybackFileCacheTests {
    let folder: URL
    let copies: URL
    let wav: URL
    let flac: URL
    let locate: @Sendable (TrackRef) -> URL? = { URL(fileURLWithPath: $0.path) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        copies = folder.appendingPathComponent("copies")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        wav = folder.appendingPathComponent("tone.wav")
        try ToneFile.write(to: wav, seconds: 0.5)
        flac = folder.appendingPathComponent("tone.flac")
        try ToneFile.write(to: flac, seconds: 0.5, format: kAudioFormatFLAC)
    }

    private func makeCache(byteLimit: Int64 = 1 << 30) -> PlaybackFileCache {
        PlaybackFileCache(directory: copies, byteLimit: byteLimit, isLocal: { _ in false })
    }

    /// A file on a share that hasn't sent anything yet. Returns the write end (opened read-write,
    /// so it doesn't wait for a reader): write to it to send, close it to end the file.
    private func slowFile(named name: String) throws -> (url: URL, sender: Int32) {
        let url = folder.appendingPathComponent(name)
        guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(.EEXIST) }
        let sender = open(url.path, O_RDWR)
        guard sender >= 0 else { throw POSIXError(.EBADF) }
        return (url, sender)
    }

    private func send(_ bytes: Int, to sender: Int32) {
        let data = [UInt8](repeating: 0x5A, count: bytes)
        _ = data.withUnsafeBytes { write(sender, $0.baseAddress, bytes) }
    }

    private var copiedFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: copies.path)) ?? []).sorted()
    }

    private func waitUntil(timeout: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func streamsWhatItCanAndCopiesTheRest() async throws {
        let cache = makeCache()
        let streamed = try #require(await cache.openFile(for: TrackRef(id: 1, path: wav.path), immediate: true, locate: locate))
        #expect(streamed.isStreaming && streamed.file.url == wav)
        // FLAC is copied even when it's wanted right away; tracks fetched ahead are always copied.
        let flacNow = try #require(await cache.openFile(for: TrackRef(id: 2, path: flac.path), immediate: true, locate: locate))
        #expect(!flacNow.isStreaming && flacNow.file.url.path.hasPrefix(copies.path))
        let ahead = try #require(await cache.openFile(for: TrackRef(id: 3, path: wav.path), locate: locate))
        #expect(!ahead.isStreaming && ahead.file.url.path.hasPrefix(copies.path))
        // Once copied, the copy is used even when the track is wanted right away.
        let later = try #require(await cache.openFile(for: TrackRef(id: 3, path: wav.path), immediate: true, locate: locate))
        #expect(later.file.url == ahead.file.url)
        #expect(await cache.openFile(for: TrackRef(id: 4, path: "/nonexistent/4.mp3"), immediate: true, locate: locate) == nil)

        // Files on the Mac's own disks are played in place.
        let local = PlaybackFileCache(directory: folder.appendingPathComponent("local"))
        let inPlace = try #require(await local.openFile(for: TrackRef(id: 5, path: flac.path), locate: locate))
        #expect(!inPlace.isStreaming && inPlace.file.url == flac)
    }

    @Test func aTrackWantedNowStreamsRatherThanWaitForItsCopy() async throws {
        let cache = makeCache()
        let slow = try slowFile(named: "slow.wav")
        let ahead = Task { await cache.openFile(for: TrackRef(id: 7, path: slow.url.path), locate: locate) }
        #expect(await waitUntil { copiedFiles.contains { $0.hasSuffix(".partial") } }, "the copy has started")

        // The same track, now wanted right away (Next was pressed): it plays from the share.
        let now = try #require(await cache.openFile(for: TrackRef(id: 7, path: wav.path), immediate: true, locate: locate))
        #expect(now.isStreaming && now.file.url == wav)
        close(slow.sender)
        _ = await ahead.value
    }

    @Test func aCopyNobodyNeedsStopsBetweenChunksAndTidiesUp() async throws {
        let cache = makeCache()
        let slow = try slowFile(named: "slow.wav")
        defer { close(slow.sender) }
        let request = Task { await cache.openFile(for: TrackRef(id: 8, path: slow.url.path), locate: locate) }
        #expect(await waitUntil { copiedFiles.contains { $0.hasSuffix(".partial") } })
        send(4096, to: slow.sender)

        request.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        send(4096, to: slow.sender)
        #expect(await request.value == nil)
        // The share never finished sending, but the partial copy is gone.
        #expect(await waitUntil { copiedFiles.isEmpty }, "\(copiedFiles)")
    }

    @Test func aNewCopyOfATrackDoesntCollideWithOneWindingDown() async throws {
        let cache = makeCache()
        let slow = try slowFile(named: "slow.wav")
        let first = Task { await cache.openFile(for: TrackRef(id: 9, path: slow.url.path), locate: locate) }
        #expect(await waitUntil { copiedFiles.contains { $0.hasSuffix(".partial") } })
        first.cancel()
        try? await Task.sleep(for: .milliseconds(100))

        // Asked for again (from where it really is) while the first copy is still stuck.
        let second = try #require(await cache.openFile(for: TrackRef(id: 9, path: wav.path), locate: locate))
        #expect(second.file.length > 0)
        close(slow.sender)
        _ = await first.value
        #expect(await waitUntil { copiedFiles == [second.file.url.lastPathComponent] }, "\(copiedFiles)")
    }

    @Test func keepsTheNewestAndWantedCopiesWithinItsLimit() async throws {
        let cache = makeCache(byteLimit: 1)
        let owner = NSObject()
        let a = try #require(await cache.openFile(for: TrackRef(id: 1, path: wav.path), locate: locate))
        cache.keep([1], for: owner)
        let b = try #require(await cache.openFile(for: TrackRef(id: 2, path: wav.path), locate: locate))
        let c = try #require(await cache.openFile(for: TrackRef(id: 3, path: flac.path), locate: locate))
        // Over the limit: the oldest copy nobody wants goes; a wanted one and the newest stay.
        let names = [a, c].map(\.file.url.lastPathComponent).sorted()
        #expect(await waitUntil { copiedFiles == names }, "\(copiedFiles)")
        #expect(!copiedFiles.contains(b.file.url.lastPathComponent))

        cache.keep([], for: owner)
        #expect(await waitUntil { copiedFiles == [c.file.url.lastPathComponent] }, "\(copiedFiles)")
    }
}
