import Foundation
import Observation

/// Background queue of tag writes, one file at a time (the files sit on a slow network share).
/// Edits queued for a file that hasn't been written yet are merged into one write.
///
/// A write that fails for a reason that can pass (the share dropped, another app had the file)
/// isn't given up on: it stays saved and waits, and is tried again when a volume mounts, every few
/// minutes, at the next launch, or on Try Now. One that can't work (a format that can't be tagged)
/// is reported and its saved row goes, though Try Again still has its values for this session.
@MainActor
@Observable
final class TagWriteQueue {
    struct Failure: Identifiable {
        let id = UUID()
        let path: String
        let message: String
        /// What couldn't be written, for Try Again.
        let values: TagValues
    }

    typealias Writer = @Sendable (TagValues, URL) async throws -> TagFileWriter.Outcome

    /// Progress through the current batch (reset when a new batch starts after the queue went idle).
    private(set) var done = 0
    private(set) var total = 0
    private(set) var written = 0
    private(set) var currentPath: String?
    /// The next file is in use (playing) and waits until it isn't.
    private(set) var waitingForPath: String?
    private(set) var failures: [Failure] = []
    /// Writes waiting for a failure to pass. They stay saved, and each path is either here or
    /// pending, never both.
    private(set) var waiting: [String: TagValues] = [:]

    var isRunning: Bool { worker != nil }

    /// Files that shouldn't be replaced right now (the track that's playing).
    @ObservationIgnored var isInUse: (String) -> Bool = { _ in false }
    /// Called after a file was rewritten, with its new size.
    @ObservationIgnored var didWrite: (String, Int64) -> Void = { _, _ in }
    /// Called with the values still to be written to a path whenever they change (nil once written
    /// or given up on), so the queue can be saved and picked up again after a quit. For a file
    /// being written, they include the values being written until that write is done.
    @ObservationIgnored var persist: (String, TagValues?) -> Void = { _, _ in }

    @ObservationIgnored private var pending: [String: TagValues] = [:]
    @ObservationIgnored private var order: [String] = []
    /// The write under way.
    @ObservationIgnored private var inFlight: (path: String, values: TagValues)?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let write: Writer
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let waitingRetryDelay: Duration
    @ObservationIgnored private var waitingRetry: Task<Void, Never>?
    /// Tries so far at files that keep changing under the write, so one that never settles ends
    /// up reported.
    @ObservationIgnored private var changedTries: [String: Int] = [:]
    private static let maxChangedTries = 3

    /// `retryDelay`: how often to look whether a file in use is free yet. `waitingRetryDelay`: how
    /// often to try the writes that are waiting (a share can come back without a mount).
    init(retryDelay: Duration = .seconds(3), waitingRetryDelay: Duration = .seconds(300),
         write: @escaping Writer = { try await TagFileWriter.write($0, to: $1) }) {
        self.write = write
        self.retryDelay = retryDelay
        self.waitingRetryDelay = waitingRetryDelay
    }

    func enqueue(_ values: TagValues, path: String) {
        guard add(values, path: path) else { return }
        if let inFlight, inFlight.path == path {
            // If susurrus quits before that write is done, both edits still have to be written.
            persist(path, inFlight.values.merged(with: pending[path]!))
        } else {
            persist(path, pending[path])
        }
    }

    /// Queues writes an earlier run saved through `persist`, without saving them again. For
    /// launch, before anything else is queued.
    func resume(_ saved: [(path: String, values: TagValues)]) {
        for (path, values) in saved { add(values, path: path) }
    }

    /// Adds the values to what's pending for `path` and starts the worker; false if there's
    /// nothing to write.
    @discardableResult
    private func add(_ values: TagValues, path: String) -> Bool {
        guard !values.isEmpty else { return false }
        // What this file still owes goes in with the new values, underneath them.
        var values = values
        if let index = failures.firstIndex(where: { $0.path == path }) {
            values = failures.remove(at: index).values.merged(with: values)
        }
        if let older = waiting.removeValue(forKey: path) { values = older.merged(with: values) }
        if worker == nil {
            done = 0
            total = 0
            written = 0
        }
        if let existing = pending[path] {
            pending[path] = existing.merged(with: values)
        } else {
            pending[path] = values
            order.append(path)
            total += 1
        }
        if worker == nil {
            worker = Task { [weak self] in await self?.run() }
        }
        return true
    }

    func clearFailures() {
        failures.removeAll()
    }

    /// Queues the failed writes again, in the order they failed.
    func retryFailures() {
        let failed = failures
        failures = []
        for failure in failed { enqueue(failure.values, path: failure.path) }
    }

    /// Tries the waiting writes now. A share that's still gone costs one failed try.
    func retryWaiting() {
        waitingRetry?.cancel()
        waitingRetry = nil
        let writes = waiting
        waiting = [:]
        for (path, values) in writes.sorted(by: { $0.key < $1.key }) { add(values, path: path) }
    }

    /// Stops waiting: the edits stay in the library, but these files won't get them.
    func forgetWaiting() {
        waitingRetry?.cancel()
        waitingRetry = nil
        let paths = waiting.keys
        waiting = [:]
        for path in paths {
            changedTries[path] = nil
            persist(path, nil)
        }
    }

    /// Whether a write to `path` is waiting or under way, so its file can't be moved yet.
    func isWriting(_ path: String) -> Bool {
        pending[path] != nil || inFlight?.path == path || waiting[path] != nil
    }

    /// Waits until everything queued so far has been written (for tests).
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func run() async {
        while !order.isEmpty {
            guard let path = order.first(where: { !isInUse($0) }) else {
                waitingForPath = order.first
                try? await Task.sleep(for: retryDelay)
                continue
            }
            waitingForPath = nil
            order.removeAll { $0 == path }
            guard let values = pending.removeValue(forKey: path) else { continue }
            currentPath = path
            inFlight = (path, values)

            let write = write
            // Deciding what a failure means can touch the share, so it's done off the main actor too.
            let result: Result<TagFileWriter.Outcome, QueuedWriteFailure> = await Task.detached(priority: .utility) {
                do {
                    return .success(try await write(values, URL(fileURLWithPath: path)))
                } catch {
                    return .failure(QueuedWriteFailure(error: error, retry: TagFileWriter.retry(after: error, path: path)))
                }
            }.value
            inFlight = nil
            var stillOwed = false
            switch result {
            case .success(.written(let size)):
                written += 1
                changedTries[path] = nil
                didWrite(path, size)
            case .success(.unchanged):
                changedTries[path] = nil
            case .failure(let failure):
                stillOwed = fail(values, path: path, failure)
            }
            // Written, or given up on: done with. Edits that arrived meanwhile are still pending
            // and stay saved, and so does a write that waits.
            persist(path, pending[path] ?? waiting[path])
            if stillOwed { total -= 1 } else { done += 1 }
        }
        currentPath = nil
        waitingForPath = nil
        worker = nil
        scheduleWaitingRetry()
    }

    /// Files a write that failed: true when it now waits rather than being finished with.
    private func fail(_ values: TagValues, path: String, _ failure: QueuedWriteFailure) -> Bool {
        // Edits that arrived meanwhile go in with these on the next try, which is coming anyway.
        if let newer = pending[path] {
            pending[path] = values.merged(with: newer)
            return false
        }
        switch failure.retry {
        case .whenReachable:
            waiting[path] = values
            waitForVolume(of: path, because: failure.error)
            return true
        case .soon:
            let tries = changedTries[path, default: 0] + 1
            if tries < Self.maxChangedTries {
                changedTries[path] = tries
                waiting[path] = values
                return true
            }
        case .never:
            break
        }
        changedTries[path] = nil
        failures.append(Failure(path: path, message: failure.error.localizedDescription, values: values))
        EventLog.shared.log("Tag write: \(failure.error.localizedDescription) — \(path)")
        if failures.count > 200 { failures.removeFirst(failures.count - 200) }
        return false
    }

    /// The share `path` is on has gone: everything else queued for it waits too, without a try
    /// each (on a share that's hanging, every one could take a long timeout).
    private func waitForVolume(of path: String, because error: Error) {
        let volume = MissingFiles.volumeRoot(of: path)
        EventLog.shared.log("Tag writes wait for \(volume ?? path): \(error.localizedDescription)")
        guard let volume else { return }
        let others = order.filter { MissingFiles.volumeRoot(of: $0) == volume }
        for other in others {
            if let values = pending.removeValue(forKey: other) {
                waiting[other] = values
                total -= 1
            }
        }
        order.removeAll { MissingFiles.volumeRoot(of: $0) == volume }
    }

    private func scheduleWaitingRetry() {
        guard !waiting.isEmpty, waitingRetry == nil else { return }
        waitingRetry = Task { [weak self, waitingRetryDelay] in
            try? await Task.sleep(for: waitingRetryDelay)
            guard let self, !Task.isCancelled else { return }
            self.waitingRetry = nil
            self.retryWaiting()
        }
    }
}

/// A failed write and what to do about it, on its way back to the main actor.
private struct QueuedWriteFailure: Error {
    let error: Error
    let retry: TagFileWriter.Retry
}
