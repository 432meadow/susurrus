import AVFoundation
import ObjCSupport
import Observation

/// Queue-based player on AVAudioEngine.
///
/// - Files are prepared off the main thread by `PlaybackFileCache` (copied locally when they live
///   on a network share), so the UI never waits on disk or network I/O.
/// - Gapless: the next track is prepared early and chained onto the same player node
///   shortly before the current one ends, so the audio runs back-to-back. It's chained late on
///   purpose: once scheduled, a segment can't be withdrawn from the node, so queue edits before
///   that point cost nothing. If the queue changes after chaining, the schedule is rebuilt.
/// - The engine only runs while there's something to hear. A running output keeps the Mac (and
///   Bluetooth or AirPlay speakers) awake, so a paused player lets it go after `engineIdleDelay`,
///   and a queue restored at launch doesn't start it at all.
/// - Graph: player node → 10-band EQ → main mixer → output device.
@MainActor
@Observable
final class Player {
    enum RepeatMode: String, CaseIterable, Identifiable {
        case off, all, one
        var id: Self { self }
    }

    struct SavedState: Codable {
        var trackIDs: [Int64]
        var index: Int
        var position: Double
    }

    /// What the player is doing with the current queue entry. Views see it as `isPlaying`,
    /// `isLoading` and `isWaitingForShare`.
    private enum State {
        /// No queue entry.
        case idle
        /// Finding and opening the entry's file, to start at `position`: paused if Pause was
        /// pressed meanwhile.
        case loading(position: TimeInterval, paused: Bool, waitingForShare: Bool)
        /// Scheduled from `position` and started, but its first audio hasn't come back from the
        /// share yet.
        case buffering(position: TimeInterval, waitingForShare: Bool)
        case playing
        /// Paused at `position`. A `resumable` node just carries on; otherwise Play schedules
        /// afresh from `position`, opening the file first if it isn't open (a queue restored at
        /// launch, or one waiting for the share to come back).
        case paused(position: TimeInterval, resumable: Bool)
    }

    private(set) var queue: [Track] = []
    private(set) var index: Int?
    private var state = State.idle {
        // Each change books the listening time under the state that's ending, and a pause starts
        // the countdown to letting the output device go.
        willSet { accumulateListen() }
        didSet { releaseEngineWhenIdle() }
    }
    private(set) var shuffle = false
    /// How many tracks right after the current one were added with Play Next / Add to Queue.
    private(set) var queuedAheadCount = 0
    private(set) var outputDeviceUID: String?
    var repeatMode: RepeatMode = .off {
        didSet {
            UserDefaults.standard.set(repeatMode.rawValue, forKey: Keys.repeatMode)
            queueDidChange()
        }
    }
    var errorMessage: String? {
        didSet { if let errorMessage, errorMessage != oldValue { EventLog.shared.log("Player: \(errorMessage)") } }
    }
    var volume: Float = 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = volume
            UserDefaults.standard.set(volume, forKey: Keys.volume)
        }
    }

    let equalizer = Equalizer()
    let outputs = OutputDevices()

    /// Playing, or about to: also true while loading or buffering a track that's going to play.
    var isPlaying: Bool {
        switch state {
        case .loading(_, let paused, _): !paused
        case .buffering, .playing: true
        case .idle, .paused: false
        }
    }

    /// True while the current track's file is being fetched/opened, or its first audio is on its way.
    var isLoading: Bool {
        switch state {
        case .loading, .buffering: true
        case .idle, .playing, .paused: false
        }
    }

    /// Loading has taken long enough that the network share is probably slow or unreachable.
    var isWaitingForShare: Bool {
        switch state {
        case .loading(_, _, let waiting), .buffering(_, let waiting): waiting
        case .idle, .playing, .paused: false
        }
    }

    var currentTrack: Track? {
        guard let index, queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    /// The tracks that will play after the current one.
    var upNext: [Track] {
        guard let index, index + 1 < queue.count else { return [] }
        return Array(queue[(index + 1)...])
    }

    var upNextCount: Int {
        guard let index else { return 0 }
        return max(0, queue.count - index - 1)
    }

    /// The first `limit` upcoming tracks, for display. (Playing All Tracks queues ~50k.)
    func upNext(limit: Int) -> ArraySlice<Track> {
        guard let index, index + 1 < queue.count else { return [] }
        return queue[(index + 1)..<min(queue.count, index + 1 + limit)]
    }

    /// Resolves a track to its file (stored path first, then bookmark). Called off the main thread.
    @ObservationIgnored var locate: @Sendable (TrackRef) -> URL? = { URL(fileURLWithPath: $0.path) }
    /// Called when a track's file couldn't be opened (it's skipped).
    @ObservationIgnored var onUnplayable: ((Track) -> Void)?
    /// Called once per listen, once enough has been heard: half the track, or 4 minutes.
    @ObservationIgnored var onTrackPlayed: ((Track) -> Void)?
    /// Called when playback moves on from a queue entry that played for at least a second, with
    /// how long it actually played and how it ended.
    @ObservationIgnored var onListenEnded: ((Track, ListenRecord) -> Void)?
    /// Called whenever playback starts or resumes, so the mixer's decks can pause.
    @ObservationIgnored var onStartedPlaying: (() -> Void)?
    /// Called when the user picks another output device (nil: the system output).
    @ObservationIgnored var onOutputDeviceChanged: ((String?) -> Void)?
    /// How long the engine keeps running while paused before it lets the output device go.
    @ObservationIgnored var engineIdleDelay: Duration = .seconds(20)

    /// Whether the audio engine, and with it the output device, is running.
    var isEngineRunning: Bool { engine.isRunning }

    private enum Keys {
        static let volume = "player.volume"
        static let repeatMode = "player.repeat"
        static let shuffle = "player.shuffle"
        static let outputDevice = "player.outputDeviceUID"
    }

    private struct Prepared {
        let index: Int
        let trackID: Int64
        let opened: PlaybackFile
    }

    /// Where a run of files that wouldn't open began.
    private struct FailureRun {
        let entryID: Int
        let position: TimeInterval
        let queuedAheadCount: Int
        var count = 0
    }

    /// Seconds before the end of a track at which the next one is chained onto the node.
    private static let chainLeadTime: TimeInterval = 12
    /// A track left this close to its end (or within its last 10%, if shorter) counts as
    /// finished, not skipped.
    private static let finishedWithin: TimeInterval = 10
    /// Previous goes back to the start of the current track once it's this far in.
    private static let previousRestartsAfter: TimeInterval = 3
    /// How long loading may take before the bar says the share is slow.
    private static let shareWaitThreshold: Duration = .seconds(8)
    /// The probe segment scheduled ahead of a streamed start (see `begin`).
    private static let probeSeconds = 0.25
    /// While the current track streams from the share, the next one is fetched once the stream
    /// has had this long to settle, or is this close to its end.
    private static let prefetchSettleTime: TimeInterval = 20
    private static let prefetchLeadTime: TimeInterval = 60
    /// Files in a row that won't open before the share is taken to be gone.
    private static let maxConsecutiveFailures = 3

    @ObservationIgnored private let files: PlaybackFileCache
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private var connectedFormat: AVAudioFormat?
    /// Bumped whenever the node's schedule is torn down, so stale callbacks and loads are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var scheduleCounter = 0
    @ObservationIgnored private var currentScheduleID: Int?
    @ObservationIgnored private var currentFile: PlaybackFile?
    /// The following track, opened and ready (not necessarily scheduled yet).
    @ObservationIgnored private var nextFile: Prepared?
    /// Set once `nextFile` has been scheduled on the node behind the current track.
    @ObservationIgnored private var chainedScheduleID: Int?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var prefetching: (trackID: Int64, task: Task<Void, Never>)?
    @ObservationIgnored private var failedPrefetchTrackID: Int64?
    /// What the file cache was last told the player needs.
    @ObservationIgnored private var keptTrackIDs: Set<Int64> = []
    /// Node sample time at which the current track's audio begins (node time keeps counting across gapless chains).
    @ObservationIgnored private var currentStartSampleTime: AVAudioFramePosition = 0
    /// Frame within the current file where playback was (re)started, after a seek.
    @ObservationIgnored private var currentStartFrame: AVAudioFramePosition = 0
    /// The playhead at the last tick while the engine ran. When the output device changes, the
    /// engine has stopped (and its clock with it) before we hear about it.
    @ObservationIgnored private var lastPlayheadTime: TimeInterval = 0
    /// Files that wouldn't open, in a row. After `maxConsecutiveFailures` the share is probably
    /// gone, so playback goes back to where the run began and waits there, paused.
    @ObservationIgnored private var failureRun: FailureRun?
    /// The current queue entry's listen, accumulating playing time.
    @ObservationIgnored private var listen: ListenSession?
    /// Tells queue entries apart (a track can be queued twice), in step with `queue`, so the
    /// unshuffled order can follow edits made while shuffled.
    @ObservationIgnored private var entryIDs: [Int] = []
    @ObservationIgnored private var lastEntryID = 0
    /// The entries in their unshuffled order, so turning shuffle off restores it.
    @ObservationIgnored private var unshuffledOrder: [Int]?
    @ObservationIgnored private var engineRelease: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var nowPlaying: NowPlayingCenter?

    /// `files`: the shared cache when nil (tests pass their own).
    init(files: PlaybackFileCache? = nil) {
        self.files = files ?? .shared
        let defaults = UserDefaults.standard
        volume = defaults.object(forKey: Keys.volume) as? Float ?? 0.8
        repeatMode = RepeatMode(rawValue: defaults.string(forKey: Keys.repeatMode) ?? "") ?? .off
        shuffle = defaults.bool(forKey: Keys.shuffle)
        outputDeviceUID = defaults.string(forKey: Keys.outputDevice)

        engine.attach(node)
        engine.attach(equalizer.unit)
        engine.mainMixerNode.outputVolume = volume
        if let uid = outputDeviceUID, let device = OutputDevices.deviceID(forUID: uid) {
            engine.setOutputDevice(device)
        }

        // Rebuild the schedule at the same position on the new device.
        engine.onConfigurationChange { [weak self] in self?.outputConfigurationChanged() }

        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
        nowPlaying = NowPlayingCenter(player: self)
    }

    // MARK: Transport

    func play(_ tracks: [Track], startingAt start: Int) {
        guard tracks.indices.contains(start) else { return }
        failureRun = nil
        queuedAheadCount = 0
        queue = tracks
        entryIDs = newEntryIDs(tracks.count)
        if shuffle {
            unshuffledOrder = entryIDs
            var rest = Array(tracks.indices)
            rest.remove(at: start)
            rearrange([start] + rest.shuffled())
            startTrack(at: 0, newQueue: true)
        } else {
            unshuffledOrder = nil
            startTrack(at: start, newQueue: true)
        }
    }

    func togglePlayPause() {
        guard let index else { return }
        switch state {
        case .idle:
            return
        case .loading(let position, let paused, let waiting):
            // Takes effect once the file is open.
            state = .loading(position: position, paused: !paused, waitingForShare: waiting)
        case .buffering(let position, _):
            // Nothing has played from here yet, so Play starts over from the same spot.
            resetNode()
            state = .paused(position: position, resumable: false)
        case .playing:
            let position = currentTime
            node.pause()
            state = .paused(position: position, resumable: true)
        case .paused(let position, let resumable):
            if resumable {
                resume(at: position)
            } else if currentFile != nil {
                restart(from: position, paused: false)
            } else {
                failureRun = nil
                startTrack(at: index, fromSeconds: position)
            }
        }
        nowPlaying?.update()
    }

    func pause() {
        if isPlaying { togglePlayPause() }
    }

    func next() {
        guard let index else { return }
        failureRun = nil
        if let target = followingIndex(after: index, automatic: false) {
            startTrack(at: target, reuse: preparedFile(for: target))
        } else {
            stop()
        }
    }

    /// Restarts the current track once it's a few seconds in, like most players.
    func previous() {
        guard let index else { return }
        failureRun = nil
        if currentTime > Player.previousRestartsAfter {
            seek(to: 0)
        } else if index > 0 {
            startTrack(at: index - 1)
        } else if repeatMode != .off, queue.count > 1 {
            startTrack(at: queue.count - 1)
        } else {
            seek(to: 0)
        }
    }

    func stop() {
        endListen(.stopped)
        loadTask?.cancel()
        cancelPrefetch()
        resetNode()
        engine.stop()
        state = .idle
        index = nil
        currentFile = nil
        nextFile = nil
        failureRun = nil
        queuedAheadCount = 0
        keepFiles()
        nowPlaying?.update()
    }

    func seek(to seconds: TimeInterval) {
        guard let index else { return }
        let end = duration - 0.05
        let target = max(0, end > 0 ? min(seconds, end) : seconds)
        switch state {
        case .idle:
            return
        case .loading(_, let paused, let waiting):
            state = .loading(position: target, paused: paused, waitingForShare: waiting)
            nowPlaying?.update()
        case .paused where currentFile == nil:
            // Restored at launch, or waiting for the share: open it now, still paused.
            failureRun = nil
            startTrack(at: index, fromSeconds: target, startPaused: true)
        case .buffering, .playing, .paused:
            restart(from: target, paused: !isPlaying)
        }
    }

    // MARK: Modes

    func setShuffle(_ on: Bool) {
        guard on != shuffle else { return }
        shuffle = on
        UserDefaults.standard.set(on, forKey: Keys.shuffle)
        guard !queue.isEmpty else { return }

        if on {
            unshuffledOrder = entryIDs
            // The current track and whatever was queued to follow it stay first; the rest is shuffled.
            let kept = index.map { $0..<min($0 + 1 + queuedAheadCount, queue.count) } ?? 0..<0
            let rest = queue.indices.filter { !kept.contains($0) }
            rearrange(Array(kept) + rest.shuffled())
            if index != nil { index = 0 }
        } else if let order = unshuffledOrder {
            let currentEntry = index.map { entryIDs[$0] }
            let queued = index.map { Set(entryIDs[($0 + 1)...].prefix(queuedAheadCount)) } ?? []
            let positions = Dictionary(uniqueKeysWithValues: entryIDs.enumerated().map { ($1, $0) })
            rearrange(order.compactMap { positions[$0] })
            if let currentEntry, let restored = entryIDs.firstIndex(of: currentEntry) {
                index = restored
                queuedAheadCount = entryIDs[(restored + 1)...].prefix { queued.contains($0) }.count
            }
            unshuffledOrder = nil
        }
        queueDidChange()
    }

    func cycleRepeatMode() {
        repeatMode = switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    // MARK: Up Next

    /// Plays `tracks` right after the current track.
    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index else {
            play(tracks, startingAt: 0)
            return
        }
        insertEntries(tracks, at: index + 1)
        queuedAheadCount += tracks.count
        queueDidChange()
    }

    /// Adds `tracks` after anything already queued with Play Next / Add to Queue.
    func addToQueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard let index else {
            play(tracks, startingAt: 0)
            return
        }
        insertEntries(tracks, at: min(index + 1 + queuedAheadCount, queue.count))
        queuedAheadCount += tracks.count
        queueDidChange()
    }

    /// Offsets are positions in `upNext`.
    func removeFromUpNext(at offsets: IndexSet) {
        guard let index else { return }
        let removedQueued = offsets.filter { $0 < queuedAheadCount }.count
        removeEntries(at: IndexSet(offsets.map { $0 + index + 1 }))
        queuedAheadCount -= removedQueued
        queueDidChange()
    }

    func moveInUpNext(from offsets: IndexSet, to destination: Int) {
        guard let index else { return }
        var upcoming = Array((index + 1)..<queue.count)
        upcoming.move(fromOffsets: offsets, toOffset: destination)
        rearrange(Array(0...index) + upcoming)
        queueDidChange()
    }

    func clearUpNext() {
        guard let index, index + 1 < queue.count else { return }
        removeEntries(at: IndexSet(integersIn: (index + 1)..<queue.count))
        queuedAheadCount = 0
        queueDidChange()
    }

    /// Starts the track at `offset` in `upNext`, dropping everything before it.
    func jump(toUpNext offset: Int) {
        guard let index, queue.indices.contains(index + 1 + offset) else { return }
        failureRun = nil
        let target = index + 1 + offset
        startTrack(at: target, reuse: preparedFile(for: target))
    }

    private func newEntryIDs(_ count: Int) -> [Int] {
        defer { lastEntryID += count }
        return (0..<count).map { lastEntryID + 1 + $0 }
    }

    /// Puts the queue in `order` (positions in it as it is).
    private func rearrange(_ order: [Int]) {
        let tracks = queue, ids = entryIDs
        queue = order.map { tracks[$0] }
        entryIDs = order.map { ids[$0] }
    }

    /// Inserts `tracks` as new entries at `position`. While shuffled they also go into the
    /// unshuffled order, right after the entry they follow here.
    private func insertEntries(_ tracks: [Track], at position: Int) {
        let ids = newEntryIDs(tracks.count)
        if let anchor = unshuffledOrder?.firstIndex(of: entryIDs[position - 1]) {
            unshuffledOrder?.insert(contentsOf: ids, at: anchor + 1)
        }
        queue.insert(contentsOf: tracks, at: position)
        entryIDs.insert(contentsOf: ids, at: position)
    }

    /// Removes entries, from the unshuffled order too.
    private func removeEntries(at positions: IndexSet) {
        if unshuffledOrder != nil {
            let removed = Set(positions.map { entryIDs[$0] })
            unshuffledOrder?.removeAll { removed.contains($0) }
        }
        queue.remove(atOffsets: positions)
        entryIDs.remove(atOffsets: positions)
    }

    // MARK: Saved state

    var savedState: SavedState? {
        guard let index else { return nil }
        return SavedState(trackIDs: queue.map(\.id), index: index, position: currentTime)
    }

    /// Restores a queue paused at `position`, as it was when the app quit. Nothing is opened until
    /// Play or a seek: the share may not even be mounted yet.
    func restore(_ tracks: [Track], index: Int, position: Double) {
        guard tracks.indices.contains(index) else { return }
        stop()
        queue = tracks
        entryIDs = newEntryIDs(tracks.count)
        unshuffledOrder = nil
        self.index = index
        state = .paused(position: max(0, position), resumable: false)
        nowPlaying?.update()
    }

    // MARK: Output device

    /// nil follows the system default output.
    func setOutputDevice(_ uid: String?) {
        outputDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: Keys.outputDevice)
        onOutputDeviceChanged?(uid)
        let device = uid.flatMap(OutputDevices.deviceID(forUID:)) ?? OutputDevices.defaultOutputDeviceID()
        guard let device else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        engine.stop()
        engine.setOutputDevice(device)
        connectedFormat = nil
        restart(from: position, paused: !wasPlaying)
    }

    private func outputConfigurationChanged() {
        connectedFormat = nil  // force a reconnect to the new output
        resync()
    }

    // MARK: Time

    var duration: TimeInterval {
        guard let file = currentFile?.file else { return currentTrack?.length ?? 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: TimeInterval {
        switch state {
        case .idle: 0
        case .loading(let position, _, _), .buffering(let position, _), .paused(let position, _): position
        case .playing: playheadTime ?? lastPlayheadTime
        }
    }

    /// The playhead by the node's clock; nil while the engine isn't running (its clock is gone).
    private var playheadTime: TimeInterval? {
        guard engine.isRunning, let file = currentFile?.file, let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return nil }
        // The clock reads a little before the start until the node's first render after play.
        let frames = currentStartFrame + max(0, playerTime.sampleTime - currentStartSampleTime)
        return min(Double(frames) / file.processingFormat.sampleRate, duration)
    }

    /// Audio is coming out: not paused, loading or waiting for the share.
    private var isAudible: Bool {
        if case .playing = state { return true }
        return false
    }

    // MARK: Scheduling

    /// What plays after `index`. `automatic` is a track ending on its own (repeat-one replays it);
    /// otherwise the user pressed Next.
    private func followingIndex(after index: Int, automatic: Bool) -> Int? {
        if automatic, repeatMode == .one { return index }
        if index + 1 < queue.count { return index + 1 }
        if repeatMode != .off, !queue.isEmpty { return 0 }
        return nil
    }

    private func preparedFile(for target: Int) -> PlaybackFile? {
        guard let prepared = nextFile, prepared.index == target,
              queue.indices.contains(target), queue[target].id == prepared.trackID else { return nil }
        return prepared.opened
    }

    private func startTrack(at newIndex: Int, fromSeconds: TimeInterval = 0, reuse: PlaybackFile? = nil,
                            startPaused: Bool = false, newQueue: Bool = false) {
        if newIndex != index || newQueue {
            // Where the outgoing track got to says whether it was finished or skipped.
            let endedAt = currentTime
            let finished = duration - endedAt <= min(Player.finishedWithin, duration * 0.1)
            endListen(finished ? .finished : .skipped, at: endedAt)
        }
        loadTask?.cancel()
        resetNode()
        if newQueue {
            nextFile = nil
            cancelPrefetch()
            index = newIndex
        } else {
            if let reuse, nextFile?.opened.file === reuse.file { nextFile = nil }
            moveIndex(to: newIndex)
        }
        if listen == nil { listen = ListenSession(queue[newIndex]) }

        if let reuse {
            begin(reuse, at: newIndex, fromSeconds: fromSeconds, startPaused: startPaused)
        } else {
            currentFile = nil
            state = .loading(position: fromSeconds, paused: startPaused, waitingForShare: false)
            keepFiles()
            nowPlaying?.update()
            load(queue[newIndex], at: newIndex)
        }
    }

    /// Moves to another queue entry. Moving ahead uses up that many of the tracks added with Play
    /// Next / Add to Queue (they're the ones right after the current track).
    private func moveIndex(to newIndex: Int) {
        if let index, newIndex > index { queuedAheadCount = max(0, queuedAheadCount - (newIndex - index)) }
        index = newIndex
    }

    /// Opens the entry's file off the main thread, then starts it as `state` says by then: a seek
    /// or Pause may have come in meanwhile.
    private func load(_ track: Track, at newIndex: Int) {
        let loadGeneration = generation
        let ref = TrackRef(id: track.id, path: track.path)
        loadTask = Task {
            let opened = await files.openFile(for: ref, immediate: true, locate: locate)
            // The user may have skipped or stopped while this loaded.
            guard loadGeneration == generation, case .loading(let position, let paused, _) = state else { return }
            guard let opened else {
                errorMessage = "Can't open “\(track.title)” — \(track.path)"
                onUnplayable?(track)
                loadFailed(at: newIndex, position: position, paused: paused)
                return
            }
            begin(opened, at: newIndex, fromSeconds: position, startPaused: paused)
        }
        flagSlowShare(after: loadGeneration)
    }

    /// Shows "Waiting for the network share…" if this load or probe is still going after `shareWaitThreshold`.
    private func flagSlowShare(after startGeneration: Int) {
        Task {
            try? await Task.sleep(for: Player.shareWaitThreshold)
            guard startGeneration == generation else { return }
            switch state {
            case .loading(let position, let paused, false):
                state = .loading(position: position, paused: paused, waitingForShare: true)
            case .buffering(let position, false):
                state = .buffering(position: position, waitingForShare: true)
            default:
                break
            }
        }
    }

    /// Skips a file that won't open, carrying on playing or paused as it was going to. After a few
    /// in a row the share is probably gone (unmounted, or dropped mid-queue): playback goes back
    /// to where the failures began and waits there, paused, with the queue as it was.
    private func loadFailed(at failedIndex: Int, position: TimeInterval, paused: Bool) {
        var run = failureRun ?? FailureRun(entryID: entryIDs[failedIndex], position: position,
                                           queuedAheadCount: queuedAheadCount)
        run.count += 1
        failureRun = run
        if run.count < Player.maxConsecutiveFailures,
           let target = followingIndex(after: failedIndex, automatic: false), target != failedIndex {
            startTrack(at: target, startPaused: paused)
            return
        }
        failureRun = nil
        endListen(.skipped)
        currentFile = nil
        if let start = entryIDs.firstIndex(of: run.entryID) {
            index = start
            queuedAheadCount = min(run.queuedAheadCount, upNextCount)
            state = .paused(position: run.position, resumable: false)
        } else {
            state = .paused(position: 0, resumable: false)
        }
        keepFiles()
        nowPlaying?.update()
    }

    /// Starts `opened` at `fromSeconds` on a fresh schedule, or with `startPaused` just cues it
    /// there: nothing is scheduled and the engine stays off until Play.
    private func begin(_ opened: PlaybackFile, at newIndex: Int, fromSeconds: TimeInterval, startPaused: Bool) {
        resetNode()
        let file = opened.file
        guard connect(for: file.processingFormat) else {
            errorMessage = "Unsupported audio format: \(file.processingFormat)"
            currentFile = nil
            loadFailed(at: newIndex, position: fromSeconds, paused: startPaused)
            return
        }
        failureRun = nil
        errorMessage = nil
        currentFile = opened

        let rate = file.processingFormat.sampleRate
        let startFrame = max(0, min(AVAudioFramePosition(fromSeconds * rate), file.length - 1))
        let startTime = Double(startFrame) / rate
        currentStartFrame = startFrame
        currentStartSampleTime = 0
        lastPlayheadTime = startTime
        defer {
            nowPlaying?.update()
            tick()
        }
        guard !startPaused else {
            state = .paused(position: startTime, resumable: false)
            return
        }

        // Over the network share the node can sit silent for a while after a seek, waiting for
        // data at the new offset. Schedule a short probe segment first: the moment its audio has
        // actually played, the spinner stops. Local files skip this (data is instant).
        let probeFrames = AVAudioFramePosition(rate * Player.probeSeconds)
        let probes = opened.isStreaming && file.length - startFrame > probeFrames * 2
        if probes {
            let probeGeneration = generation
            node.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(probeFrames),
                                 at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    self?.probeFinished(generation: probeGeneration, resumingAt: startFrame + probeFrames)
                }
            }
            currentScheduleID = schedule(file, from: startFrame + probeFrames,
                                         frames: AVAudioFrameCount(file.length - startFrame - probeFrames))
        } else {
            currentScheduleID = schedule(file, from: startFrame, frames: AVAudioFrameCount(file.length - startFrame))
        }

        guard startEngine() else {
            resetNode()
            state = .paused(position: startTime, resumable: false)
            return
        }
        node.play()
        if probes {
            state = .buffering(position: startTime, waitingForShare: false)
            flagSlowShare(after: generation)
        } else {
            state = .playing
        }
        onStartedPlaying?()
    }

    /// Carries on from a pause: the engine first (it may have been let go), then the node.
    private func resume(at position: TimeInterval) {
        guard startEngine() else { return }
        node.play()
        lastPlayheadTime = position
        state = .playing
        onStartedPlaying?()
    }

    /// Schedules the open file afresh from `position`: after a seek, an output change, a resume
    /// that can't just carry on, or a queue edit that invalidated what's chained.
    private func restart(from position: TimeInterval, paused: Bool) {
        guard let index, let file = currentFile else { return }
        begin(file, at: index, fromSeconds: position, startPaused: paused)
    }

    /// Restarts the current file at the current position with a fresh schedule.
    private func resync() {
        restart(from: currentTime, paused: !isPlaying)
    }

    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
            return false
        }
    }

    /// The probe's audio has played: the share has caught up, and the clock can run.
    private func probeFinished(generation probeGeneration: Int, resumingAt frame: AVAudioFramePosition) {
        // A segment also "finishes" when the engine stops underneath it.
        guard probeGeneration == generation, engine.isRunning, case .buffering = state else { return }
        // Re-anchor the clock: the probe has just finished, so the node is now at the frame right
        // after it, however long it sat waiting for data.
        if let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) {
            currentStartFrame = frame
            currentStartSampleTime = playerTime.sampleTime
        }
        state = .playing
        nowPlaying?.update()
    }

    /// Throws away everything scheduled on the node; completions still on their way are ignored.
    private func resetNode() {
        generation += 1
        node.stop()
        currentScheduleID = nil
        chainedScheduleID = nil
    }

    /// A paused player lets the output device go after `engineIdleDelay`; Play starts it again.
    private func releaseEngineWhenIdle() {
        engineRelease?.cancel()
        engineRelease = nil
        guard case .paused = state, engine.isRunning else { return }
        engineRelease = Task { [weak self, delay = engineIdleDelay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, case .paused(let position, _) = self.state else { return }
            self.resetNode()
            self.engine.stop()
            self.state = .paused(position: position, resumable: false)
        }
    }

    /// Returns false if the engine can't play this format (it raises an NSException, caught in ObjC).
    private func connect(for format: AVAudioFormat) -> Bool {
        guard !Player.sameLayout(connectedFormat, format) else { return true }
        engine.disconnectNodeOutput(node)
        engine.disconnectNodeOutput(equalizer.unit)
        // The mixer converts to the output device's rate.
        var error: NSError?
        guard MMConnectNodes(engine, node, equalizer.unit, format, &error),
              MMConnectNodes(engine, equalizer.unit, engine.mainMixerNode, format, &error) else {
            connectedFormat = nil
            return false
        }
        connectedFormat = format
        return true
    }

    private static func sameLayout(_ a: AVAudioFormat?, _ b: AVAudioFormat) -> Bool {
        guard let a else { return false }
        return a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    private func schedule(_ file: AVAudioFile, from frame: AVAudioFramePosition, frames: AVAudioFrameCount) -> Int {
        scheduleCounter += 1
        let scheduleID = scheduleCounter
        let scheduledGeneration = generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: frames, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.didFinish(scheduleID: scheduleID, generation: scheduledGeneration) }
        }
        return scheduleID
    }

    /// Runs twice a second: books listening time and counts plays, prefetches the next track, and
    /// chains it near the end.
    private func tick() {
        if isAudible, let time = playheadTime { lastPlayheadTime = time }
        countPlayIfDue()
        keepFiles()
        guard let index, let current = currentFile else { return }

        guard let upcoming = followingIndex(after: index, automatic: true) else {
            nextFile = nil
            cancelPrefetch()
            return
        }
        let upcomingTrack = queue[upcoming]
        if let prepared = nextFile, prepared.index != upcoming || prepared.trackID != upcomingTrack.id {
            // Keep the file if the same track just moved position; otherwise it's stale.
            nextFile = prepared.trackID == upcomingTrack.id
                ? Prepared(index: upcoming, trackID: prepared.trackID, opened: prepared.opened)
                : nil
        }
        if let prefetching, prefetching.trackID != upcomingTrack.id { cancelPrefetch() }
        // While the current track streams from the network share, don't compete with it for
        // bandwidth right away: fetch the next one once the stream has settled, or near the end.
        let streamIsSettled = !current.isStreaming || currentTime > Player.prefetchSettleTime
            || duration - currentTime < Player.prefetchLeadTime
        if nextFile == nil, prefetching == nil, streamIsSettled, failedPrefetchTrackID != upcomingTrack.id {
            prefetch(upcomingTrack)
        }

        if isPlaying, chainedScheduleID == nil, let prepared = nextFile,
           Player.sameLayout(connectedFormat, prepared.opened.file.processingFormat),
           duration - currentTime < Player.chainLeadTime {
            chainedScheduleID = schedule(prepared.opened.file, from: 0, frames: AVAudioFrameCount(prepared.opened.file.length))
        }
    }

    private func prefetch(_ track: Track) {
        let ref = TrackRef(id: track.id, path: track.path)
        let task = Task {
            let opened = await files.openFile(for: ref, locate: locate)
            guard !Task.isCancelled else { return }
            prefetching = nil
            guard let opened else {
                failedPrefetchTrackID = track.id
                return
            }
            guard let index, let upcoming = followingIndex(after: index, automatic: true),
                  queue[upcoming].id == track.id else { return }
            nextFile = Prepared(index: upcoming, trackID: track.id, opened: opened)
            tick()
        }
        prefetching = (track.id, task)
    }

    private func cancelPrefetch() {
        prefetching?.task.cancel()
        prefetching = nil
    }

    /// Tells the file cache what the player still needs (the current and next tracks), so copies
    /// of anything else can go.
    private func keepFiles() {
        var trackIDs = Set<Int64>()
        if let index {
            trackIDs.insert(queue[index].id)
            if let upcoming = followingIndex(after: index, automatic: true) { trackIDs.insert(queue[upcoming].id) }
        }
        guard trackIDs != keptTrackIDs else { return }
        keptTrackIDs = trackIDs
        files.keep(trackIDs, for: self)
    }

    private func didFinish(scheduleID: Int, generation finishedGeneration: Int) {
        // Segments also "finish" when the engine stops underneath them (an output device change):
        // that isn't the end of the track.
        guard finishedGeneration == generation, scheduleID == currentScheduleID, engine.isRunning,
              let index, let current = currentFile else { return }
        endListen(.finished, at: duration)

        if let chained = chainedScheduleID, let prepared = nextFile {
            // Already playing gaplessly; just advance our bookkeeping.
            currentStartSampleTime += current.file.length - currentStartFrame
            currentStartFrame = 0
            lastPlayheadTime = 0
            currentFile = prepared.opened
            currentScheduleID = chained
            chainedScheduleID = nil
            nextFile = nil
            moveIndex(to: prepared.index)
            listen = ListenSession(queue[prepared.index])
            nowPlaying?.update()
            tick()
            return
        }

        guard let target = followingIndex(after: index, automatic: true) else {
            stop()
            return
        }
        startTrack(at: target, reuse: preparedFile(for: target))
    }

    // MARK: Listens

    /// Books the time since the last call, if audio was coming out. Called before every state
    /// change, so the state now is the state since the last call.
    private func accumulateListen() {
        listen?.update(audible: isAudible)
    }

    /// Counts the current entry as played once enough of it has been heard.
    private func countPlayIfDue() {
        accumulateListen()
        if listen?.takePlay(duration: duration) == true, let track = listen?.track { onTrackPlayed?(track) }
    }

    private func endListen(_ outcome: ListenOutcome, at position: TimeInterval? = nil) {
        countPlayIfDue()
        guard let ended = listen else { return }
        listen = nil
        if let record = ended.record(outcome, at: position ?? currentTime) { onListenEnded?(ended.track, record) }
    }

    /// Ends the current listen as stopped, for when susurrus quits.
    func endCurrentListen() {
        endListen(.stopped)
    }

    /// Call after any change to the queue, shuffle or repeat.
    private func queueDidChange() {
        // A segment already chained onto the node can't be withdrawn. If it's no longer what should
        // play next, rebuild the schedule from the current position.
        if chainedScheduleID != nil, let index {
            let expected = followingIndex(after: index, automatic: true)
            if expected == nil || nextFile?.index != expected || nextFile?.trackID != expected.map({ queue[$0].id }) {
                resync()
            }
        }
        tick()
    }
}
