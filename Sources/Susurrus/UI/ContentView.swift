import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        // The bar sits below the split view rather than in a safeAreaInset: the detail column
        // doesn't pass that inset on to non-scrolling content, so the album pane slid under it.
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } detail: {
                detail
                    .overlay { if model.selection?.isCustomView != true { emptyState } }
                    .overlay(alignment: .bottomTrailing) { NoticeStack().padding(16) }
                    .modifier(PaletteTitle(subtitle: subtitle))
                    .toolbar {
                        if !model.activities.isEmpty {
                            ToolbarItem(placement: .primaryAction) { ActivityButton() }
                        }
                    }
                    .inspector(isPresented: $model.isShowingUpNext) {
                        // Only build the queue list while the panel is open.
                        if model.isShowingUpNext {
                            UpNextView()
                                .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
                        }
                    }
            }

            if model.isShowingMixer {
                MixerView()
            }
            NowPlayingBar()
        }
        .background(WindowReader { window in
            model.mainWindow = window
            WindowKeys.install(for: model)
        })
        .sheet(item: Binding(
            get: { model.infoTracks.map(InfoSheetItem.init) },
            set: { model.infoTracks = $0?.tracks }
        )) { item in
            InfoView(tracks: item.tracks)
        }
        .sheet(item: $model.smartPlaylistDraft) { draft in
            SmartPlaylistEditor(draft: draft)
        }
        .modifier(ExchangeSheets())
        .sheet(item: $model.releaseLookup, onDismiss: { model.releaseLookup?.cancel() }) { lookup in
            ReleaseLookupView(lookup: lookup)
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { model.undoManager = undoManager }
        .confirmationDialog(removalTitle, isPresented: Binding(
            get: { model.pendingRemoval != nil },
            set: { if !$0 { model.pendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let tracks = model.pendingRemoval { model.removeFromLibrary(tracks) }
                model.pendingRemoval = nil
            }
        } message: {
            Text(removalMessage)
        }
        .confirmationDialog("Write the covers into the files too?", isPresented: Binding(
            get: { model.pendingCoverSearch != nil },
            set: { if !$0 { model.pendingCoverSearch = nil } }
        ), presenting: model.pendingCoverSearch) { albums in
            Button("Find and Write into Files") { model.findMissingCovers(for: albums, writeToFiles: true) }
            Button("Find Only") { model.findMissingCovers(for: albums, writeToFiles: false) }
        } message: { albums in
            let files = albums.reduce(0) { $0 + $1.tracks.count }
            Text("Covers that are found show right away. Writing them into the files too rewrites every track of each album that gets one — up to \(files.formatted()) \(files == 1 ? "file" : "files") here, one at a time in the background, which can take hours on a slow network share.")
        }
    }

    /// The library search sits in the toolbar only on the panes it filters.
    @ViewBuilder private var detail: some View {
        @Bindable var model = model
        let search = Binding(get: { model.searchText }, set: { model.searchText = $0 })
        switch model.selection {
        case .albums:
            AlbumGridView()
                .searchable(text: search, placement: .toolbar, prompt: "Search  (artist:, year:>2000, genre:…)")
        case .soulseek:
            SoulseekView()
        case .artists:
            ArtistsView()
                .searchable(text: search, placement: .toolbar, prompt: "Filter artists")
        case .stats:
            StatsView()
        case .browser:
            VSplitView {
                BrowserColumnsView()
                    .frame(minHeight: 120, idealHeight: 200, maxHeight: 400)
                TrackTableView()
                    .frame(minHeight: 200)
            }
            .searchable(text: search, placement: .toolbar, prompt: Self.searchPrompt)
        default:
            TrackTableView()
                .searchable(text: search, placement: .toolbar, prompt: Self.searchPrompt)
        }
    }

    private static let searchPrompt = "Search  (artist:, bpm:120-128, key:~8A, rating:>=4…)"

    @ViewBuilder private var emptyState: some View {
        if let error = model.libraryError {
            ContentUnavailableView("Library Unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.tracks.isEmpty {
            ContentUnavailableView {
                Label("No Music Yet", systemImage: "music.note.list")
            } description: {
                Text(model.isScanning ? "Adding your music…" : "Add music files or folders. They stay where they are.")
            } actions: {
                if !model.isScanning {
                    Button("Add to Library…") { model.chooseFilesToAdd() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else if model.isLoadingSelection, model.visibleTracks.isEmpty {
            ProgressView()
        } else if let error = model.selectionError {
            ContentUnavailableView("Can't Show Playlist", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.visibleTracks.isEmpty, !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else if model.visibleTracks.isEmpty, let item = model.selection, item.isBuiltInList {
            builtInListEmptyState(item)
        }
    }

    @ViewBuilder private func builtInListEmptyState(_ item: SidebarItem) -> some View {
        switch item {
        case .recentlyAdded:
            ContentUnavailableView("Nothing Added Lately", systemImage: "clock.badge.plus",
                                   description: Text("Tracks added in the last \(AppModel.recentDays) days show up here."))
        case .recentlyPlayed:
            ContentUnavailableView("Nothing Played Lately", systemImage: "clock.arrow.circlepath",
                                   description: Text("Tracks played in the last \(AppModel.recentDays) days show up here."))
        case .history:
            ContentUnavailableView("No History", systemImage: "list.bullet.rectangle",
                                   description: Text("Each play is listed here once it counts (half the track, or 4 minutes)."))
        case .duplicates:
            ContentUnavailableView("No Duplicates", systemImage: "square.on.square",
                                   description: Text("No two tracks share an artist and title with lengths within 2 seconds."))
        default:
            ContentUnavailableView("No Missing Files", systemImage: "checkmark.circle",
                                   description: Text("Every track's file was found at the last check."))
        }
    }

    private var removalTitle: String {
        let count = model.pendingRemoval?.count ?? 0
        return count == 1 ? "Remove 1 track from the library?" : "Remove \(count.formatted()) tracks from the library?"
    }

    /// Names the tracks, so it's clear which ones go.
    private var removalMessage: String {
        let tracks = model.pendingRemoval ?? []
        var names = tracks.prefix(3).map { "“\($0.displayTitle)”" }
        if tracks.count > names.count { names.append("\((tracks.count - names.count).formatted()) more") }
        return ListFormatter.localizedString(byJoining: names)
            + ". The files stay where they are; their play counts, ratings and playlist entries are lost. This can't be undone."
    }

    private var subtitle: String {
        if model.selection == .soulseek || model.selection == .stats { return "" }
        if model.selection == .artists { return "\(model.artists.artists.count.formatted()) artists" }
        let tracks = model.visibleTracks
        let seconds = tracks.reduce(0) { $0 + $1.length }
        let span = Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
        let activity = model.activities.map { " · " + $0.summary }.joined()
        if model.selection == .albums {
            return "\(model.albums.count.formatted()) albums · \(tracks.count.formatted()) tracks · \(span)\(activity)"
        }
        return "\(tracks.count.formatted()) tracks · \(span)\(activity)"
    }
}

/// The window's name in the slate accent, drawn by hand since a native title can't be coloured.
/// Hiding the native title needs macOS 15; on 14 it stays plain.
private struct PaletteTitle: ViewModifier {
    let subtitle: String

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbar(removing: .title)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("susurrus").font(.headline).foregroundStyle(Palette.cool)
                            if !subtitle.isEmpty {
                                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        .padding(.leading, 8)
                    }
                    .hidingSharedBackground()
                }
        } else {
            content.navigationSubtitle(subtitle)
        }
    }
}

private extension ToolbarContent {
    /// macOS 26 sets toolbar items in a glass capsule; the title reads better straight on the bar.
    @ToolbarContentBuilder
    func hidingSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Wraps the Get Info tracks so `.sheet(item:)` gets an identity.
private struct InfoSheetItem: Identifiable {
    let tracks: [Track]
    var id: [Int64] { tracks.map(\.id) }
}
