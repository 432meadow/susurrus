import AppKit
import MediaPlayer

/// Media keys, the menu-bar Now Playing widget, Control Center and headphone buttons.
@MainActor
final class NowPlayingCenter {
    private weak var player: Player?
    private var artworkTrackID: Int64?
    private var artwork: MPMediaItemArtwork?

    init(player: Player) {
        self.player = player
        let commands = MPRemoteCommandCenter.shared()
        // Handlers can arrive on any thread; hop to the main actor.
        func handle(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let player = self?.player else { return }
                    action(player)
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
            Task { @MainActor in self?.player?.seek(to: position) }
            return .success
        }
    }

    /// Publishes the current track, position and state. Call on track change, play/pause and seek.
    func update() {
        let center = MPNowPlayingInfoCenter.default()
        guard let player, let track = player.currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.displayTitle,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            // The widget runs its own clock from this, so it stands still until audio comes out.
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying && !player.isLoading ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if artworkTrackID == track.id, let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            loadArtwork(for: track)
        }
        center.nowPlayingInfo = info
        center.playbackState = player.isPlaying ? .playing : .paused
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
