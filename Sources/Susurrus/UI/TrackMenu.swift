import AppKit
import SwiftUI

/// The right-click menus for tracks and albums, the same in every list: the AppKit track table
/// shows them as an `NSMenu`, SwiftUI lists (album and artist pages, Stats) as buttons
/// (`MenuEntries`).
@MainActor
enum TrackMenu {
    /// One menu entry, however it's shown.
    enum Entry {
        case action(String, isOn: Bool = false, run: () -> Void)
        case submenu(String, [Entry])
        case separator
    }

    /// The track list's menu for the rows with these IDs.
    static func make(for ids: Set<Int64>, model: AppModel) -> NSMenu {
        menu(entries(for: model.visibleTracks.filter { ids.contains($0.id) }, model: model))
    }

    /// The menu for `tracks`. `play` starts them where they're listed (an album from that track,
    /// say); without it they play from the main list.
    static func entries(for tracks: [Track], model: AppModel, play: (() -> Void)? = nil) -> [Entry] {
        guard let first = tracks.first else { return [] }
        var entries: [Entry] = [
            .action("Play") {
                if let play { play() } else { model.play(first) }
            },
            .action("Play Next") { model.playNext(tracks) },
            .action("Add to Queue") { model.addToQueue(tracks) },
            .separator,
            .action("Load on Deck A") { model.load(first, on: .a) },
            .action("Load on Deck B") { model.load(first, on: .b) },
            .separator,
            addToPlaylist(tracks, model: model),
        ]
        if model.editablePlaylistID != nil {
            entries.append(.action("Remove from Playlist") { model.removeFromCurrentPlaylist(tracks) })
        }
        entries += [
            .separator,
            rating(tracks, model: model),
            .action(detectBPMTitle(for: tracks)) { model.detectBPM(for: tracks) },
            .action(detectKeyTitle(for: tracks)) { model.detectKey(for: tracks) },
            .action("Get Info") { model.showInfo(for: tracks) },
            .action("Look Up Album on MusicBrainz…") { model.lookUpAlbum(for: tracks) },
        ]
        if model.coverSearch == nil {
            entries.append(.action("Find Missing Covers") { model.requestMissingCovers(for: model.albums(of: tracks)) })
        }
        if tracks.count == 1, !first.displayArtist.isEmpty {
            entries.append(.action("Go to Artist") { model.showArtist(first.displayArtist) })
        }
        entries.append(.action("Show in Finder") { NSWorkspace.shared.reveal(tracks) })
        if tracks.count == 1, model.unavailableTracks[first.id] != nil {
            entries.append(.action("Locate File…") { model.locate(first) })
        }
        entries += [
            .separator,
            .action(tracks.count == 1 ? "Remove from Library…" : "Remove \(tracks.count) Tracks from Library…") {
                model.confirmRemoveFromLibrary(tracks)
            },
        ]
        return entries
    }

    /// The menu for an album's cover. `leading` comes first (Open, on an artist page).
    static func entries(for album: Album, model: AppModel, leading: [Entry] = []) -> [Entry] {
        var entries = leading + [
            .action("Play") { model.play(album) },
            .action("Shuffle") { model.player.play(album.tracks.shuffled(), startingAt: 0) },
            .action("Play Next") { model.playNext(album.tracks) },
            .action("Add to Queue") { model.addToQueue(album.tracks) },
            .separator,
            addToPlaylist(album.tracks, model: model),
            .action("Get Info") { model.showInfo(for: album.tracks) },
            .action("Look Up Album on MusicBrainz…") { model.lookUpAlbum(for: album.tracks) },
        ]
        if model.coverSearch == nil {
            entries.append(.action("Find Missing Cover") { model.requestMissingCovers(for: [album]) })
        }
        if let artist = album.pageArtist, model.selection != .artists || model.artists.artist(named: artist)?.id != model.selectedArtistID {
            entries.append(.action("Go to Artist") { model.showArtist(artist) })
        }
        entries += [
            .action("Show in Finder") { NSWorkspace.shared.reveal(album.tracks) },
            .separator,
            .action("Remove Album from Library…") { model.confirmRemoveFromLibrary(album.tracks) },
        ]
        return entries
    }

    /// Detect BPM fills in missing tempos; once every selected track has one, it re-detects them.
    static func detectBPMTitle(for tracks: [Track]) -> String {
        !tracks.isEmpty && tracks.allSatisfy { $0.bpm > 0 } ? "Re-detect BPM" : "Detect BPM"
    }

    static func detectKeyTitle(for tracks: [Track]) -> String {
        !tracks.isEmpty && tracks.allSatisfy { !$0.musicalKey.isEmpty } ? "Re-detect Key" : "Detect Key"
    }

    private static func addToPlaylist(_ tracks: [Track], model: AppModel) -> Entry {
        var entries: [Entry] = [.action("New Playlist from Selection") { model.newPlaylist(with: tracks) }]
        let playlists = model.editablePlaylists
        if !playlists.isEmpty { entries.append(.separator) }
        for entry in playlists {
            entries.append(.action(entry.path) { model.add(tracks, toPlaylist: entry.playlist.id) })
        }
        return .submenu("Add to Playlist", entries)
    }

    private static func rating(_ tracks: [Track], model: AppModel) -> Entry {
        let current = Set(tracks.map(\.rating))
        var entries: [Entry] = []
        for stars in 0...5 {
            let title = stars == 0 ? "None" : String(repeating: "★", count: stars)
            entries.append(.action(title, isOn: current == [Double(stars)]) { model.setRating(Double(stars), for: tracks) })
        }
        return .submenu("Rating", entries)
    }

    static func menu(_ entries: [Entry]) -> NSMenu {
        let menu = NSMenu()
        for entry in entries {
            switch entry {
            case let .action(title, isOn, run):
                menu.addItem(ClosureMenuItem(title, state: isOn ? .on : .off, handler: run))
            case let .submenu(title, children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = Self.menu(children)
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }
}

/// `TrackMenu` entries as SwiftUI buttons, for the context menus of SwiftUI lists.
struct MenuEntries: View {
    let entries: [TrackMenu.Entry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            switch entry {
            case let .action(title, isOn, run):
                if isOn {
                    Button(action: run) { Label(title, systemImage: "checkmark") }
                } else {
                    Button(title, action: run)
                }
            case let .submenu(title, children):
                // Type-erased: the menu nests itself.
                Menu(title) { AnyView(MenuEntries(entries: children)) }
            case .separator:
                Divider()
            }
        }
    }
}

extension NSWorkspace {
    /// Shows the tracks' files selected in Finder.
    func reveal(_ tracks: [Track]) {
        activateFileViewerSelecting(tracks.map { URL(fileURLWithPath: $0.path) })
    }
}

/// NSMenuItem that runs a closure, so menus can be built without target/selector plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, keyEquivalent: String = "", state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
