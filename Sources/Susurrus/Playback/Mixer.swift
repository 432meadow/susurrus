import AVFoundation
import ObjCSupport
import Observation

/// A two-deck mixer for blending tracks by hand, on its own AVAudioEngine so the queue player's
/// gapless schedule is left alone. Only one of the two plays at a time: starting a deck pauses
/// the queue player and vice versa (wired up in `AppModel`).
///
/// Graph per deck: player node → input mixer → varispeed (tempo) → 3-band EQ → channel mixer →
/// main mixer → output. The input mixer converts every file to one fixed deck format, so loading a
/// track only rewires the player node into it. The engine allows that while the other deck keeps
/// playing, because the change is upstream of a mixer. The channel mixer's volume is the channel
/// fader times the crossfader curve.
@MainActor
@Observable
final class Mixer {
    enum Side: String, CaseIterable, Identifiable {
        case a, b
        var id: Self { self }
        var name: String { rawValue.uppercased() }
        var other: Side { self == .a ? .b : .a }
    }

    let a = Deck(side: .a)
    let b = Deck(side: .b)
    var decks: [Deck] { [a, b] }

    func deck(_ side: Side) -> Deck { side == .a ? a : b }

    /// 0 is all deck A, 1 is all deck B.
    private(set) var crossfader: Double = 0.5
    private(set) var isAutoFading = false
    var errorMessage: String? {
        didSet { if let errorMessage, errorMessage != oldValue { EventLog.shared.log("Mixer: \(errorMessage)") } }
    }
    var masterVolume: Float = 0.8 {
        didSet {
            engine.mainMixerNode.outputVolume = masterVolume
            UserDefaults.standard.set(masterVolume, forKey: Keys.masterVolume)
        }
    }
    /// How long Auto Crossfade takes to glide from one side to the other.
    var autoFadeSeconds: Double = 8 {
        didSet { UserDefaults.standard.set(autoFadeSeconds, forKey: Keys.autoFadeSeconds) }
    }
    static let autoFadeChoices: [Double] = [4, 8, 16, 32]

    /// Resolves a track to its file. Called off the main thread.
    @ObservationIgnored var locate: @Sendable (TrackRef) -> URL? = { URL(fileURLWithPath: $0.path) }
    /// Called once per deck load, once half the track (or 4 minutes) has been heard.
    @ObservationIgnored var onTrackPlayed: ((Track) -> Void)?
    /// Called when a deck moves on from a track it played for at least a second.
    @ObservationIgnored var onListenEnded: ((Track, ListenRecord) -> Void)?
    @ObservationIgnored var onUnplayable: ((Track) -> Void)?
    /// Called once a deck has read its track through, so a missing BPM or key can be filled in.
    @ObservationIgnored var onAnalyzed: ((Track, TrackAnalysis) -> Void)?
    /// Called whenever a deck starts playing, so the queue player can pause.
    @ObservationIgnored var onStartedPlaying: (() -> Void)?

    private enum Keys {
        static let masterVolume = "mixer.masterVolume"
        static let autoFadeSeconds = "mixer.autoFadeSeconds"
    }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let files: PlaybackFileCache
    /// What the file cache was last told the decks need.
    @ObservationIgnored private var keptTrackIDs: Set<Int64> = []
    @ObservationIgnored private var isSetUp = false
    @ObservationIgnored private var outputDeviceUID: String?
    @ObservationIgnored private var fade: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    /// `files`: the shared cache when nil (tests pass their own).
    init(files: PlaybackFileCache? = nil) {
        self.files = files ?? .shared
        let defaults = UserDefaults.standard
        masterVolume = defaults.object(forKey: Keys.masterVolume) as? Float ?? 0.8
        autoFadeSeconds = defaults.object(forKey: Keys.autoFadeSeconds) as? Double ?? 8
        for deck in decks {
            deck.startEngine = { [weak self] in self?.startEngine() ?? false }
            deck.didStop = { [weak self] in self?.deckStopped() }
            deck.levelChanged = { [weak self] in self?.applyGains() }
            deck.playCounted = { [weak self] track in self?.onTrackPlayed?(track) }
            deck.listenEnded = { [weak self] track, listen in self?.onListenEnded?(track, listen) }
        }
    }

    // MARK: Loading

    /// Opens `track` on a deck, cued at `seconds`. `whenReady` runs once it can play.
    func load(_ track: Track, on side: Side, at seconds: TimeInterval = 0, whenReady: ((Deck) -> Void)? = nil) {
        setUpIfNeeded()
        let deck = deck(side)
        let token = deck.beginLoading(track)
        keepFiles()
        let ref = TrackRef(id: track.id, path: track.path)
        deck.loading = Task {
            // Copied locally first when it's on the share: decks seek a lot, and the waveform reads it all.
            let opened = await files.openFile(for: ref, locate: locate)
            guard deck.loadToken == token else { return }
            guard let file = opened?.file else {
                deck.failLoading("Can't open “\(track.displayTitle)”")
                onUnplayable?(track)
                return
            }
            guard connect(deck, for: file.processingFormat) else {
                deck.failLoading("Unsupported audio format")
                return
            }
            deck.finishLoading(file, at: seconds)
            whenReady?(deck)
            let url = file.url
            let hint = track.bpm > 0 ? Double(track.bpm) : nil
            let analysis = await BlockingIO.analysis.run { TrackAnalysis.analyze(url, bpmHint: hint) }
            if deck.loadToken == token { deck.analysis = analysis }
            if let analysis { onAnalyzed?(track, analysis) }
        }
    }

    func pauseAll() {
        for deck in decks { deck.pause() }
    }

    /// Ends both decks' listens as stopped, for when susurrus quits.
    func endListens() {
        for deck in decks { deck.endListen(.stopped) }
    }

    /// How far deck A's beat is ahead of deck B's, in seconds at A's playing speed (negative:
    /// behind), while both are playing with a beat grid. Within half a beat either way.
    var beatOffset: TimeInterval? {
        guard a.isPlaying, b.isPlaying, let gridA = a.beatGrid, let gridB = b.beatGrid,
              let bpm = a.effectiveBPM else { return nil }
        var beats = gridA.phase(at: a.currentTime) - gridB.phase(at: b.currentTime)
        beats -= beats.rounded()
        return beats * 60 / bpm
    }

    // MARK: Crossfader

    /// Equal-power curve: the blend keeps the same loudness all the way across.
    nonisolated static func crossfadeGains(_ position: Double) -> (a: Float, b: Float) {
        let angle = min(max(position, 0), 1) * .pi / 2
        return (Float(cos(angle)), Float(sin(angle)))
    }

    /// Moves the crossfader by hand, which stops any auto crossfade.
    func moveCrossfader(to position: Double) {
        cancelAutoFade()
        setCrossfader(position)
    }

    /// Glides the crossfader to the far side over `autoFadeSeconds`, starting the incoming deck if
    /// it's loaded and paused.
    func autoFade() {
        cancelAutoFade()
        let from = crossfader
        let to: Double = crossfader < 0.5 ? 1 : 0
        let incoming = deck(to == 1 ? .b : .a)
        if incoming.isReady, !incoming.isPlaying { incoming.play() }
        let seconds = autoFadeSeconds
        isAutoFading = true
        fade = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(start) / seconds)
                // Eased at both ends, like a hand on the fader.
                self?.setCrossfader(from + (to - from) * (1 - cos(t * .pi)) / 2)
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if !Task.isCancelled { self?.isAutoFading = false }
        }
    }

    func cancelAutoFade() {
        fade?.cancel()
        fade = nil
        isAutoFading = false
    }

    private func setCrossfader(_ position: Double) {
        crossfader = min(max(position, 0), 1)
        applyGains()
    }

    private func applyGains() {
        let (gainA, gainB) = Mixer.crossfadeGains(crossfader)
        // Squared so the channel fader feels even across its travel, like an audio-taper fader.
        a.channel.outputVolume = a.level * a.level * gainA
        b.channel.outputVolume = b.level * b.level * gainB
    }

    // MARK: Output device

    /// nil follows the system default output. Follows the queue player's choice.
    func setOutputDevice(_ uid: String?) {
        outputDeviceUID = uid
        guard isSetUp else { return }
        let device = uid.flatMap(OutputDevices.deviceID(forUID:)) ?? OutputDevices.defaultOutputDeviceID()
        guard let device else { return }
        let playing = decks.filter(\.isPlaying)
        for deck in playing { deck.pause(notify: false) }
        engine.stop()
        engine.setOutputDevice(device)
        for deck in playing { deck.play() }
    }

    // MARK: Engine

    /// Builds the graph the first time a deck is loaded, so an unused mixer costs nothing.
    private func setUpIfNeeded() {
        guard !isSetUp else { return }
        isSetUp = true
        if let uid = outputDeviceUID, let device = OutputDevices.deviceID(forUID: uid) {
            engine.setOutputDevice(device)
        }
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 44_100, channels: 2)!
        for deck in decks {
            for node in [deck.node, deck.input, deck.varispeed, deck.eq, deck.channel] as [AVAudioNode] {
                engine.attach(node)
            }
            engine.connect(deck.input, to: deck.varispeed, format: format)
            engine.connect(deck.varispeed, to: deck.eq, format: format)
            engine.connect(deck.eq, to: deck.channel, format: format)
            engine.connect(deck.channel, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = masterVolume
        applyGains()

        // Pick up where the decks were, on the new device.
        engine.onConfigurationChange { [weak self] in
            guard let self else { return }
            for deck in self.decks where deck.isPlaying { deck.restart() }
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.tick()
            }
        }
    }

    /// Returns false if the engine can't take this format (it raises an NSException, caught in ObjC).
    private func connect(_ deck: Deck, for format: AVAudioFormat) -> Bool {
        if let connected = deck.connectedFormat,
           connected.sampleRate == format.sampleRate, connected.channelCount == format.channelCount {
            return true
        }
        engine.disconnectNodeOutput(deck.node)
        var error: NSError?
        guard MMConnectNodes(engine, deck.node, deck.input, format, &error) else {
            deck.connectedFormat = nil
            return false
        }
        deck.connectedFormat = format
        return true
    }

    private func startEngine() -> Bool {
        do {
            if !engine.isRunning { try engine.start() }
            errorMessage = nil
            onStartedPlaying?()
            return true
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Lets the audio hardware go when neither deck is playing.
    private func deckStopped() {
        if !a.isPlaying, !b.isPlaying, engine.isRunning { engine.stop() }
    }

    /// Runs twice a second: notes where the decks are, counts plays, and tells the file cache what
    /// the decks still need.
    private func tick() {
        for deck in decks {
            deck.notePlayhead()
            deck.countPlayIfDue()
        }
        keepFiles()
    }

    private func keepFiles() {
        let trackIDs = Set(decks.compactMap { $0.track?.id })
        guard trackIDs != keptTrackIDs else { return }
        keptTrackIDs = trackIDs
        files.keep(trackIDs, for: self)
    }
}

// MARK: - Deck

@MainActor
@Observable
final class Deck {
    let side: Mixer.Side

    private(set) var track: Track?
    private(set) var isLoading = false
    private(set) var isPlaying = false {
        // Each change books the listening time under the state that's ending.
        willSet { listen?.update(audible: isPlaying) }
    }
    private(set) var errorMessage: String?
    /// Loudness overview and beat grid, once the file has been read through (nil until then).
    fileprivate(set) var analysis: TrackAnalysis?
    var waveform: [Float] { analysis?.overview ?? [] }
    var beatGrid: BeatGrid? { analysis?.grid }
    /// Where Cue jumps back to.
    private(set) var cuePoint: TimeInterval = 0
    /// Speed change as a fraction (0.02 is +2%). Pitch follows, like a turntable.
    var tempo: Double = 0 { didSet { applyRate() } }
    /// Temporary speed change while a nudge button is held, for lining up beats.
    private(set) var nudge: Double = 0
    /// Channel fader, 0…1.
    var level: Float = 1 { didSet { levelChanged() } }
    /// EQ knobs, −1…1: up to +6 dB, down to a near kill.
    var low: Float = 0 { didSet { eq.bands[0].gain = Deck.eqGain(low) } }
    var mid: Float = 0 { didSet { eq.bands[1].gain = Deck.eqGain(mid) } }
    var high: Float = 0 { didSet { eq.bands[2].gain = Deck.eqGain(high) } }

    static let tempoRange = 0.08
    static let nudgeAmount = 0.03

    @ObservationIgnored let node = AVAudioPlayerNode()
    @ObservationIgnored let input = AVAudioMixerNode()
    @ObservationIgnored let varispeed = AVAudioUnitVarispeed()
    @ObservationIgnored let eq = AVAudioUnitEQ(numberOfBands: 3)
    @ObservationIgnored let channel = AVAudioMixerNode()

    @ObservationIgnored fileprivate var connectedFormat: AVAudioFormat?
    @ObservationIgnored fileprivate var startEngine: () -> Bool = { false }
    @ObservationIgnored fileprivate var didStop: () -> Void = {}
    @ObservationIgnored fileprivate var levelChanged: () -> Void = {}
    @ObservationIgnored fileprivate var playCounted: (Track) -> Void = { _ in }
    @ObservationIgnored fileprivate var listenEnded: (Track, ListenRecord) -> Void = { _, _ in }
    /// Bumped per load or eject, so a slow load that's been replaced is dropped.
    @ObservationIgnored fileprivate private(set) var loadToken = 0
    /// The load under way: cancelled when it's replaced, so a copy nobody needs can stop.
    @ObservationIgnored fileprivate var loading: Task<Void, Never>?

    @ObservationIgnored private var file: AVAudioFile?
    /// Bumped whenever the node's schedule is torn down, so stale completions are ignored.
    @ObservationIgnored private var generation = 0
    /// File frame the current segment was scheduled from.
    @ObservationIgnored private var startFrame: AVAudioFramePosition = 0
    /// The playhead at the last tick while the engine ran. When the output device changes, the
    /// engine has stopped (and its clock with it) before we hear about it.
    @ObservationIgnored private var lastPlayheadFrame: AVAudioFramePosition = 0
    /// Observed, so a seek while paused redraws whatever shows the position.
    private var pausedFrame: AVAudioFramePosition = 0
    /// The loaded track's listen so far: from its first play until the deck moves on.
    @ObservationIgnored private var listen: ListenSession?
    @ObservationIgnored private var reachedEndOnce = false

    init(side: Mixer.Side) {
        self.side = side
        let bands = eq.bands
        bands[0].filterType = .lowShelf
        bands[0].frequency = 200
        bands[1].filterType = .parametric
        bands[1].frequency = 1_000
        bands[1].bandwidth = 2
        bands[2].filterType = .highShelf
        bands[2].frequency = 4_000
        for band in bands {
            band.gain = 0
            band.bypass = false
        }
    }

    /// Knob position → dB. Gentle near the middle, steep near the bottom so the end of the travel
    /// takes the band out.
    nonisolated static func eqGain(_ knob: Float) -> Float {
        knob >= 0 ? knob * 6 : -40 * knob * knob
    }

    var isReady: Bool { file != nil }

    var duration: TimeInterval {
        guard let file else { return track?.length ?? 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    var currentTime: TimeInterval {
        guard let file else { return 0 }
        return Double(currentFrame) / file.processingFormat.sampleRate
    }

    /// The track's own BPM: the beat grid's (to a hundredth) once it's been fitted, else the tag's.
    var bpm: Double? {
        if let grid = beatGrid { return grid.bpm }
        guard let bpm = track?.bpm, bpm > 0 else { return nil }
        return Double(bpm)
    }

    /// The track's BPM at the current tempo, if it has one.
    var effectiveBPM: Double? {
        bpm.map { $0 * (1 + tempo) }
    }

    /// The track's key: as tagged, else as worked out when the deck read it.
    var key: MusicalKey? { track?.key ?? analysis?.key }

    /// Semitones the tempo shifts the pitch by (the varispeed moves both), to the nearest one.
    var pitchShift: Int { Int((12 * log2(1 + tempo)).rounded()) }

    /// The key it sounds in at the current tempo.
    var effectiveKey: MusicalKey? { key?.transposed(by: pitchShift) }

    /// How fast the track is playing, with any nudge.
    var playbackRate: Double { (1 + tempo) * (1 + nudge) }

    private var currentFrame: AVAudioFramePosition {
        guard let file else { return 0 }
        guard isPlaying else { return pausedFrame }
        // No clock while the engine is stopped, nor before the node's first render after play.
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return lastPlayheadFrame }
        return min(file.length, startFrame + max(0, playerTime.sampleTime))
    }

    // MARK: Transport

    func play() {
        guard let file, let track, !isPlaying, startEngine() else { return }
        if listen == nil { listen = ListenSession(track) }
        // At the end, play again from the cue point.
        let from = pausedFrame >= file.length - 1 ? frame(for: cuePoint) : pausedFrame
        schedule(from: from)
        node.play()
        isPlaying = true
    }

    func pause() {
        pause(notify: true)
    }

    fileprivate func pause(notify: Bool) {
        guard isPlaying else { return }
        pausedFrame = currentFrame
        halt()
        if notify { didStop() }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) {
        guard file != nil else { return }
        let target = frame(for: seconds)
        if isPlaying {
            halt()
            schedule(from: target)
            node.play()
            isPlaying = true
        } else {
            pausedFrame = target
        }
    }

    /// Playing: back to the cue point, paused. Paused: the cue point moves here.
    func cue() {
        guard file != nil else { return }
        if isPlaying {
            pause()
            seek(to: cuePoint)
        } else {
            cuePoint = currentTime
        }
    }

    func setNudge(_ amount: Double) {
        nudge = amount
        applyRate()
    }

    /// Sets the tempo so this deck's BPM matches `other`'s (or half/double it, whichever is
    /// closest). Only lines up the speed; the beats still need lining up by ear.
    func matchTempo(to other: Deck) {
        if let match = tempoMatching(other) { tempo = match }
    }

    func tempoMatching(_ other: Deck) -> Double? {
        guard let bpm, let target = other.effectiveBPM else { return nil }
        let best = [target, target * 2, target / 2]
            .map { $0 / bpm - 1 }
            .min { abs($0) < abs($1) }!
        return abs(best) <= Deck.tempoRange + 0.0001 ? best : nil
    }

    func eject() {
        pause(notify: false)  // keeps the position, for the listen
        didStop()
        endListen(nil)
        loading?.cancel()
        loadToken += 1
        track = nil
        file = nil
        analysis = nil
        isLoading = false
        errorMessage = nil
        cuePoint = 0
        pausedFrame = 0
    }

    // MARK: Loading (driven by Mixer)

    fileprivate func beginLoading(_ track: Track) -> Int {
        pause(notify: false)  // keeps the position, for the listen
        didStop()
        endListen(nil)
        loading?.cancel()
        reachedEndOnce = false
        loadToken += 1
        self.track = track
        file = nil
        analysis = nil
        errorMessage = nil
        isLoading = true
        return loadToken
    }

    fileprivate func finishLoading(_ file: AVAudioFile, at seconds: TimeInterval) {
        self.file = file
        isLoading = false
        pausedFrame = frame(for: seconds)
        cuePoint = Double(pausedFrame) / file.processingFormat.sampleRate
    }

    fileprivate func failLoading(_ message: String) {
        isLoading = false
        errorMessage = message
        EventLog.shared.log("Deck \(side.name): \(message) — \(track?.path ?? "")")
    }

    /// Notes where the playhead is while the engine runs (from the mixer's tick).
    fileprivate func notePlayhead() {
        guard isPlaying, node.engine?.isRunning == true else { return }
        lastPlayheadFrame = currentFrame
    }

    /// Reschedules at the current position, after the engine stopped underneath us.
    fileprivate func restart() {
        guard isPlaying else { return }
        pause(notify: false)
        play()
    }

    // MARK: Listens

    /// Counts the loaded track as played, once, when enough of it has been heard.
    fileprivate func countPlayIfDue() {
        listen?.update(audible: isPlaying)
        if listen?.takePlay(duration: duration) == true, let track = listen?.track { playCounted(track) }
    }

    /// Ends the current listen. A deck counts it as finished once it played to the end or long
    /// enough to count as a play; anything shorter was auditioning or mixed out early, and moving a
    /// deck on says nothing against the track, so it's stopped rather than skipped. `outcome`
    /// overrides that (quitting is always stopped).
    fileprivate func endListen(_ outcome: ListenOutcome?) {
        countPlayIfDue()
        guard let ended = listen else { return }
        listen = nil
        let outcome = outcome ?? (reachedEndOnce || ended.isCounted ? .finished : .stopped)
        if let record = ended.record(outcome, at: currentTime) { listenEnded(ended.track, record) }
    }

    // MARK: Scheduling

    private func frame(for seconds: TimeInterval) -> AVAudioFramePosition {
        guard let file else { return 0 }
        let frame = AVAudioFramePosition(max(0, seconds) * file.processingFormat.sampleRate)
        return min(frame, max(0, file.length - 1))
    }

    private func halt() {
        generation += 1
        node.stop()
        isPlaying = false
    }

    private func schedule(from frame: AVAudioFramePosition) {
        guard let file else { return }
        startFrame = frame
        lastPlayheadFrame = frame
        let frames = file.length - frame
        guard frames > 0 else { return }
        let scheduled = generation
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(frames), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.reachedEnd(generation: scheduled) }
        }
    }

    private func reachedEnd(generation finished: Int) {
        // A segment also "finishes" when the engine stops underneath it (an output device change).
        guard finished == generation, isPlaying, let file, node.engine?.isRunning == true else { return }
        pausedFrame = file.length
        reachedEndOnce = true
        halt()
        didStop()
    }

    private func applyRate() {
        varispeed.rate = Float(playbackRate)
    }
}
