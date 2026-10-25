import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renameText = ""
    @FocusState private var isRenameFocused: Bool
    @State private var pendingDelete: Playlist?
    @State private var confirmClearHistory = false

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                Section("Library") {
                    Label("All Tracks", systemImage: "music.note")
                        .tag(SidebarItem.allTracks)
                        .paletteSelection(model.selection == SidebarItem.allTracks)
                    Label("Albums", systemImage: "square.grid.2x2")
                        .tag(SidebarItem.albums)
                        .paletteSelection(model.selection == SidebarItem.albums)
                    Label("Artists", systemImage: "music.mic")
                        .tag(SidebarItem.artists)
                        .paletteSelection(model.selection == SidebarItem.artists)
                        .help("Artist pages: your albums, their discography, similar artists")
                    Label("Browse", systemImage: "rectangle.split.3x1")
                        .tag(SidebarItem.browser)
                        .paletteSelection(model.selection == SidebarItem.browser)
                    Label("Recently Added", systemImage: "clock.badge.plus")
                        .tag(SidebarItem.recentlyAdded)
                        .paletteSelection(model.selection == SidebarItem.recentlyAdded)
                        .help("Added in the last \(AppModel.recentDays) days")
                    Label("Recently Played", systemImage: "clock.arrow.circlepath")
                        .tag(SidebarItem.recentlyPlayed)
                        .paletteSelection(model.selection == SidebarItem.recentlyPlayed)
                        .help("Played in the last \(AppModel.recentDays) days, most recent first")
                    Label("History", systemImage: "list.bullet.rectangle")
                        .tag(SidebarItem.history)
                        .paletteSelection(model.selection == SidebarItem.history)
                        .help("Every play, newest first")
                        .contextMenu {
                            Button("Clear History…") { confirmClearHistory = true }
                        }
                    Label("Stats", systemImage: "chart.bar")
                        .tag(SidebarItem.stats)
                        .paletteSelection(model.selection == SidebarItem.stats)
                        .help("Listening time, top artists, albums and tracks, and when you listen")
                    Label("Duplicates", systemImage: "square.on.square")
                        .tag(SidebarItem.duplicates)
                        .paletteSelection(model.selection == SidebarItem.duplicates)
                        .help("Same artist and title, lengths within 2 seconds")
                    if model.missingTrackCount > 0 {
                        Label("Missing Files", systemImage: "exclamationmark.triangle")
                            .badge(model.missingTrackCount)
                            .tag(SidebarItem.missing)
                            .paletteSelection(model.selection == SidebarItem.missing)
                            .contextMenu {
                                Button("Check Again") { model.checkForMissingFiles() }
                                Button("Remove Missing Tracks from Library…") { model.confirmRemoveFromLibrary(model.missingTracks) }
                            }
                    }
                }
                Section("Network") {
                    Label("Soulseek", systemImage: "point.3.connected.trianglepath.dotted")
                        .badge(model.soulseek.chats.unreadTotal)
                        .tag(SidebarItem.soulseek)
                        .paletteSelection(model.selection == SidebarItem.soulseek)
                }
                Section {
                    OutlineGroup(model.playlists, children: \.children) { playlist in
                        row(for: playlist)
                    }
                } header: {
                    HStack {
                        Text("Playlists")
                        Spacer()
                        Menu {
                            newPlaylistButtons(in: nil)
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("New playlist")
                    }
                }
            }
            .listStyle(.sidebar)
            // A new playlist (⌘N, the + menu) comes up with its name ready to type over.
            .onChange(of: model.renamingPlaylistID, initial: true) {
                guard let id = model.renamingPlaylistID, let playlist = model.playlistsByID[id] else { return }
                renameText = playlist.name
                // Its row may be scrolled out of sight, where its name field doesn't exist to take focus.
                proxy.scrollTo(SidebarItem.playlist(id))
            }
            .confirmationDialog("Clear the play history?", isPresented: $confirmClearHistory) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
            } message: {
                Text("Listening stats and skip counts start over. Play counts and Last Played dates stay as they are.")
            }
            .confirmationDialog(
                "Delete “\(pendingDelete?.name ?? "")”?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { playlist in
                Button("Delete", role: .destructive) { model.deletePlaylist(playlist.id) }
            } message: { playlist in
                Text(playlist.kind == .folder
                     ? "The folder and every playlist in it will be deleted. Tracks stay in the library."
                     : "Tracks stay in the library.")
            }
        }
    }

    @ViewBuilder
    private func row(for playlist: Playlist) -> some View {
        Group {
            if model.renamingPlaylistID == playlist.id {
                TextField("Name", text: $renameText)
                    .focused($isRenameFocused)
                    // Focus once the field is on screen: asked for any earlier, it's lost.
                    .onAppear { DispatchQueue.main.async { isRenameFocused = true } }
                    .onSubmit { commitRename(playlist.id) }
                    .onExitCommand { model.renamingPlaylistID = nil }
                    .onChange(of: isRenameFocused) { if !isRenameFocused { commitRename(playlist.id) } }
            } else {
                Label(playlist.name, systemImage: playlist.systemImage)
                    .help(playlist.predicateFormat ?? playlist.name)
            }
        }
        .tag(SidebarItem.playlist(playlist.id))
        .id(SidebarItem.playlist(playlist.id))
        .paletteSelection(model.selection == .playlist(playlist.id))
        .contextMenu { contextMenu(for: playlist) }
        .draggable("playlist:\(playlist.id)")
        .onDrop(of: [.fileURL, .plainText], isTargeted: nil) { providers in
            handleDrop(providers, onto: playlist)
        }
    }

    @ViewBuilder
    private func contextMenu(for playlist: Playlist) -> some View {
        if playlist.kind == .smart {
            Button("Edit Smart Playlist…") {
                if let predicate = model.smartPredicate(forPlaylist: playlist.id) {
                    model.smartPlaylistDraft = SmartPlaylistDraft(playlistID: playlist.id, name: playlist.name, predicate: predicate)
                }
            }
        }
        Button("Rename") { model.renamingPlaylistID = playlist.id }
        if playlist.kind == .folder {
            Divider()
            newPlaylistButtons(in: playlist.id)
        }
        if playlist.parentID != nil {
            Button("Move to Top Level") { model.movePlaylist(playlist.id, toFolder: nil, position: Int.max) }
        }
        Divider()
        Button("Export Playlist…") { model.exportPlaylistAsM3U(playlist.id) }
        Button("Import Playlist…") { model.chooseM3UToImport(into: playlist.kind == .folder ? playlist.id : playlist.parentID) }
        Button("Export for Rekordbox…") { model.showRekordboxExport(choosing: [playlist.id], wholeLibrary: false) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = playlist }
    }

    @ViewBuilder
    private func newPlaylistButtons(in folderID: Int64?) -> some View {
        Button("New Playlist") { model.newPlaylist(in: folderID) }
        Button("New Smart Playlist…") { model.smartPlaylistDraft = .new() }
        Button("New Folder") { model.newFolder(in: folderID) }
    }

    private func commitRename(_ id: Int64) {
        guard model.renamingPlaylistID == id else { return }
        model.renamingPlaylistID = nil
        model.renamePlaylist(id, to: renameText)
    }

    /// Tracks (as file URLs from the track list or Finder) are added to regular playlists, all in
    /// one step and in the order they were dragged; playlists ("playlist:<id>" text) dropped on a
    /// folder move into it.
    private func handleDrop(_ providers: [NSItemProvider], onto target: Playlist) -> Bool {
        let fileProviders = target.kind == .regular
            ? providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) } : []
        if !fileProviders.isEmpty {
            Task {
                var tracks: [Track] = []
                for provider in fileProviders {
                    let url = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url, let track = model.track(atPath: url.path) { tracks.append(track) }
                }
                model.add(tracks, toPlaylist: target.id)
            }
        }
        var handled = !fileProviders.isEmpty
        for provider in providers where !fileProviders.contains(provider) {
            if provider.canLoadObject(ofClass: String.self) {
                handled = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, text.hasPrefix("playlist:"), let id = Int64(text.dropFirst("playlist:".count)) else { return }
                    Task { @MainActor in
                        if target.kind == .folder {
                            model.movePlaylist(id, toFolder: target.id, position: Int.max)
                        } else {
                            // Dropping on a playlist puts the dragged one just before it, in its folder.
                            model.movePlaylist(id, toFolder: target.parentID, position: target.position)
                        }
                    }
                }
            }
        }
        return handled
    }
}
