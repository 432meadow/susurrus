import AppKit
import Observation

enum SidebarItem: Hashable {
    case allTracks
    case albums
    case artists
    case browser
    case recentlyAdded
    case recentlyPlayed
    case history
    case stats
    case duplicates
    case missing
    case soulseek
    case playlist(Int64)

    /// Views that bring their own content instead of the track list.
    var isCustomView: Bool {
        switch self {
        case .artists, .stats, .soulseek: true
        default: false
        }
    }

    /// Built-in lists that open in their own order (like playlists) until a column is clicked.
    var isBuiltInList: Bool {
        switch self {
        case .recentlyAdded, .recentlyPlayed, .history, .duplicates, .missing: true
        default: false
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var tracks: [Track] = []
    private(set) var playlists: [Playlist] = []
    /// Tracks for the sidebar selection, filtered by search and sorted.
    private(set) var visibleTracks: [Track] = []
    /// `visibleTracks` grouped into albums; only computed while the Albums view is showing.
    private(set) var albums: [Album] = []
    var albumSort: Album.Sort = .artist { didSet { refilter() } }
    var selectedAlbumID: Album.ID?
    /// Rows selected in the track table (or an album's track list). Menu commands (Get Info, Rate,
    /// Add to Playlist…) act on these.
    var selectedTrackIDs = Set<Int64>()

    /// Selected tracks in the order they appear in the list. An album page in the Artists view
    /// isn't the track list, so its selection is found by ID, in album order.
    var selectedTracks: [Track] {
        if selection == .artists {
            return selectedTrackIDs.compactMap { tracksByID[$0] }
                .sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
        }
        return visibleTracks.filter { selectedTrackIDs.contains($0.id) }
    }
    /// Problems loading the current selection (e.g. a smart playlist that can't be evaluated).
    private(set) var selectionError: String?
    /// Why the library couldn't be opened at all; shown instead of the track list.
    private(set) var libraryError: String? {
        didSet { if let libraryError { EventLog.shared.log(libraryError) } }
    }
    /// Messages shown over the window without blocking it (AppModel+Notices.swift).
    var notices: [Notice] = []

    var selection: SidebarItem? = .allTracks {
        didSet {
            // Menu commands act on the selection, so it mustn't outlive the list it was made in.
            if selection != oldValue { selectedTrackIDs = [] }
            loadSelection()
        }
    }
    var searchText = "" { didSet { if searchText != oldValue { refilter() } } }
    var sortOrder: [KeyPathComparator<Track>] = AppModel.defaultSort { didSet { refreshVisible() } }

    let player = Player()
    let mixer = Mixer()
    let soulseek = SoulseekModel()
    /// M3U, Library.xml and Rekordbox XML import/export (AppModel+Exchange.swift).
    let exchange = PlaylistExchange()

    /// The window's undo manager (set by the main view), for undoing edits and playlist changes.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Playlists deleted and then restored by Undo come back with new IDs; older undo steps
    /// still name the old ones, so they're looked up here (old → new).
    @ObservationIgnored var playlistIDRemap: [Int64: Int64] = [:]

    // MARK: Go to Current Track

    /// Asks the track list to select and scroll to a track; `token` changes on every request.
    struct RevealRequest: Equatable {
        let trackID: Int64
        let token: Int
    }

    private(set) var revealRequest: RevealRequest?

    func requestReveal(of trackID: Int64) {
        revealRequest = RevealRequest(trackID: trackID, token: (revealRequest?.token ?? 0) + 1)
    }

    // MARK: Missing files

    /// Tracks whose file couldn't be found at the last check (or when playback tried to open it).
    private(set) var unavailableTracks: [Int64: MissingFiles.Status] = [:]
    var isCheckingForMissingFiles = false
    /// Tracks waiting for the user to confirm Remove from Library.
    var pendingRemoval: [Track]?

    var missingTrackCount: Int { unavailableTracks.values.lazy.filter { $0 == .missing }.count }

    func setUnavailable(_ statuses: [Int64: MissingFiles.Status]) {
        guard statuses != unavailableTracks else { return }
        unavailableTracks = statuses
        noteTracksChanged()
        if selection == .missing { loadSelection() }
    }

    func markAvailable(_ ids: some Sequence<Int64>) {
        var statuses = unavailableTracks
        for id in ids { statuses[id] = nil }
        setUnavailable(statuses)
    }

    // MARK: MusicBrainz album lookups and covers

    /// The open Look Up Album sheet.
    var releaseLookup: ReleaseLookup?
    /// Find Missing Covers' progress while it runs.
    var coverSearch: CoverSearch?
    /// Albums waiting for an answer on whether found covers go into the files too.
    var pendingCoverSearch: [Album]?
    @ObservationIgnored var coverSearchTask: Task<Void, Never>?
    /// Download folders already matched (or tried) this session, so each is cleaned up once.
    @ObservationIgnored var cleanedDownloadFolders = Set<String>()

    // MARK: Artists

    /// Built on first use and dropped whenever track tags change (see `artists`).
    @ObservationIgnored var artistIndex: ArtistIndex?
    /// The artist open in the Artists view (`ArtistIndex.Artist.id`).
    var selectedArtistID: String?

    // MARK: Column browser

    /// Genre / Artist / Album filters for the Browse view (nil = All).
    private(set) var browserGenre: String?
    private(set) var browserArtist: String?
    private(set) var browserAlbum: String?
    private(set) var browserGenres: [String] = []
    private(set) var browserArtists: [String] = []
    private(set) var browserAlbums: [String] = []

    func browse(genre: String?) {
        browserGenre = genre
        browserArtist = nil
        browserAlbum = nil
        refilter()
    }

    func browse(artist: String?) {
        browserArtist = artist
        browserAlbum = nil
        refilter()
    }

    func browse(album: String?) {
        browserAlbum = album
        refilter()
    }

    /// Narrows `tracks` by the browser columns, filling each column from the level above it.
    private func applyBrowser(to tracks: [Track]) -> [Track] {
        func distinct(_ values: some Sequence<String>) -> [String] {
            Set(values.filter { !$0.isEmpty }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        browserGenres = distinct(tracks.lazy.map(\.genre))
        if let genre = browserGenre, !browserGenres.contains(genre) { browserGenre = nil }
        let byGenre = browserGenre.map { genre in tracks.filter { $0.genre == genre } } ?? tracks

        browserArtists = distinct(byGenre.lazy.map(\.albumGroupArtist))
        if let artist = browserArtist, !browserArtists.contains(artist) { browserArtist = nil }
        let byArtist = browserArtist.map { artist in byGenre.filter { $0.albumGroupArtist == artist } } ?? byGenre

        browserAlbums = distinct(byArtist.lazy.map(\.album))
        if let album = browserAlbum, !browserAlbums.contains(album) { browserAlbum = nil }
        return browserAlbum.map { album in byArtist.filter { $0.album == album } } ?? byArtist
    }

    // MARK: Adding files

    enum ScanState: Equatable {
        case idle
        case running(done: Int, total: Int)
        case finished(added: Int, updated: Int)
    }

    var scanState: ScanState = .idle
    /// Scans waiting for the one that's running (AppModel+Scanning.swift).
    var queuedScans = 0
    /// Folders rescanned for new music at launch, when a volume mounts, and every 30 minutes.
    var watchedFolders: [String] = UserDefaults.standard.stringArray(forKey: "library.watchedFolders") ?? [] {
        didSet { UserDefaults.standard.set(watchedFolders, forKey: "library.watchedFolders") }
    }
    /// The last scan asked for; each one waits for the one before it.
    @ObservationIgnored var lastScan: Task<ScanResult, Never>?
    /// Bumped by Stop: scans asked for before then don't run (or stop where they are).
    @ObservationIgnored var scanGeneration = 0
    /// A rescan of the watched folders is waiting or running, so another isn't queued behind it.
    @ObservationIgnored var isRescanQueued = false

    // MARK: Writing tags to files

    /// Off by default: edits then only change susurrus's database.
    var writesTagsToFiles: Bool = UserDefaults.standard.bool(forKey: "library.writeTagsToFiles") {
        didSet { UserDefaults.standard.set(writesTagsToFiles, forKey: "library.writeTagsToFiles") }
    }
    /// Set once the user has accepted the first-use warning.
    var hasConfirmedTagWriting: Bool = UserDefaults.standard.bool(forKey: "library.writeTagsConfirmed") {
        didSet { UserDefaults.standard.set(hasConfirmedTagWriting, forKey: "library.writeTagsConfirmed") }
    }
    let tagWriter = TagWriteQueue()

    // MARK: BPM and key detection

    let bpmAnalyzer = TrackAnalysisQueue.bpm()
    let keyAnalyzer = TrackAnalysisQueue.key()

    // MARK: Panels and sheets

    /// Tracks being edited in the Get Info sheet.
    var infoTracks: [Track]?
    /// The smart playlist being created or edited.
    var smartPlaylistDraft: SmartPlaylistDraft?
    /// Whether the Up Next panel is open.
    var isShowingUpNext = false
    /// The playlist whose name is being edited in the sidebar (a new one starts that way).
    var renamingPlaylistID: Int64?
    /// The main window, for bringing it back from the menu bar.
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Whether the two-deck mixer sits above the now-playing bar.
    var isShowingMixer = UserDefaults.standard.bool(forKey: "mixer.isShowing") {
        didSet { UserDefaults.standard.set(isShowingMixer, forKey: "mixer.isShowing") }
    }
    /// Whether the mixer shows both decks' beats close up above the decks.
    var isShowingBeatView = UserDefaults.standard.object(forKey: "mixer.isShowingBeats") as? Bool ?? true {
        didSet { UserDefaults.standard.set(isShowingBeatView, forKey: "mixer.isShowingBeats") }
    }

    func showInfo(for tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        infoTracks = tracks
    }

    /// Bumped whenever track metadata changes in place (ratings, play counts, tag edits), so views
    /// that show those values know to redraw even though the track objects are the same.
    private(set) var libraryRevision = 0
    /// Bumped whenever a listen is recorded or history is cleared, so Stats knows to recompute.
    var statsRevision = 0

    private static let defaultSort = [KeyPathComparator(\Track.dateAddedSortKey, order: .reverse)]
    @ObservationIgnored private(set) var store: LibraryStore?
    @ObservationIgnored private(set) var tracksByID: [Int64: Track] = [:]
    @ObservationIgnored private var pathIndex: [String: Track]?
    /// Selection contents in their natural order (playlist order, or library order).
    @ObservationIgnored private var selectionTracks: [Track] = []
    /// `selectionTracks` in the current sort order: typing in the search field only narrows it.
    @ObservationIgnored private var sortedSelection: [Track] = []
    /// Copies of the tracks for work off the main actor (`detachedTracks()`), until a track changes.
    @ObservationIgnored private var cachedSnapshots: [Track]?
    @ObservationIgnored private var predicateCache: [Int64: NSPredicate] = [:]
    @ObservationIgnored private var selectionLoad: Task<Void, Never>?
    /// Which playlist or built-in list `selectionTracks` holds, so reloading it keeps the user's column sort.
    @ObservationIgnored private var loadedItem: SidebarItem?
    @ObservationIgnored var missingFilesCheck: Task<Void, Never>?
    /// A volume came or went while a check ran; check everything again once it's done.
    @ObservationIgnored var needsMissingFilesCheck = false
    static let recentDays = 30
    static let historyLimit = 2000
    /// True while a playlist (usually a smart one) is being evaluated.
    private(set) var isLoadingSelection = false

    /// `libraryURL` lets tests use a throwaway database.
    init(libraryURL: URL = LibraryStore.defaultURL) {
        do {
            store = try LibraryStore(url: libraryURL)
            try reload()
        } catch {
            libraryError = "Couldn't open the library: \(error.localizedDescription)"
        }
        let info = Bundle.main.infoDictionary ?? [:]
        EventLog.shared.log("Launched susurrus \(info["CFBundleShortVersionString"] as? String ?? "(development build)")", level: .info)
        player.locate = makeLocator()
        player.onTrackPlayed = { [weak self] track in self?.recordPlay(track) }
        player.onListenEnded = { [weak self] track, listen in self?.recordListen(listen, of: track) }
        connectMixer()
        soulseek.importFolders = { [weak self] folders in
            guard let self, self.store != nil else { return false }
            let scan = self.addToLibrary(folders)
            if self.soulseek.tagsDownloads { self.cleanUpDownloads(in: folders, after: scan) }
            return true
        }
        // The share is built from the library's tracks (no walk of the share needed), and they
        // advertise their bitrate, length and depth in search results.
        soulseek.libraryFiles = { [weak self] in
            guard let self else { return [] }
            return self.tracks.map { track in
                SlskLibraryFile(
                    path: track.path,
                    size: UInt64(max(0, track.fileSize)),
                    attributes: SlskFileAttributes(
                        bitrate: track.bitRate > 0 ? track.bitRate : nil,
                        durationSeconds: track.length > 0 ? Int(track.length) : nil,
                        sampleRate: track.sampleRate > 0 ? track.sampleRate : nil,
                        bitDepth: track.bitDepth > 0 ? track.bitDepth : nil))
            }
        }
        // Don't swap a file out from under the player.
        tagWriter.isInUse = { [weak self] path in
            guard let self else { return false }
            return self.player.currentTrack?.path == path || self.mixer.decks.contains { $0.track?.path == path }
        }
        tagWriter.didWrite = { [weak self] path, size in self?.noteFileRewritten(path: path, size: size) }
        tagWriter.persist = { [weak self] path, values in try? self?.store?.savePendingTagWrite(values, forPath: path) }
        restorePendingTagWrites()
        player.onUnplayable = { [weak self] track in self?.noteUnplayable(track) }
        bpmAnalyzer.didDetect = { [weak self] results in self?.saveDetectedBPMs(results) }
        keyAnalyzer.didDetect = { [weak self] results in self?.saveDetectedKeys(results) }
        restorePlaybackState()
        startWatchingFolders()
        if soulseek.connectsAtLaunch, soulseek.hasCredentials { soulseek.connect() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.savePlaybackState()
                self?.player.endCurrentListen()
                self?.mixer.endListens()
                EventLog.shared.log("Quit", level: .info)
            }
        }

        // Covers that failed while the music share was unmounted are worth retrying once it's back;
        // so are files that looked missing. Only the volume that came or went is checked.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notification in
            ArtworkStore.shared.forgetMisses()
            let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.checkForMissingFiles(onVolume: volume) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.checkForMissingFiles(onVolume: volume) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))  // after launch has settled and the share has had time to mount
            self?.checkForMissingFiles()
        }
    }

    var playlistsByID: [Int64: Playlist] {
        var result: [Int64: Playlist] = [:]
        func walk(_ items: [Playlist]) {
            for item in items {
                result[item.id] = item
                walk(item.children ?? [])
            }
        }
        walk(playlists)
        return result
    }

    // MARK: Library

    /// Re-reads the whole library. Tracks already loaded keep their objects (the player, the
    /// mixer, open sheets and undo steps hold on to them) and just take the stored values.
    func reload() throws {
        guard let store else { return }
        let loaded = try store.loadTracks()
        let skips = try store.skipCounts()
        var byID: [Int64: Track] = [:]
        byID.reserveCapacity(loaded.count)
        tracks = loaded.map { fresh in
            let track: Track
            if let existing = tracksByID[fresh.id] {
                existing.update(from: fresh)
                track = existing
            } else {
                track = fresh
            }
            track.skipCount = skips[fresh.id] ?? 0
            byID[track.id] = track
            return track
        }
        tracksByID = byID
        artistIndex = nil
        pathIndex = nil
        cachedSnapshots = nil
        playlists = try store.loadPlaylists()
        predicateCache = [:]
        if case .playlist(let id) = selection, playlistsByID[id] == nil {
            selection = .allTracks  // its didSet loads the selection
        } else {
            loadSelection()
        }
    }

    // MARK: Selection

    /// Reloads the sidebar selection's tracks (call after its contents change).
    func loadSelection() {
        selectionError = nil
        selectionLoad?.cancel()
        switch selection {
        case .allTracks, .albums, .browser, nil:
            isLoadingSelection = false
            loadedItem = nil
            selectionTracks = tracks
            applySort(sortOrder.isEmpty ? AppModel.defaultSort : sortOrder)
        case .soulseek, .artists, .stats:
            // These views bring their own content; nothing to load from the library.
            isLoadingSelection = false
            loadedItem = nil
            selectionTracks = []
            refreshVisible()
        case .playlist(let id) where playlistsByID[id]?.kind == .regular:
            // A database read: quick enough to show at once, without a flash of the old list.
            showInOwnOrder(.playlist(id), regularPlaylistTracks(id))
        case .playlist(let id):
            loadInOwnOrder(.playlist(id)) { model in await model.tracks(inPlaylist: id) }
        case .recentlyAdded, .recentlyPlayed, .history, .duplicates, .missing:
            let item = selection!
            loadInOwnOrder(item) { model in await model.builtInListTracks(item) }
        }
    }

    /// Playlists and built-in lists open in their own order until a column header is clicked;
    /// reloading the one already showing keeps the user's sort (and its rows while it loads). A
    /// list that's new stays empty, with a spinner, until it's ready.
    private func loadInOwnOrder(_ item: SidebarItem, load: @escaping (AppModel) async -> [Track]) {
        if loadedItem != item {
            selectionTracks = []
            applySort([])
        }
        isLoadingSelection = true
        selectionLoad = Task { [weak self] in
            guard let self else { return }
            let result = await load(self)
            guard !Task.isCancelled, self.selection == item else { return }
            self.selectionTracks = result
            self.loadedItem = item
            self.isLoadingSelection = false
            self.refreshVisible()
        }
    }

    private func showInOwnOrder(_ item: SidebarItem, _ tracks: [Track]) {
        isLoadingSelection = false
        let keepSort = loadedItem == item
        loadedItem = item
        selectionTracks = tracks
        if keepSort { refreshVisible() } else { applySort([]) }
    }

    private func regularPlaylistTracks(_ id: Int64) -> [Track] {
        (perform("Couldn't load the playlist") { try $0.trackIDs(inPlaylist: id) } ?? []).compactMap { tracksByID[$0] }
    }

    private func builtInListTracks(_ item: SidebarItem) async -> [Track] {
        let cutoff = Date().addingTimeInterval(-Double(Self.recentDays) * 86_400)
        switch item {
        case .recentlyAdded:
            return tracks.filter { ($0.dateAdded ?? .distantPast) >= cutoff }
                .sorted { $0.dateAddedSortKey > $1.dateAddedSortKey }
        case .recentlyPlayed:
            return tracks.filter { ($0.lastPlayed ?? .distantPast) >= cutoff }
                .sorted { $0.lastPlayedSortKey > $1.lastPlayedSortKey }
        case .history:
            return (perform("Couldn't load the history") { try $0.historyTrackIDs(limit: Self.historyLimit) } ?? [])
                .compactMap { tracksByID[$0] }
        case .duplicates:
            let all = detachedTracks()
            let found = await Task.detached(priority: .userInitiated) { Duplicates.find(in: all).map(\.id) }.value
            return found.compactMap { tracksByID[$0] }
        case .missing:
            return tracks.filter { unavailableTracks[$0.id] == .missing }
        default:
            return []
        }
    }

    /// Assigning sortOrder already refreshes (didSet); only refresh directly when it's unchanged,
    /// so 50k rows aren't filtered, sorted and rebuilt twice.
    private func applySort(_ sort: [KeyPathComparator<Track>]) {
        if sort != sortOrder {
            sortOrder = sort
        } else {
            refreshVisible()
        }
    }

    /// Smart playlist rules run off the main thread: a KVC predicate over 50k tracks takes a
    /// noticeable moment, and a folder of smart playlists multiplies that.
    func tracks(inPlaylist id: Int64) async -> [Track] {
        guard let store, let playlist = playlistsByID[id] else { return [] }
        do {
            switch playlist.kind {
            case .regular:
                return try store.trackIDs(inPlaylist: id).compactMap { tracksByID[$0] }
            case .smart:
                let predicate = try predicate(for: id)
                let all = detachedTracks()
                let ids = try await Task.detached(priority: .userInitiated) {
                    try SmartPredicate.evaluate(predicate, on: all).map(\.id)
                }.value
                return ids.compactMap { tracksByID[$0] }
            case .folder:
                // A folder shows everything in its playlists, once each.
                var seen = Set<Int64>()
                var result: [Track] = []
                for child in playlist.children ?? [] {
                    result += await tracks(inPlaylist: child.id).filter { seen.insert($0.id).inserted }
                }
                return result
            }
        } catch {
            selectionError = "“\(playlist.name)”: \(error.localizedDescription)"
            return []
        }
    }

    private func predicate(for playlistID: Int64) throws -> NSPredicate {
        if let cached = predicateCache[playlistID] { return cached }
        guard let data = try store?.smartPredicateArchive(forPlaylist: playlistID) else {
            throw DatabaseError(message: "This smart playlist has no rules")
        }
        let predicate = try SmartPredicate.unarchive(data)
        predicateCache[playlistID] = predicate
        return predicate
    }

    /// Re-reads the sidebar's playlists after they were created, renamed, moved or deleted.
    func reloadPlaylists() {
        guard let store else { return }
        playlists = (try? store.loadPlaylists()) ?? playlists
        predicateCache = [:]
    }

    /// The library track for a file path (for drops from the track list or Finder).
    func track(atPath path: String) -> Track? {
        if pathIndex == nil {
            pathIndex = Dictionary(tracks.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return pathIndex?[path]
    }

    func noteTracksChanged() {
        libraryRevision += 1
        cachedSnapshots = nil
    }

    /// Call after track paths change, so drops and lookups by path see the new ones.
    func notePathsChanged() {
        pathIndex = nil
        cachedSnapshots = nil
    }

    /// Copies of every track for work done off the main actor, which mustn't read the live
    /// objects while they may be edited. Reused until a track changes.
    func detachedTracks() -> [Track] {
        if let cachedSnapshots { return cachedSnapshots }
        let copies = tracks.map { $0.snapshot() }
        cachedSnapshots = copies
        return copies
    }

    /// Brings tracks just added to the database (or changed in it) into memory. Tracks already
    /// loaded keep their objects and take the stored values.
    func refreshTracks(_ ids: [Int64]) {
        guard !ids.isEmpty, let loaded = perform("Couldn't load the library", { try $0.loadTracks(ids: ids) }) else { return }
        for fresh in loaded {
            if let existing = tracksByID[fresh.id] {
                existing.update(from: fresh)
            } else {
                tracks.append(fresh)
                tracksByID[fresh.id] = fresh
            }
        }
        artistIndex = nil
        pathIndex = nil
        noteTracksChanged()
        loadSelection()
    }

    /// Drops tracks deleted from the database from everything in memory.
    func forgetTracks(_ ids: Set<Int64>) {
        guard !ids.isEmpty else { return }
        tracks.removeAll { ids.contains($0.id) }
        cachedSnapshots = nil
        artistIndex = nil
        for id in ids {
            tracksByID[id] = nil
            unavailableTracks[id] = nil
        }
        pathIndex = nil
        selectedTrackIDs.subtract(ids)
        loadSelection()
    }

    /// Sorts the selection again and refilters it (after its tracks or their values changed).
    func refreshVisible() {
        sortedSelection = sortOrder.isEmpty ? selectionTracks : TrackSort.sorted(selectionTracks, by: sortOrder)
        refilter()
    }

    /// Narrows the sorted selection by the search and the column browser; filtering keeps the
    /// order, so typing never re-sorts 50k tracks.
    private func refilter() {
        var result = sortedSelection
        // Every word must match somewhere, so "aphex ambient" works; scopes like bpm:120-128 too.
        let query = SearchQuery(searchText)
        if !query.isEmpty {
            let now = Date()
            result = result.filter { query.matches($0, now: now) }
        }
        if selection == .browser {
            result = applyBrowser(to: result)
        }
        visibleTracks = result
        albums = selection == .albums ? Album.group(result, sortedBy: albumSort) : []
    }

    var selectedAlbum: Album? {
        selectedAlbumID.flatMap { id in albums.first { $0.id == id } }
    }

    func play(_ album: Album, startingAt index: Int = 0) {
        player.play(album.tracks, startingAt: index)
    }

    // MARK: Playback

    func play(_ track: Track) {
        guard let start = visibleTracks.firstIndex(where: { $0.id == track.id }) else { return }
        player.play(visibleTracks, startingAt: start)
    }

    /// Builds the player's file locator. It runs off the main thread (file checks on the network
    /// share can block), so it only captures the store, never `self` or `Track` objects.
    /// Order: stored path, then the stored macOS bookmark (which follows moved/renamed files).
    private func makeLocator() -> @Sendable (TrackRef) -> URL? {
        let store = store
        return { [weak self] ref in
            if FileManager.default.fileExists(atPath: ref.path) {
                return URL(fileURLWithPath: ref.path)
            }
            guard let store, let bookmark = try? store.bookmark(forTrack: ref.id) else { return nil }
            var isStale = false
            // .withoutMounting: never block trying to mount the SMB share from a bookmark.
            guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            let refreshed = isStale ? try? url.bookmarkData() : nil
            try? store.updatePath(url.path, bookmark: refreshed, forTrack: ref.id)
            Task { @MainActor in self?.tracksByID[ref.id]?.path = url.path }
            return url
        }
    }
}
