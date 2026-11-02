import Foundation

/// The two-deck mixer: loading decks, and handing playback between it and the queue player.
extension AppModel {
    func connectMixer() {
        mixer.locate = player.locate
        mixer.setOutputDevice(player.outputDevice)
        mixer.onTrackPlayed = { [weak self] track in self?.recordPlay(track) }
        mixer.onListenEnded = { [weak self] track, listen in self?.recordListen(listen, of: track) }
        mixer.onUnplayable = { [weak self] track in self?.noteUnplayable(track) }
        mixer.onAnalyzed = { [weak self] track, analysis in
            self?.fillIn(track, from: analysis)
            self?.rememberBeatGrid(analysis, of: track)
        }
        // One or the other: the mixer and the queue player never play over each other.
        mixer.onStartedPlaying = { [weak self] in self?.player.pause() }
        player.onStartedPlaying = { [weak self] in self?.mixer.pauseAll() }
        player.onOutputChanged = { [weak self] device in self?.mixer.setOutputDevice(device) }
        // While a mix is live, the media keys and Now Playing are its own.
        player.nowPlaying?.mixer = mixer
        mixer.onTransportChanged = { [weak self] in self?.player.nowPlaying?.setNeedsUpdate() }
    }

    func load(_ track: Track, on side: Mixer.Side) {
        isShowingMixer = true
        mixer.load(track, on: side)
    }

    func loadTrack(id: Int64, on side: Mixer.Side) {
        guard let track = tracksByID[id] else { return }
        load(track, on: side)
    }

    /// Moves the playing track onto a free deck at the same position, so a mix can start from
    /// whatever's on. The queue player keeps going until the deck is ready, then hands over, the
    /// listen so far included.
    func continueInMixer() {
        guard let track = player.currentTrack else { return }
        isShowingMixer = true
        let side = Mixer.Side.allCases.first { !mixer.deck($0).isPlaying } ?? .a
        mixer.moveCrossfader(to: side == .a ? 0 : 1)
        mixer.load(track, on: side, at: player.currentTime) { [weak self] deck in
            guard let self, self.player.currentTrack?.id == track.id else { return }
            deck.seek(to: self.player.currentTime)
            if self.player.isPlaying {
                deck.play()  // pauses the queue player
                guard deck.isPlaying else { return }  // no output: the queue player carries on
            }
            deck.continueListen(self.player.handOverListen())
        }
    }
}
