import AVFoundation
import Foundation

/// Identifies a track's file without touching the (main-actor) `Track` object.
struct TrackRef: Sendable, Hashable {
    let id: Int64
    let path: String
}

/// An audio file opened for playback, and whether it's read straight from a network share rather
/// than from a local copy.
struct PlaybackFile {
    let file: AVAudioFile
    let isStreaming: Bool
}

/// Makes audio files safe to play from a network share. One cache serves the queue player and the
/// mixer, so a track on both (Continue in Mixer) is copied once.
///
/// AVAudioPlayerNode reads lazily from the file while playing. For files on SMB that means every
/// network hiccup stalls the audio, and for FLAC without a seek table AudioToolbox scans the
/// whole file (`FLACAudioFile::ScanForPackets`) over the network. So files on non-local volumes
/// are copied into a local cache first; local files are played in place. The least recently used
/// copies go once they take up more than `byteLimit`.
///
/// Copies run a chunk at a time on `BlockingIO` threads and stop early once nothing needs them: no
/// request is waiting for one, and no owner (the player, the mixer) still wants its track. The
/// bookkeeping is tiny, so it stays on the main actor.
@MainActor
final class PlaybackFileCache {
    static let shared: PlaybackFileCache = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("susurrus")
        // The mixer kept copies of its own here before it shared this cache.
        try? FileManager.default.removeItem(at: caches.appendingPathComponent("Mixer"))
        return PlaybackFileCache(directory: caches.appendingPathComponent("Playback"))
    }()

    /// A track's file once fetched: our copy, or the original (local, or on the share when the copy
    /// failed).
    private struct Fetched: Sendable {
        let url: URL
        let isStreaming: Bool
        /// The size of our copy; nil when `url` is the original.
        let copiedBytes: Int64?
    }

    /// Finding, and if need be copying, one track's file.
    private final class Fetch {
        let id: Int
        let task: Task<Fetched?, Never>
        /// Set once the copy is done and kept.
        var copy: Fetched?
        /// Requests waiting for it, or opening it.
        var waiters: Set<Int> = []

        init(id: Int, task: Task<Fetched?, Never>) {
            self.id = id
            self.task = task
        }
    }

    /// Formats AudioToolbox must scan end to end to find packets (no reliable seek table).
    /// These are always copied first; streaming them reads the whole file over the network anyway.
    private static let scanFirstExtensions: Set<String> = ["flac"]
    /// Bytes per step of a copy, between checks that it's still needed (under a second of the
    /// share's throughput).
    private nonisolated static let copyChunkSize = 1 << 20

    private let directory: URL
    /// How much disk the copies may take before the least recently used go.
    private let byteLimit: Int64
    private let isLocal: @Sendable (URL) -> Bool
    private let io = BlockingIO.playback
    /// One fetch per track, so the current and prefetched next track never copy twice.
    private var fetches: [Int64: Fetch] = [:]
    /// Tracks with fetches, least recently used first.
    private var recent: [Int64] = []
    /// The tracks each owner still needs.
    private var wanted: [ObjectIdentifier: Set<Int64>] = [:]
    private var lastFetchID = 0
    private var lastWaiterID = 0

    /// `isLocal` decides which files are played in place (tests stand in for a share with it).
    init(directory: URL, byteLimit: Int64 = 1 << 30,
         isLocal: @escaping @Sendable (URL) -> Bool = { PlaybackFileCache.isOnLocalVolume($0) }) {
        self.directory = directory
        self.byteLimit = byteLimit
        self.isLocal = isLocal
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated static func isOnLocalVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }

    /// Opens the track for playback, or nil if its file can't be found or read.
    ///
    /// `immediate` is for a track the user just asked to hear: lossy/PCM files on a slow share
    /// then play straight from it (they need ~40 KB/s) instead of waiting for a full copy, even
    /// when one is under way (it finishes in the background). Tracks fetched ahead of time
    /// (`immediate == false`) are copied locally for glitch-free gapless playback.
    func openFile(for track: TrackRef, immediate: Bool = false,
                  locate: @escaping @Sendable (TrackRef) -> URL?) async -> PlaybackFile? {
        let ext = (track.path as NSString).pathExtension.lowercased()
        if immediate, fetches[track.id]?.copy == nil, !Self.scanFirstExtensions.contains(ext) {
            let isLocal = isLocal
            return await io.run {
                guard let url = locate(track) else { return nil }
                return Self.open(url, isStreaming: !isLocal(url))
            }
        }

        let fetch = fetches[track.id] ?? startFetch(track, locate: locate)
        touch(track.id)
        lastWaiterID += 1
        let waiter = lastWaiterID
        let fetchID = fetch.id
        fetch.waiters.insert(waiter)
        defer {
            fetch.waiters.remove(waiter)
            evict()
        }
        let fetched = await withTaskCancellationHandler {
            await fetch.task.value
        } onCancel: {
            Task { @MainActor in self.withdraw(waiter, trackID: track.id, fetchID: fetchID) }
        }
        guard let fetched, !Task.isCancelled else { return nil }
        return await io.run { Self.open(fetched.url, isStreaming: fetched.isStreaming) }
    }

    /// Records which tracks `owner` still needs, so copies of the others can go. One still under
    /// way stops, unless a request is waiting for it.
    func keep(_ trackIDs: Set<Int64>, for owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        let released = (wanted[key] ?? []).subtracting(trackIDs)
        wanted[key] = trackIDs.isEmpty ? nil : trackIDs
        for trackID in released { cancelIfUnneeded(trackID) }
        evict()
    }

    // MARK: Fetching

    private func startFetch(_ track: TrackRef, locate: @escaping @Sendable (TrackRef) -> URL?) -> Fetch {
        lastFetchID += 1
        let fetchID = lastFetchID
        // Named per fetch, so a cancelled copy still winding down never collides with a newer one.
        let destination = directory.appendingPathComponent("\(track.id)-\(fetchID)")
        let isLocal = isLocal
        let task = Task { [io] in
            let fetched = await io.run(cancellable: { isCancelled -> Fetched? in
                guard let source = locate(track) else { return nil }
                if isLocal(source) { return Fetched(url: source, isStreaming: false, copiedBytes: nil) }
                let copy = destination.appendingPathExtension(source.pathExtension)
                do {
                    let bytes = try Self.copy(source, to: copy, isCancelled: isCancelled)
                    return Fetched(url: copy, isStreaming: false, copiedBytes: bytes)
                } catch is CancellationError {
                    return nil
                } catch {
                    // Copy failed (share dropped mid-copy, disk full): fall back to streaming from the share.
                    return Fetched(url: source, isStreaming: true, copiedBytes: nil)
                }
            })
            self.finish(track.id, fetchID: fetchID, with: fetched)
            return fetched
        }
        let fetch = Fetch(id: fetchID, task: task)
        fetches[track.id] = fetch
        return fetch
    }

    private func finish(_ trackID: Int64, fetchID: Int, with fetched: Fetched?) {
        guard let fetch = fetches[trackID], fetch.id == fetchID else {
            // Cancelled while it ran: nothing will use this copy.
            if let fetched, fetched.copiedBytes != nil { delete(fetched.url) }
            return
        }
        if let fetched, fetched.copiedBytes != nil {
            fetch.copy = fetched
            evict()
        } else {
            // A local original, a failed copy or a missing file: nothing to keep, and the next
            // request looks again.
            forget(trackID)
        }
    }

    private func withdraw(_ waiter: Int, trackID: Int64, fetchID: Int) {
        guard let fetch = fetches[trackID], fetch.id == fetchID else { return }
        fetch.waiters.remove(waiter)
        cancelIfUnneeded(trackID)
    }

    /// Stops a copy under way that no request is waiting for and no owner wants any more.
    private func cancelIfUnneeded(_ trackID: Int64) {
        guard let fetch = fetches[trackID], fetch.copy == nil, fetch.waiters.isEmpty,
              !isWanted(trackID) else { return }
        fetch.task.cancel()
        forget(trackID)
    }

    // MARK: Keeping copies

    /// Deletes the least recently used copies until the rest fit in `byteLimit`. Copies an owner
    /// wants, copies being opened, and the newest one are spared.
    private func evict() {
        var total = fetches.values.reduce(Int64(0)) { $0 + ($1.copy?.copiedBytes ?? 0) }
        for trackID in recent.dropLast() where total > byteLimit {
            guard let fetch = fetches[trackID], let copy = fetch.copy, let bytes = copy.copiedBytes,
                  fetch.waiters.isEmpty, !isWanted(trackID) else { continue }
            forget(trackID)
            total -= bytes
            delete(copy.url)
        }
    }

    private func isWanted(_ trackID: Int64) -> Bool {
        wanted.values.contains { $0.contains(trackID) }
    }

    private func touch(_ trackID: Int64) {
        recent.removeAll { $0 == trackID }
        recent.append(trackID)
    }

    private func forget(_ trackID: Int64) {
        fetches[trackID] = nil
        recent.removeAll { $0 == trackID }
    }

    private func delete(_ url: URL) {
        io.perform { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: File work (on `io` threads)

    /// Opens a file for playback. Reading `length` up front forces any packet-table scan to happen
    /// here, not during playback.
    private nonisolated static func open(_ url: URL, isStreaming: Bool) -> PlaybackFile? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return PlaybackFile(file: file, isStreaming: isStreaming)
    }

    /// Copies `source` to `destination` through a `.partial` file, returning the bytes copied. Stops
    /// (and removes the partial file) between chunks once `isCancelled` says so.
    private nonisolated static func copy(_ source: URL, to destination: URL, isCancelled: () -> Bool) throws -> Int64 {
        let partial = destination.appendingPathExtension("partial")
        do {
            let bytes = try copyChunks(from: source, to: partial, isCancelled: isCancelled)
            try FileManager.default.moveItem(at: partial, to: destination)
            return bytes
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private nonisolated static func copyChunks(from source: URL, to partial: URL, isCancelled: () -> Bool) throws -> Int64 {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: partial])
        }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        // read(2) hands back whatever has arrived, where FileHandle's read(upToCount:) waits for
        // the whole count: a trickling transfer still gets to check between chunks.
        var buffer = Data(count: copyChunkSize)
        var bytes: Int64 = 0
        while !isCancelled() {
            let count = buffer.withUnsafeMutableBytes { read(input.fileDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { return bytes }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try output.write(contentsOf: buffer.prefix(count))
            bytes += Int64(count)
        }
        throw CancellationError()
    }
}
