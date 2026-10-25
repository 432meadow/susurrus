import SwiftUI

/// A compact player in the menu bar, for controlling playback without the main window.
struct MenuBarPlayer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let player = model.player
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(request: player.currentTrack?.artworkRequest, pixelSize: 160, cornerRadius: 6)
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    if let track = player.currentTrack {
                        Text(track.displayTitle).font(.headline).lineLimit(2)
                        Text(track.displayArtist).foregroundStyle(.secondary).lineLimit(1)
                        Text(track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("Not Playing").foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ProgressView(value: min(player.currentTime, player.duration), total: max(player.duration, 0.1))
                    .progressViewStyle(.linear)
            }

            HStack(spacing: 22) {
                Button { player.setShuffle(!player.shuffle) } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Palette.warm : .secondary)
                }
                .toggleAccessibility("Shuffle", isOn: player.shuffle)
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous")
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next")
                Button { player.cycleRepeatMode() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? .secondary : Palette.warm)
                }
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode.rawValue)
            }
            .buttonStyle(.borderless)
            .font(.title3)
            .disabled(player.currentTrack == nil)

            Divider()
            HStack {
                Button("Show susurrus") { showMainWindow() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 300)
    }

    /// Brings the main window forward, or opens it if it was closed (a second one would share
    /// the same model, sheets and all).
    private func showMainWindow() {
        if let window = model.mainWindow, window.isVisible || window.isMiniaturized {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate()
    }
}
