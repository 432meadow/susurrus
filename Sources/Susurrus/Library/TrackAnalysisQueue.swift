import Foundation
import Observation

/// Background analysis (BPM or key detection), a few files at a time (each read is a short
/// excerpt, but the files sit on a slow network share). The reads run on `BlockingIO` threads, so
/// a hung share can't stall the rest of the app's tasks. Results are handed back in small batches
/// so the library and table update as it goes without re-sorting 50k rows per track.
@MainActor
@Observable
final class TrackAnalysisQueue<Value: Sendable> {
    typealias Detector = @Sendable (URL) throws -> Value?

    /// Progress through the current batch (reset when a new batch starts after the queue went idle).
    private(set) var done = 0
    private(set) var total = 0
    /// How many files gave a result (the rest were missing, undecodable, or had no clear beat or key).
    private(set) var detected = 0

    var isRunning: Bool { worker != nil }

    /// Called with (track ID, result) pairs as they're found.
    @ObservationIgnored var didDetect: ([(Int64, Value)]) -> Void = { _ in }

    @ObservationIgnored private var pending: [(id: Int64, path: String)] = []
    @ObservationIgnored private var queued = Set<Int64>()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let detect: Detector
    @ObservationIgnored private let width: Int

    init(width: Int = 3, detect: @escaping Detector) {
        self.width = width
        self.detect = detect
    }

    func enqueue(_ tracks: [(id: Int64, path: String)]) {
        if worker == nil {
            done = 0
            total = 0
            detected = 0
        }
        for track in tracks where queued.insert(track.id).inserted {
            pending.append(track)
            total += 1
        }
        if worker == nil, !pending.isEmpty {
            worker = Task { [weak self] in await self?.run() }
        }
    }

    /// Drops everything not yet started; files already being read finish and are saved.
    func cancel() {
        total -= pending.count
        queued.subtract(pending.map(\.id))
        pending.removeAll()
    }

    /// Waits until everything queued so far has been analyzed (for tests).
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func run() async {
        var results: [(Int64, Value)] = []
        var lastFlush = ContinuousClock.now
        func flush() {
            guard !results.isEmpty else { return }
            didDetect(results)
            results.removeAll()
            lastFlush = .now
        }

        await withTaskGroup(of: (Int64, Value?).self) { group in
            for _ in 0..<width where !startNext(in: &group) { break }
            for await (id, value) in group {
                done += 1
                queued.remove(id)
                if let value {
                    detected += 1
                    results.append((id, value))
                }
                if results.count >= 50 || ContinuousClock.now - lastFlush > .seconds(1) { flush() }
                _ = startNext(in: &group)
            }
        }
        flush()
        worker = nil
    }

    private func startNext(in group: inout TaskGroup<(Int64, Value?)>) -> Bool {
        guard !pending.isEmpty else { return false }
        let track = pending.removeFirst()
        let detect = detect
        group.addTask(priority: .utility) {
            let url = URL(fileURLWithPath: track.path)
            return (track.id, await BlockingIO.analysis.run { try? detect(url) })
        }
        return true
    }
}

extension TrackAnalysisQueue where Value == Int {
    /// Tempos, rounded to whole BPM as tags store them.
    static func bpm() -> TrackAnalysisQueue<Int> {
        TrackAnalysisQueue(width: 3) { url in
            try BPMDetector.detect(fileAt: url).flatMap { $0.isFinite && $0 > 0 ? Int($0.rounded()) : nil }
        }
    }
}

extension TrackAnalysisQueue where Value == MusicalKey {
    static func key() -> TrackAnalysisQueue<MusicalKey> {
        TrackAnalysisQueue(width: 3) { try KeyDetector.detect(fileAt: $0) }
    }
}
