import SwiftUI

/// The play queue: what's playing, then what's after it. Drag to reorder, click to jump.
struct UpNextView: View {
    @Environment(AppModel.self) private var model
    /// Playing All Tracks queues ~50k tracks; a SwiftUI List that size hangs, so show the start.
    private static let displayLimit = 200

    var body: some View {
        let player = model.player
        let upNext = player.upNext(limit: Self.displayLimit)
        let total = player.upNextCount
        VStack(spacing: 0) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Button("Clear") { player.clearUpNext() }
                    .disabled(upNext.isEmpty)
            }
            .padding(12)

            List {
                if let current = player.currentTrack {
                    Section("Now Playing") {
                        QueueRow(track: current, isCurrent: true)
                    }
                }
                Section(total == 0 ? "Nothing queued" : "\(total.formatted()) tracks") {
                    ForEach(Array(upNext.enumerated()), id: \.offset) { offset, track in
                        QueueRow(track: track, isCurrent: false, isUserQueued: offset < player.queuedAheadCount)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { player.jump(toUpNext: offset) }
                            .contextMenu {
                                Button("Play Now") { player.jump(toUpNext: offset) }
                                Button("Remove from Queue") { player.removeFromUpNext(at: [offset]) }
                            }
                    }
                    .onMove { player.moveInUpNext(from: $0, to: $1) }
                    .onDelete { player.removeFromUpNext(at: $0) }
                    if total > upNext.count {
                        Text("…and \((total - upNext.count).formatted()) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 260)
    }
}

private struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    var isUserQueued = false

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(request: track.artworkRequest, pixelSize: 64, cornerRadius: 3)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.displayTitle)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .lineLimit(1)
                Text(track.displayArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if isUserQueued {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(.tint)
                    .help("Added with Play Next / Add to Queue")
            }
            Text(Format.time(track.length)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
