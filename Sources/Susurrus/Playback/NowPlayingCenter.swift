import AppKit
import MediaPlayer

/// Media keys, the menu-bar Now Playing widget, Control Center and headphone buttons. They drive the
/// queue player, unless a mix is live: then they're the mixer's, because the queue player starting
/// would stop the mix.
@MainActor
final class NowPlayingCenter {
    /// What the widget shows.
    struct Shown {
        let track: Track
        let duration: TimeInterval
        let elapsed: TimeInterval
        /// Its clock runs at this speed; 0 stands still.
        let rate: Double
        let isPlaying: Bool
    }

    private weak var player: Player?
    weak var mixer: Mixer?
    private var artworkTrackID: Int64?
    private var artwork: MPMediaItemArtwork?
    private var isUpdatePending = false

    init(player: Player) {
        self.player = player
        let commands = MPRemoteCommandCenter.shared()
        // Handlers can arrive on any thread; hop to the main actor.
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NowPlayingCenter) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
                return .success
            }
        }
        handle(commands.togglePlayPauseCommand) { $0.togglePlayPause() }
        handle(commands.playCommand) { if !$0.isPlaying { $0.togglePlayPause() } }
        handle(commands.pauseCommand) { if $0.isPlaying { $0.togglePlayPause() } }
        handle(commands.nextTrackCommand) { $0.next() }
        handle(commands.previousTrackCommand) { $0.previous() }

        commands.changePlaybackPositionCommand.isEnabled = true
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }

    // MARK: Commands

    private var isMixLive: Bool { mixer?.isLive == true }

    private var isPlaying: Bool {
        isMixLive ? mixer?.isPlaying == true : player?.isPlaying == true
    }

    func togglePlayPause() {
        if isMixLive {
            mixer?.toggleLive()
        } else {
            player?.togglePlayPause()
        }
    }

    /// A mix has no next track to skip to, and starting one on the queue player would stop the mix.
    func next() {
        if !isMixLive { player?.next() }
    }

    func previous() {
        if !isMixLive { player?.previous() }
    }

    func seek(to position: TimeInterval) {
        if let deck = mixer?.leadDeck {
            deck.seek(to: position)
        } else {
            player?.seek(to: position)
        }
    }

    // MARK: The widget

    /// The deck most in a live mix, else the queue player's track.
    var shown: Shown? {
        if let deck = mixer?.leadDeck, let track = deck.track {
            return Shown(track: track, duration: deck.duration, elapsed: deck.currentTime,
                         rate: deck.isPlaying ? deck.playbackRate : 0, isPlaying: deck.isPlaying)
        }
        guard let player, let track = player.currentTrack else { return nil }
        return Shown(track: track, duration: player.duration, elapsed: player.currentTime,
                     // The widget runs its own clock from this, so it stands still until audio comes out.
                     rate: player.isPlaying && !player.isLoading ? 1 : 0, isPlaying: player.isPlaying)
    }

    /// `update`, once, after a burst of changes (a fader being dragged, a deck restarting).
    func setNeedsUpdate() {
        guard !isUpdatePending else { return }
        isUpdatePending = true
        Task { @MainActor in
            isUpdatePending = false
            update()
        }
    }

    /// Publishes the current track, position and state. Call on track change, play/pause and seek.
    func update() {
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = !isMixLive
        commands.previousTrackCommand.isEnabled = !isMixLive

        let center = MPNowPlayingInfoCenter.default()
        guard let shown else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let track = shown.track
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: shown.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: shown.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: shown.rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if artworkTrackID == track.id, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(for: track)
        }
        center.nowPlayingInfo = info
        center.playbackState = shown.isPlaying ? .playing : .paused
    }

    private func loadArtwork(for track: Track) {
        artworkTrackID = track.id
        artwork = nil
        let request = track.artworkRequest
        Task {
            guard let image = await ArtworkStore.shared.image(for: request, pixelSize: 512),
                  artworkTrackID == track.id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            update()
        }
    }
}
