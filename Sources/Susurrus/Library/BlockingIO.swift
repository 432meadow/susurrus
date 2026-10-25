import Foundation
import os

/// Runs blocking file system work (reading from the network share, copying, opening audio files)
/// on dispatch threads of its own. Swift's shared thread pool has one thread per core and every
/// actor and task in the app runs on it, so a hung share must never hold one of those.
struct BlockingIO: Sendable {
    /// Finding, copying and opening tracks for the player and the mixer.
    static let playback = BlockingIO(label: "playback", qos: .userInitiated)
    /// Background analysis: BPM, key, and the mixer's waveforms and beat grids.
    static let analysis = BlockingIO(label: "analysis", qos: .utility)
    /// The library's own: scans, missing-file checks, organizing downloads, imports and exports.
    static let library = BlockingIO(label: "library", qos: .utility)

    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS) {
        queue = DispatchQueue(label: "susurrus.io.\(label)", qos: qos, attributes: .concurrent)
    }

    /// Runs `work` on one of this lane's threads and waits for it without holding a pool thread.
    func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Like `run`, for long work that can stop early: once the waiting task is cancelled,
    /// `isCancelled` returns true, for the work to check between steps.
    func run<T>(cancellable work: @escaping @Sendable (_ isCancelled: @escaping @Sendable () -> Bool) -> T) async -> T {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await run { work { cancelled.withLock { $0 } } }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Starts `work` without waiting for it.
    func perform(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }
}
