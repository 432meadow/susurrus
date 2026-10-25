import AppKit
import Observation
import UniformTypeIdentifiers

/// State for playlist and library exchange that views watch.
@MainActor
@Observable
final class PlaylistExchange {
    /// The Rekordbox export sheet, while it's open.
    var rekordboxDraft: RekordboxExportDraft?
    /// What's being worked on, for the window subtitle ("Importing library…").
    var status: String?
    /// A Library.xml import waiting for the go-ahead in its preview sheet.
    var libraryImport: PendingLibraryImport?
    @ObservationIgnored let beatGrids = BeatGridCache()
}

/// A Library.xml import that's been read and planned, waiting for the go-ahead.
struct PendingLibraryImport: Identifiable {
    let id = UUID()
    let fileName: String
    let library: ITunesLibrary
    let plan: LibraryImportPlan
}

struct RekordboxExportDraft: Identifiable {
    let id = UUID()
    var wholeLibrary: Bool
    /// Playlists and folders to export when not the whole library (a folder brings everything in it).
    var chosen: Set<Int64>
}

/// Playlist and library exchange: M3U playlists in and out, importing an Apple Music / iTunes
/// `Library.xml`, and exporting Rekordbox XML. Everything works from the database; the only files
/// read are the ones being imported, plus the tags of files that are added to the library.
extension AppModel {
    /// The playlist or folder selected in the sidebar.
    var selectedPlaylistID: Int64? {
        guard case .playlist(let id) = selection, playlistsByID[id] != nil else { return nil }
        return id
    }

    // MARK: M3U export

    private static let m3uPathStyleKey = "exchange.m3uPathStyle"

    /// Saves a playlist (a smart playlist's current tracks, or everything in a folder) as M3U8.
    func exportPlaylistAsM3U(_ id: Int64) {
        guard let playlist = playlistsByID[id] else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = Self.fileName(for: playlist.name) + ".m3u8"
        panel.message = "Export “\(playlist.name)” as an M3U playlist."
        let styles = M3UPlaylist.PathStyle.allCases
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: styles.map(\.label))
        let saved = UserDefaults.standard.string(forKey: Self.m3uPathStyleKey).flatMap(M3UPlaylist.PathStyle.init) ?? .relative
        popup.selectItem(at: styles.firstIndex(of: saved) ?? 0)
        panel.accessoryView = Self.accessory(label: "Paths:", control: popup)
        // Not modal: the rest of the app (the mixer, say) keeps working while it's open.
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            let style = styles[max(0, popup.indexOfSelectedItem)]
            UserDefaults.standard.set(style.rawValue, forKey: Self.m3uPathStyleKey)
            MainActor.assumeIsolated { self?.exportPlaylist(playlist, to: url, style: style) }
        }
    }

    private func exportPlaylist(_ playlist: Playlist, to url: URL, style: M3UPlaylist.PathStyle) {
        Task {
            let entries = await tracks(inPlaylist: playlist.id).map(M3UPlaylist.entry)
            let text = M3UPlaylist.text(for: entries, style: style, directory: url.deletingLastPathComponent().path)
            do {
                try await BlockingIO.library.run { Result { try ExchangeFile.write(Data(text.utf8), to: url) } }.get()
                notify("Exported “\(playlist.name)”", "\(Self.count(entries.count, "entry", "entries")) in \(url.lastPathComponent)")
            } catch {
                report("Couldn't export “\(playlist.name)”", error)
            }
        }
    }

    // MARK: M3U import

    /// Imports M3U files as new playlists, in `folderID` (nil = top level).
    func chooseM3UToImport(into folderID: Int64? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = M3UPlaylist.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose M3U playlists to import. Files they list that aren't in the library yet are added."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.importM3U(urls, into: folderID) }
        }
    }

    func importM3U(_ urls: [URL], into folderID: Int64? = nil) {
        guard !urls.isEmpty, store != nil else { return }
        Task {
            var reports: [String] = []
            for url in urls {
                exchange.status = "Importing “\(url.deletingPathExtension().lastPathComponent)”…"
                reports.append(await importPlaylist(at: url, into: folderID))
            }
            exchange.status = nil
            notify(urls.count == 1 ? "Imported “\(urls[0].deletingPathExtension().lastPathComponent)”" : "Imported \(urls.count) playlists",
                   reports.joined(separator: "\n\n"), staysOpen: true)
        }
    }

    /// Matches each entry to a library track by its resolved path; files that exist but aren't in
    /// the library are added first. Returns the summary line for the alert.
    func importPlaylist(at url: URL, into folderID: Int64?) async -> String {
        let name = url.deletingPathExtension().lastPathComponent
        guard let data = await BlockingIO.library.run({ try? Data(contentsOf: url) }), let text = M3UPlaylist.decode(data) else {
            return "“\(name)” couldn't be read."
        }
        let entries = M3UPlaylist.parse(text, directory: url.deletingLastPathComponent().path)
        var matcher = TrackPathMatcher(tracks)
        let unmatched = Array(Set(entries.map(\.path).filter { matcher.trackID(forPath: $0) == nil }))
        let matched = entries.filter { matcher.trackID(forPath: $0.path) != nil }.count
        let addable = await BlockingIO.library.run {
            unmatched.filter { FileManager.default.fileExists(atPath: $0) && TagReader.isAudioFile(URL(fileURLWithPath: $0)) }
        }
        if !addable.isEmpty, await !addToLibrary(addable.map { URL(fileURLWithPath: $0) }).value.added.isEmpty {
            matcher = TrackPathMatcher(tracks)
        }

        let ids = entries.compactMap { matcher.trackID(forPath: $0.path) }
        let missing = entries.filter { matcher.trackID(forPath: $0.path) == nil }
        createPlaylist(named: name, with: ids.compactMap { tracksByID[$0] }, in: folderID)

        var lines = ["“\(name)”: \(Self.count(entries.count, "entry", "entries")). \(matched.formatted()) in the library"
                     + (ids.count > matched ? ", \((ids.count - matched).formatted()) added to it" : "")
                     + (missing.isEmpty ? "." : ", \(missing.count.formatted()) not found:")]
        lines += missing.prefix(8).map { "  \($0.title ?? ($0.path as NSString).lastPathComponent)" }
        if missing.count > 8 { lines.append("  …and \((missing.count - 8).formatted()) more") }
        return lines.joined(separator: "\n")
    }

    // MARK: Apple Music / iTunes library import

    func chooseLibraryXMLToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.prompt = "Import"
        panel.message = "Choose a library exported from Music or iTunes (File ▸ Library ▸ Export Library…)."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importLibraryXML(url) }
        }
    }

    /// Reads the export and plans the import; the preview sheet (`exchange.libraryImport`) shows
    /// what would change, and `confirmLibraryImport` applies it as one undoable step.
    func importLibraryXML(_ url: URL) {
        guard store != nil, exchange.status == nil, exchange.libraryImport == nil else { return }
        exchange.status = "Reading “\(url.lastPathComponent)”…"
        let all = detachedTracks()
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { () -> Result<(ITunesLibrary, LibraryImportPlan), Error> in
                Result {
                    let library = try ITunesLibrary(data: try Data(contentsOf: url))
                    return (library, LibraryImportPlan(library: library, tracks: all, fileExists: FileManager.default.fileExists))
                }
            }.value
            exchange.status = nil
            switch prepared {
            case .success(let (library, plan)):
                exchange.libraryImport = PendingLibraryImport(fileName: url.lastPathComponent, library: library, plan: plan)
            case .failure(let error):
                report("Couldn't import “\(url.lastPathComponent)”", error)
            }
        }
    }

    /// Goes ahead with the import in the preview sheet, first adding the files that are on disk
    /// but not in the library when `addFiles`.
    func confirmLibraryImport(addFiles: Bool) {
        guard let pending = exchange.libraryImport else { return }
        exchange.libraryImport = nil
        Task {
            var plan = pending.plan
            if addFiles, !plan.addablePaths.isEmpty {
                exchange.status = "Adding \(Self.count(plan.addablePaths.count, "file", "files"))…"
                let scan = await addToLibrary(plan.addablePaths.map { URL(fileURLWithPath: $0) }).value
                if !scan.added.isEmpty {
                    let all = detachedTracks()
                    plan = await Task.detached(priority: .userInitiated) {
                        LibraryImportPlan(library: pending.library, tracks: all, fileExists: { _ in false })
                    }.value
                }
                exchange.status = nil
            }
            applyLibraryImport(pending.library, plan: plan)
        }
    }

    /// The preview's lines: counts of what would change.
    static func importSummary(of plan: LibraryImportPlan) -> [String] {
        let total = plan.matchedCount + plan.addablePaths.count + plan.missingCount
        var lines = ["\(plan.matchedCount.formatted()) of \(Self.count(total, "track", "tracks")) are in the library"
                     + (plan.addablePaths.isEmpty ? "" : "; \(plan.addablePaths.count.formatted()) more are on disk but not in it")
                     + (plan.missingCount == 0 ? "." : "; \(plan.missingCount.formatted()) can't be found.")]
        lines.append("")
        lines.append("• Ratings for \(Self.count(plan.ratingCount, "track", "tracks")) (only where susurrus has none)")
        lines.append("• Play counts for \(plan.playCountCount.formatted()) (where the import's is higher)")
        lines.append("• Last played for \(plan.lastPlayedCount.formatted()) (where the import's is later)")
        lines.append("• Date added for \(plan.dateAddedCount.formatted()) (where the import's is earlier)")
        if plan.playlistCount + plan.folderCount > 0 {
            lines.append("• \(Self.count(plan.playlistCount, "playlist", "playlists"))"
                         + (plan.folderCount > 0 ? " in \(Self.count(plan.folderCount, "folder", "folders"))" : "")
                         + ", inside a new folder “\(Self.importFolderName)”")
        }
        if plan.skippedBuiltInPlaylists > 0 {
            lines.append("  (\(Self.count(plan.skippedBuiltInPlaylists, "built-in list", "built-in lists")) like Library and Music are skipped)")
        }
        lines.append("")
        lines.append("Saved to susurrus's database only, not written into the files. Edit ▸ Undo puts everything back.")
        return lines
    }

    static let importFolderName = "Apple Music"

    /// Brings over ratings, play counts and dates, and recreates the playlists and folders
    /// under one new folder. One undo step undoes all of it.
    func applyLibraryImport(_ library: ITunesLibrary, plan: LibraryImportPlan) {
        guard let store else { return }
        let actionName = "Import Library"
        undoManager?.beginUndoGrouping()
        defer {
            undoManager?.setActionName(actionName)
            undoManager?.endUndoGrouping()
        }

        let values: [ImportedTrackValues] = plan.changes.compactMap { change in
            guard let track = tracksByID[change.trackID] else { return nil }
            var value = ImportedTrackValues(track)
            if let rating = change.rating { value.rating = rating }
            if let playCount = change.playCount { value.playCount = playCount }
            if let lastPlayed = change.lastPlayed { value.lastPlayed = lastPlayed }
            if let dateAdded = change.dateAdded { value.dateAdded = dateAdded }
            return value
        }
        setImportedValues(values, actionName: actionName)

        guard !library.playlists.isEmpty,
              let folderID = perform("Couldn't create the imported playlists", { try $0.createPlaylist(named: Self.importFolderName, kind: .folder) })
        else { return }
        defer {
            reloadPlaylists()
            registerUndo(actionName) { $0.deletePlaylist($0.resolvedPlaylistID(folderID), actionName: actionName) }
        }
        do {
            var created: [String: Int64] = [:]
            for playlist in library.playlistsParentsFirst {
                let id = try store.createPlaylist(
                    named: playlist.name.isEmpty ? "Untitled Playlist" : playlist.name,
                    kind: playlist.isFolder ? .folder : .regular,
                    parentID: playlist.parentPersistentID.flatMap { created[$0] } ?? folderID,
                    trackIDs: playlist.isFolder ? [] : playlist.trackIDs.compactMap { plan.trackMap[$0] })
                if let key = playlist.persistentID { created[key] = id }
            }
        } catch {
            report("Couldn't create the imported playlists", error)
        }
    }

    /// Saves imported values; undoing calls this again with the values they replaced.
    func setImportedValues(_ values: [ImportedTrackValues], actionName: String) {
        guard !values.isEmpty else { return }
        let old = values.compactMap { tracksByID[$0.trackID].map(ImportedTrackValues.init) }
        guard perform("Couldn't save the imported values", { try $0.setImportedValues(values) }) != nil else { return }
        for value in values { tracksByID[value.trackID].map(value.apply) }
        noteTracksChanged()
        if selection == .recentlyAdded || selection == .recentlyPlayed { loadSelection() } else { refreshVisible() }
        registerUndo(actionName) { $0.setImportedValues(old, actionName: actionName) }
    }

    // MARK: Rekordbox XML export

    /// Opens the export sheet with `ids` ticked.
    func showRekordboxExport(choosing ids: Set<Int64> = [], wholeLibrary: Bool) {
        exchange.rekordboxDraft = RekordboxExportDraft(wholeLibrary: wholeLibrary, chosen: ids)
    }

    /// Writes the whole library, or the chosen playlists and the tracks in them, as Rekordbox XML.
    /// Smart playlists go out as plain playlists of their current tracks.
    func exportRekordboxXML(choosing chosen: Set<Int64>?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        panel.nameFieldStringValue = "rekordbox.xml"
        panel.message = "Import it in Rekordbox under Preferences ▸ Advanced ▸ rekordbox xml."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.exportRekordboxXML(choosing: chosen, to: url) }
        }
    }

    private func exportRekordboxXML(choosing chosen: Set<Int64>?, to url: URL) {
        exchange.status = "Exporting for Rekordbox…"
        Task {
            defer { exchange.status = nil }
            var nodes: [RekordboxXML.Node] = []
            for playlist in playlists {
                if let node = await rekordboxNode(for: playlist, chosen: chosen, inChosenFolder: false) { nodes.append(node) }
            }
            let exported: [Track]
            if chosen == nil {
                exported = tracks.sorted { $0.id < $1.id }
            } else {
                var seen = Set<Int64>()
                func collect(_ node: RekordboxXML.Node) -> [Int64] {
                    switch node {
                    case let .folder(_, children): children.flatMap(collect)
                    case let .playlist(_, ids): ids.filter { seen.insert($0).inserted }
                    }
                }
                exported = nodes.flatMap(collect).compactMap { tracksByID[$0] }
            }
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
            // The whole library is a big document: build and write it off the main thread, from copies.
            let (copies, grids, playlists) = (exported.map { $0.snapshot() }, exchange.beatGrids.all, nodes)
            let written = await Task.detached(priority: .userInitiated) {
                Result {
                    let xml = RekordboxXML.document(tracks: copies, beatGrids: grids, playlists: playlists, version: version)
                    try ExchangeFile.write(Data(xml.utf8), to: url)
                }
            }.value
            switch written {
            case .success: notify("Exported for Rekordbox", "\(Self.count(copies.count, "track", "tracks")) in \(url.lastPathComponent)")
            case .failure(let error): report("Couldn't export for Rekordbox", error)
            }
        }
    }

    /// nil when nothing in it was chosen. `chosen == nil` means everything.
    private func rekordboxNode(for playlist: Playlist, chosen: Set<Int64>?, inChosenFolder: Bool) async -> RekordboxXML.Node? {
        let included = chosen == nil || inChosenFolder || chosen!.contains(playlist.id)
        if playlist.kind == .folder {
            var children: [RekordboxXML.Node] = []
            for child in playlist.children ?? [] {
                if let node = await rekordboxNode(for: child, chosen: chosen, inChosenFolder: included) { children.append(node) }
            }
            return children.isEmpty && !included ? nil : .folder(name: playlist.name, children: children)
        }
        guard included else { return nil }
        return .playlist(name: playlist.name, trackIDs: await tracks(inPlaylist: playlist.id).map(\.id))
    }

    // MARK: Beat grids

    /// Keeps a grid the mixer fitted, for exports.
    func rememberBeatGrid(_ analysis: TrackAnalysis, of track: Track) {
        if let grid = analysis.grid { exchange.beatGrids.remember(grid, forTrack: track.id) }
    }

    // MARK: Dropping files on the window

    /// M3U files become playlists, a `.xml` library export is imported, anything else is added to
    /// the library (tracks dragged out of the list are already in it and are left alone).
    func handleWindowDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in fileProviders {
                let url = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                }
                if let url { urls.append(url) }
            }
            let playlistFiles = urls.filter(M3UPlaylist.isPlaylistFile)
            let libraryFiles = urls.filter { $0.pathExtension.lowercased() == "xml" }
            let others = urls.filter { url in
                !M3UPlaylist.isPlaylistFile(url) && url.pathExtension.lowercased() != "xml" && track(atPath: url.path) == nil
            }
            if !playlistFiles.isEmpty { importM3U(playlistFiles) }
            if let library = libraryFiles.first { importLibraryXML(library) }
            if !others.isEmpty { addToLibrary(others) }
        }
        return true
    }

    // MARK: Helpers

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    /// A playlist name as a file name (no slashes or colons).
    private static func fileName(for name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Playlist" : cleaned
    }

    private static func accessory(label: String, control: NSView) -> NSView {
        let stack = NSStackView(views: [NSTextField(labelWithString: label), control])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        return stack
    }
}
