import AppKit
import SwiftUI

/// The main track list.
///
/// An AppKit `NSTableView` rather than SwiftUI's `Table`: `Table` diffs and animates row changes
/// one by one, which hung for minutes going from a few hundred rows to 50k. Here a new row set is a
/// plain `reloadData()`, which only builds the rows on screen, and the table view itself survives,
/// so scroll position and keyboard focus do too.
struct TrackTableView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Read everything here, in `body`, so Observation tracks it and SwiftUI calls updateNSView.
        TrackTable(
            model: model,
            tracks: model.visibleTracks,
            sortOrder: model.sortOrder,
            sidebarSelection: model.selection,
            searchText: model.searchText,
            nowPlayingID: model.player.currentTrack?.id,
            isPlaying: model.player.isPlaying,
            selectedTrackIDs: model.selectedTrackIDs,
            libraryRevision: model.libraryRevision,
            canReorder: model.editablePlaylistID != nil && model.sortOrder.isEmpty && model.searchText.isEmpty,
            revealRequest: model.revealRequest,
            unavailable: model.unavailableTracks
        )
    }
}

private struct TrackTable: NSViewRepresentable {
    let model: AppModel
    let tracks: [Track]
    let sortOrder: [KeyPathComparator<Track>]
    let sidebarSelection: SidebarItem?
    let searchText: String
    let nowPlayingID: Int64?
    let isPlaying: Bool
    let selectedTrackIDs: Set<Int64>
    /// Bumped when track metadata changes in place (ratings, play counts, tag edits).
    let libraryRevision: Int
    /// Rows can be dragged to reorder: a regular playlist in its own order, unfiltered.
    let canReorder: Bool
    /// Go to Current Track: select and scroll to this track.
    let revealRequest: AppModel.RevealRequest?
    /// Tracks whose files can't be found, drawn dimmed with a warning sign.
    let unavailable: [Int64: MissingFiles.Status]

    func makeCoordinator() -> TrackTableCoordinator { TrackTableCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let tableView = TrackNSTableView()
        tableView.style = .inset
        // Fixed-height rows. With automatic row heights AppKit sizes rows one by one with Auto Layout
        // (`_doAutomaticRowHeightsForInsertedAndVisibleRows`), which hung the app at 50k rows.
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        for spec in TrackColumn.all {
            tableView.addTableColumn(spec.makeTableColumn())
        }
        // Right-click the header to choose columns.
        let headerMenu = NSMenu()
        headerMenu.delegate = coordinator
        tableView.headerView?.menu = headerMenu
        // After the columns exist: restores (and from now on saves) their widths and order.
        tableView.autosaveName = "TrackTable"
        tableView.autosaveTableColumns = true

        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(TrackTableCoordinator.doubleClicked(_:))
        tableView.onReturn = { [weak coordinator] in coordinator?.playSelection() }
        tableView.onSpace = { [weak coordinator] in coordinator?.model?.player.togglePlayPause() }
        // Rows drag out as files (Finder, other apps) and as track IDs (sidebar playlists, reordering).
        tableView.registerForDraggedTypes([TrackTableCoordinator.trackIDsType])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .gap
        let menu = NSMenu()
        menu.delegate = coordinator
        tableView.menu = menu
        coordinator.tableView = tableView

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }
}

// MARK: - Coordinator

@MainActor
private final class TrackTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// Pasteboard type carrying one track ID (decimal string) per dragged row.
    static let trackIDsType = NSPasteboard.PasteboardType("io.github.432meadow.susurrus.track-ids")

    weak var tableView: NSTableView?
    private(set) var model: AppModel?

    private var tracks: [Track] = []
    /// First row of each track, built on demand after a reload (a playlist can list a track twice).
    private var cachedRowsByID: [Int64: Int]?
    /// Tracks the user selected, by ID, so the selection survives reloads that move rows around.
    private var selectedIDs = Set<Int64>()
    private var nowPlayingID: Int64?
    private var isPlaying = false
    private var sidebarSelection: SidebarItem?
    private var searchText = ""
    private var hasLoaded = false
    /// `model.selectedTrackIDs` as of the last update, to tell the model's own changes from echoes of ours.
    private var lastModelSelection = Set<Int64>()
    private var libraryRevision = 0
    private var canReorder = false
    private var lastRevealToken: Int?
    private var unavailable: [Int64: MissingFiles.Status] = [:]
    private var draggedRows = IndexSet()
    /// Set while we change the table ourselves, so its delegate callbacks don't write back to the model.
    private var isApplyingChanges = false

    func update(from table: TrackTable) {
        model = table.model
        let sidebarChanged = !hasLoaded || table.sidebarSelection != sidebarSelection
        let searchChanged = table.searchText != searchText
        sidebarSelection = table.sidebarSelection
        searchText = table.searchText
        hasLoaded = true

        let oldNowPlayingID = nowPlayingID
        let nowPlayingChanged = table.nowPlayingID != nowPlayingID || table.isPlaying != isPlaying
        nowPlayingID = table.nowPlayingID
        isPlaying = table.isPlaying

        // Menu commands and other views can change the selection too.
        let modelSelectionChanged = table.selectedTrackIDs != lastModelSelection
        lastModelSelection = table.selectedTrackIDs
        if modelSelectionChanged {
            selectedIDs = table.selectedTrackIDs
        }
        let revisionChanged = table.libraryRevision != libraryRevision
        libraryRevision = table.libraryRevision
        canReorder = table.canReorder
        unavailable = table.unavailable

        // Identity, not content: a cheap pointer walk even at 50k rows.
        let tracksChanged = table.tracks.count != tracks.count || !table.tracks.elementsEqual(tracks, by: ===)
        if tracksChanged {
            // A new sidebar item starts fresh; search and sort keep whatever is still selected.
            reload(table.tracks, keepSelection: !sidebarChanged, scrollToTop: sidebarChanged || searchChanged)
        } else {
            if modelSelectionChanged {
                applySelection(scrollToIt: true)
            }
            if revisionChanged {
                repaintLoadedRows()
            } else if nowPlayingChanged {
                repaintNowPlaying(ids: [oldNowPlayingID, nowPlayingID])
            }
        }
        syncSortIndicators(with: table.sortOrder)
        if let request = table.revealRequest, request.token != lastRevealToken {
            lastRevealToken = request.token
            reveal(request.trackID)
        }
    }

    /// Selects a track's row and scrolls it to the middle of the view.
    private func reveal(_ trackID: Int64) {
        guard let tableView, let row = rowsByID[trackID], let scrollView = tableView.enclosingScrollView else { return }
        selectedIDs = [trackID]
        isApplyingChanges = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingChanges = false
        let clipView = scrollView.contentView
        var bounds = clipView.bounds
        bounds.origin.y = tableView.rect(ofRow: row).midY - bounds.height / 2
        clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clipView)
        tableView.window?.makeFirstResponder(tableView)
        if model?.selectedTrackIDs != selectedIDs {
            let ids = selectedIDs
            DispatchQueue.main.async { [weak self] in self?.model?.selectedTrackIDs = ids }
        }
    }

    // MARK: Reloading

    private func reload(_ newTracks: [Track], keepSelection: Bool, scrollToTop: Bool) {
        guard let tableView, let scrollView = tableView.enclosingScrollView else {
            tracks = newTracks
            cachedRowsByID = nil
            return
        }
        let clipView = scrollView.contentView

        // Remember where the selection sits on screen so it can be put back in the same place.
        var anchor: (id: Int64, offset: CGFloat?)?
        if keepSelection {
            let selected = tableView.selectedRowIndexes
            let visible = tableView.rows(in: clipView.documentVisibleRect)
            if let row = selected.first(where: { visible.contains($0) }) ?? selected.first, row < tracks.count {
                let offset = visible.contains(row) ? tableView.rect(ofRow: row).minY - clipView.bounds.minY : nil
                anchor = (tracks[row].id, offset)
            }
        } else {
            selectedIDs = []
        }

        tracks = newTracks
        cachedRowsByID = nil
        isApplyingChanges = true
        tableView.reloadData()
        tableView.deselectAll(nil)
        isApplyingChanges = false
        applySelection(scrollToIt: false)

        if let anchor, let row = rowsByID[anchor.id] {
            if let offset = anchor.offset {
                var bounds = clipView.bounds
                bounds.origin.y = tableView.rect(ofRow: row).minY - offset
                clipView.scroll(to: clipView.constrainBoundsRect(bounds).origin)
                scrollView.reflectScrolledClipView(clipView)
            } else {
                tableView.scrollRowToVisible(row)
            }
        } else if scrollToTop, !tracks.isEmpty {
            tableView.scrollRowToVisible(0)
        }
    }

    /// Selects the rows of `selectedIDs`, drops IDs that aren't listed, and hands the result to the model.
    private func applySelection(scrollToIt: Bool) {
        guard let tableView else { return }
        let current = Set(tableView.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0].id : nil })
        if current != selectedIDs {
            let rows = IndexSet(selectedIDs.compactMap { rowsByID[$0] })
            isApplyingChanges = true
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
            isApplyingChanges = false
            if scrollToIt, let first = rows.first {
                tableView.scrollRowToVisible(first)
            }
            selectedIDs = Set(rows.map { tracks[$0].id })
        }
        guard let model, model.selectedTrackIDs != selectedIDs else { return }
        // Not during SwiftUI's view update: publish the pruned selection right after it.
        let ids = selectedIDs
        DispatchQueue.main.async { [weak self] in
            guard self?.selectedIDs == ids else { return }  // the user has moved on since
            model.selectedTrackIDs = ids
        }
    }

    private var rowsByID: [Int64: Int] {
        if let cachedRowsByID { return cachedRowsByID }
        var result = [Int64: Int](minimumCapacity: tracks.count)
        for (row, track) in tracks.enumerated() where result[track.id] == nil {
            result[track.id] = row
        }
        cachedRowsByID = result
        return result
    }

    /// Redraws only the now-playing cells of the rows that gained or lost the indicator.
    private func repaintNowPlaying(ids: [Int64?]) {
        guard let tableView else { return }
        let ids = Set(ids.compactMap { $0 })
        guard !ids.isEmpty else { return }
        let column = tableView.column(withIdentifier: TrackColumn.nowPlayingID)
        guard column >= 0 else { return }
        let rows = IndexSet(tracks.indices.filter { ids.contains(tracks[$0].id) })
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: column))
    }

    /// Track metadata changed in place: rebuild the cells AppKit currently holds, not the whole table.
    private func repaintLoadedRows() {
        guard let tableView, tableView.numberOfColumns > 0 else { return }
        var rows = IndexSet()
        tableView.enumerateAvailableRowViews { _, row in
            if row >= 0 { rows.insert(row) }
        }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    // MARK: Sorting

    private func syncSortIndicators(with sortOrder: [KeyPathComparator<Track>]) {
        guard let tableView else { return }
        let descriptors = sortOrder.compactMap { comparator in
            TrackColumn.all.first { $0.sortKey == comparator.keyPath }.map {
                NSSortDescriptor(key: $0.id.rawValue, ascending: comparator.order == .forward)
            }
        }
        guard descriptors != tableView.sortDescriptors else { return }
        isApplyingChanges = true
        tableView.sortDescriptors = descriptors
        isApplyingChanges = false
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingChanges, let model else { return }
        model.sortOrder = tableView.sortDescriptors.compactMap { descriptor in
            TrackColumn.all.first { $0.id.rawValue == descriptor.key }?.comparator?(descriptor.ascending ? .forward : .reverse)
        }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        tracks.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let spec = TrackColumn.byID[tableColumn.identifier], tracks.indices.contains(row) else { return nil }
        let track = tracks[row]
        let id = tableColumn.identifier
        switch spec.content {
        case .nowPlaying:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NowPlayingCell ?? NowPlayingCell(identifier: id)
            if track.id == nowPlayingID {
                cell.symbol = isPlaying ? "speaker.wave.2.fill" : "speaker.fill"
                cell.toolTip = nil
            } else if let status = unavailable[track.id] {
                cell.symbol = status == .missing ? "exclamationmark.triangle" : "externaldrive.badge.xmark"
                cell.toolTip = status == .missing
                    ? "The file can't be found. Right-click ▸ Locate File… to point susurrus at it."
                    : "The file's volume isn't connected."
            } else {
                cell.symbol = nil
                cell.toolTip = nil
            }
            return cell
        case .rating:
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? RatingCell ?? RatingCell(identifier: id)
            cell.rating = track.rating
            cell.onRate = { [weak self] rating in
                self?.model?.setRating(rating, for: [track])
            }
            return cell
        case .text(let text, let alignment, let monospacedDigits):
            let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TextCell
                ?? TextCell(identifier: id, alignment: alignment, monospacedDigits: monospacedDigits)
            cell.textField?.stringValue = text(track)
            cell.textField?.textColor = unavailable[track.id] == nil ? .labelColor : .tertiaryLabelColor
            return cell
        }
    }

    /// Type-to-select matches the column the list is sorted by (text columns), else the title.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard tracks.indices.contains(row) else { return nil }
        let sortKey = tableView.sortDescriptors.first?.key
        let spec = sortKey.flatMap { TrackColumn.byID[NSUserInterfaceItemIdentifier($0)] }
        if let spec, case .text(let text, _, _) = spec.content {
            return text(tracks[row])
        }
        return tracks[row].title
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingChanges, let tableView else { return }
        selectedIDs = Set(tableView.selectedRowIndexes.compactMap { $0 < tracks.count ? tracks[$0].id : nil })
        model?.selectedTrackIDs = selectedIDs
    }

    // MARK: Dragging

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tracks.indices.contains(row) else { return nil }
        let track = tracks[row]
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: track.path).absoluteString, forType: .fileURL)
        item.setString(String(track.id), forType: Self.trackIDsType)
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedRows = rowIndexes
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedRows = []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Only reordering rows of this table; adding to playlists happens in the sidebar.
        guard canReorder, info.draggingSource as? NSTableView === tableView, !draggedRows.isEmpty else { return [] }
        if dropOperation == .on {
            tableView.setDropRow(row, dropOperation: .above)
        }
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard canReorder, let model else { return false }
        let moved = draggedRows.filter { $0 < tracks.count }.map { tracks[$0] }
        guard !moved.isEmpty else { return false }
        // Rows are playlist positions here (no sort, no search), and the drop row uses the same
        // "insert before, counted before removal" convention as `Array.move(fromOffsets:toOffset:)`.
        model.moveInCurrentPlaylist(moved, toPosition: row)
        return true
    }

    // MARK: Actions

    @objc func doubleClicked(_ sender: NSTableView) {
        let row = sender.clickedRow  // -1 for a double-click on the header or below the last row
        guard tracks.indices.contains(row) else { return }
        model?.play(tracks[row])
    }

    func playSelection() {
        play(tableView?.selectedRowIndexes ?? [])
    }

    /// Starts from the topmost row so the queue continues down the list.
    private func play(_ rows: IndexSet) {
        guard let row = rows.first, tracks.indices.contains(row) else { return }
        model?.play(tracks[row])
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let tableView else { return }
        if menu === tableView.headerView?.menu {
            buildColumnsMenu(menu, tableView: tableView)
            return
        }
        // Like Finder: right-clicking inside the selection acts on all of it, outside just on that row.
        let clicked = tableView.clickedRow
        guard tracks.indices.contains(clicked) else { return }
        guard let model else { return }
        let rows = tableView.selectedRowIndexes.contains(clicked) ? tableView.selectedRowIndexes : IndexSet(integer: clicked)
        let shared = TrackMenu.make(for: Set(rows.map { tracks[$0].id }), model: model)
        for item in shared.items {
            shared.removeItem(item)
            menu.addItem(item)
        }
    }
}

// MARK: - Choosing columns

extension TrackTableCoordinator {
    fileprivate func buildColumnsMenu(_ menu: NSMenu, tableView: NSTableView) {
        let visibleCount = tableView.tableColumns.filter { !$0.isHidden && $0.identifier != TrackColumn.nowPlayingID }.count
        for spec in TrackColumn.all where spec.id != TrackColumn.nowPlayingID {
            guard let column = tableView.tableColumn(withIdentifier: spec.id) else { continue }
            let item = ClosureMenuItem(spec.title, state: column.isHidden ? .off : .on) { [weak tableView] in
                guard let tableView else { return }
                column.isHidden.toggle()
                if !column.isHidden, column.width < spec.minWidth { column.width = spec.width }
                tableView.sizeLastColumnToFit()
            }
            // Keep at least one column.
            item.isEnabled = column.isHidden || visibleCount > 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Show Default Columns") { [weak tableView] in
            guard let tableView else { return }
            for spec in TrackColumn.all {
                guard let column = tableView.tableColumn(withIdentifier: spec.id) else { continue }
                column.isHidden = spec.hiddenByDefault
                column.width = spec.width
            }
        })
    }
}

// MARK: - Columns

@MainActor
private struct TrackColumn {
    enum Content {
        case nowPlaying
        case rating
        case text((Track) -> String, alignment: NSTextAlignment = .natural, monospacedDigits: Bool = false)
    }

    let id: NSUserInterfaceItemIdentifier
    let title: String
    let width: CGFloat
    let minWidth: CGFloat
    var maxWidth: CGFloat = .greatestFiniteMagnitude
    /// Flexible columns share out the space when the window resizes; the rest keep their width.
    var flexible = false
    var content: Content
    var sortKey: PartialKeyPath<Track>?
    var comparator: ((SortOrder) -> KeyPathComparator<Track>)?
    /// Which way the first click on the header sorts.
    var ascendingFirst = true
    /// Off until chosen from the header's menu.
    var hiddenByDefault = false

    static let nowPlayingID = NSUserInterfaceItemIdentifier("nowPlaying")
    private static let dateStyle = Date.FormatStyle(date: .numeric, time: .omitted)

    // The `KeyPathComparator` initializers are spelled out per column so String columns get the
    // localized-standard comparison, like SwiftUI's `TableColumn(_:value:)`.
    static let all: [TrackColumn] = [
        TrackColumn(id: nowPlayingID, title: "", width: 18, minWidth: 18, maxWidth: 18, content: .nowPlaying),
        TrackColumn(
            id: .init("title"), title: "Title", width: 240, minWidth: 60, flexible: true, content: .text { $0.title },
            sortKey: \Track.title, comparator: { KeyPathComparator(\Track.title, order: $0) }
        ),
        TrackColumn(
            id: .init("artist"), title: "Artist", width: 170, minWidth: 50, flexible: true, content: .text { $0.displayArtist },
            sortKey: \Track.artist, comparator: { KeyPathComparator(\Track.artist, order: $0) }
        ),
        TrackColumn(
            id: .init("album"), title: "Album", width: 190, minWidth: 50, flexible: true, content: .text { $0.album },
            sortKey: \Track.album, comparator: { KeyPathComparator(\Track.album, order: $0) }
        ),
        TrackColumn(
            id: .init("genre"), title: "Genre", width: 100, minWidth: 40, flexible: true, content: .text { $0.genre },
            sortKey: \Track.genre, comparator: { KeyPathComparator(\Track.genre, order: $0) }
        ),
        TrackColumn(
            id: .init("time"), title: "Time", width: 52, minWidth: 44,
            content: .text({ Format.time($0.length) }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.length, comparator: { KeyPathComparator(\Track.length, order: $0) }
        ),
        TrackColumn(
            id: .init("bpm"), title: "BPM", width: 40, minWidth: 32,
            content: .text({ $0.bpm > 0 ? String($0.bpm) : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.bpm, comparator: { KeyPathComparator(\Track.bpm, order: $0) }
        ),
        TrackColumn(
            id: .init("key"), title: "Key", width: 58, minWidth: 34,
            content: .text({ $0.key?.label ?? $0.musicalKey }),
            sortKey: \Track.keySortKey, comparator: { KeyPathComparator(\Track.keySortKey, order: $0) }
        ),
        TrackColumn(
            id: .init("year"), title: "Year", width: 44, minWidth: 36,
            content: .text({ $0.year > 0 ? String($0.year) : "" }, monospacedDigits: true),
            sortKey: \Track.year, comparator: { KeyPathComparator(\Track.year, order: $0) }
        ),
        TrackColumn(
            id: .init("rating"), title: "Rating", width: 72, minWidth: 60, content: .rating,
            sortKey: \Track.rating, comparator: { KeyPathComparator(\Track.rating, order: $0) }, ascendingFirst: false
        ),
        TrackColumn(
            id: .init("plays"), title: "Plays", width: 44, minWidth: 36,
            content: .text({ $0.playCount > 0 ? "\($0.playCount)" : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.playCount, comparator: { KeyPathComparator(\Track.playCount, order: $0) }, ascendingFirst: false
        ),
        TrackColumn(
            id: .init("skips"), title: "Skips", width: 44, minWidth: 36,
            content: .text({ $0.skipCount > 0 ? "\($0.skipCount)" : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.skipCount, comparator: { KeyPathComparator(\Track.skipCount, order: $0) }, ascendingFirst: false,
            hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("dateAdded"), title: "Date Added", width: 90, minWidth: 70,
            content: .text { $0.dateAdded?.formatted(dateStyle) ?? "" },
            sortKey: \Track.dateAddedSortKey, comparator: { KeyPathComparator(\Track.dateAddedSortKey, order: $0) },
            ascendingFirst: false
        ),
        TrackColumn(
            id: .init("albumArtist"), title: "Album Artist", width: 150, minWidth: 50, flexible: true, content: .text { $0.albumArtist },
            sortKey: \Track.albumArtist, comparator: { KeyPathComparator(\Track.albumArtist, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("composer"), title: "Composer", width: 140, minWidth: 50, flexible: true, content: .text { $0.composer },
            sortKey: \Track.composer, comparator: { KeyPathComparator(\Track.composer, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("grouping"), title: "Grouping", width: 110, minWidth: 40, flexible: true, content: .text { $0.grouping },
            sortKey: \Track.grouping, comparator: { KeyPathComparator(\Track.grouping, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("comment"), title: "Comment", width: 160, minWidth: 50, flexible: true, content: .text { $0.comment },
            sortKey: \Track.comment, comparator: { KeyPathComparator(\Track.comment, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("trackNumber"), title: "#", width: 32, minWidth: 26,
            content: .text({ $0.trackNumber > 0 ? String($0.trackNumber) : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.trackNumber, comparator: { KeyPathComparator(\Track.trackNumber, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("discNumber"), title: "Disc", width: 36, minWidth: 30,
            content: .text({ $0.discNumber > 0 ? String($0.discNumber) : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.discNumber, comparator: { KeyPathComparator(\Track.discNumber, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("lastPlayed"), title: "Last Played", width: 90, minWidth: 70,
            content: .text { $0.lastPlayed?.formatted(dateStyle) ?? "" },
            sortKey: \Track.lastPlayedSortKey, comparator: { KeyPathComparator(\Track.lastPlayedSortKey, order: $0) },
            ascendingFirst: false, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("kind"), title: "Kind", width: 48, minWidth: 36, content: .text { $0.fileType },
            sortKey: \Track.fileType, comparator: { KeyPathComparator(\Track.fileType, order: $0) }, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("bitRate"), title: "Bit Rate", width: 64, minWidth: 44,
            content: .text({ $0.bitRate > 0 ? "\($0.bitRate) kbps" : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.bitRate, comparator: { KeyPathComparator(\Track.bitRate, order: $0) },
            ascendingFirst: false, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("sampleRate"), title: "Sample Rate", width: 74, minWidth: 50,
            content: .text({ $0.sampleRate > 0 ? Format.sampleRate($0.sampleRate) : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.sampleRate, comparator: { KeyPathComparator(\Track.sampleRate, order: $0) },
            ascendingFirst: false, hiddenByDefault: true
        ),
        TrackColumn(
            id: .init("size"), title: "Size", width: 64, minWidth: 44,
            content: .text({ $0.fileSize > 0 ? ByteCountFormatter.string(fromByteCount: $0.fileSize, countStyle: .file) : "" }, alignment: .right, monospacedDigits: true),
            sortKey: \Track.fileSize, comparator: { KeyPathComparator(\Track.fileSize, order: $0) },
            ascendingFirst: false, hiddenByDefault: true
        ),
    ]

    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = minWidth
        column.maxWidth = maxWidth
        column.resizingMask = flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        if case .text(_, let alignment, _) = content {
            column.headerCell.alignment = alignment
        }
        if comparator != nil {
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: ascendingFirst)
        }
        if case .nowPlaying = content {
            column.headerToolTip = "Now Playing"
        }
        column.isHidden = hiddenByDefault  // the autosaved state, if any, wins
        return column
    }
}

// MARK: - Cells

private final class TrackNSTableView: NSTableView, HandlesSpaceKey {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    /// When the last letter was typed: a space right after one belongs to type-to-select
    /// ("the b…"), not to play/pause.
    private var lastTypedAt: Date?

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            return super.keyDown(with: event)
        }
        switch event.keyCode {
        case 36, 76:  // Return, keypad Enter
            onReturn?()
        case 49:  // Space
            if let lastTypedAt, Date().timeIntervalSince(lastTypedAt) < 1 {
                self.lastTypedAt = Date()
                super.keyDown(with: event)
            } else {
                onSpace?()
            }
        default:
            if event.characters?.first.map({ $0.isLetter || $0.isNumber }) == true { lastTypedAt = Date() }
            super.keyDown(with: event)
        }
    }

    /// NSTableView keeps mouse-downs for itself unless the view under the pointer is approved here.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if let cell = responder as? RatingCell, let event {
            return cell.rating(for: event) != nil
        }
        return super.validateProposedFirstResponder(responder, for: event)
    }
}

private final class TextCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment, monospacedDigits: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        let size = NSFont.systemFontSize
        field.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class NowPlayingCell: NSTableCellView {
    private let icon = NSImageView()

    var symbol: String? {
        didSet {
            guard symbol != oldValue else { return }
            icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: Self.description(of: $0)) }
        }
    }

    /// What VoiceOver says for each mark the column shows.
    private static func description(of symbol: String) -> String {
        switch symbol {
        case "exclamationmark.triangle": "File missing"
        case "externaldrive.badge.xmark": "Volume not mounted"
        case "speaker.fill": "Now playing, paused"
        default: "Now playing"
        }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    /// Accent colour, except on the accent-coloured selection highlight.
    private func updateTint() {
        icon.contentTintColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : Palette.warmNS
    }
}

/// Five stars in half-star steps, like `RatingView`, drawn directly so scrolling stays cheap.
private final class RatingCell: NSTableCellView {
    var rating = 0.0 {
        didSet {
            guard rating != oldValue else { return }
            setAccessibilityLabel(rating > 0 ? "\(rating.formatted()) stars" : nil)
            needsDisplay = true
        }
    }
    /// Called with the clicked rating (0–5 in halves; 0 when the current rating is clicked again).
    var onRate: ((Double) -> Void)?

    private static let inset: CGFloat = 2
    private static let starSlot = (NSImage(systemSymbolName: "star", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))?.size.width ?? 10) + 1

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { needsDisplay = true }
    }

    /// The rating a click sets, or nil when the click should just select the row as usual.
    /// Only a selected row's stars take clicks, so clicking around the list never rates by accident.
    func rating(for event: NSEvent) -> Double? {
        let x = convert(event.locationInWindow, from: nil).x - Self.inset
        guard onRate != nil, (superview as? NSTableRowView)?.isSelected == true,
              event.type == .leftMouseDown, event.clickCount == 1, x >= 0, x < Self.starSlot * 5 else { return nil }
        // The left half of a star gives a half star; clicking the current rating clears it.
        let value = min(5, ((x / Self.starSlot) * 2).rounded(.up) / 2)
        return value == rating ? 0 : value
    }

    override func mouseDown(with event: NSEvent) {
        guard let value = rating(for: event) else { return super.mouseDown(with: event) }
        onRate?(value)
    }

    override func draw(_ dirtyRect: NSRect) {
        // An unrated track shows empty stars on the selected row, which is where they take clicks.
        let isSelected = (superview as? NSTableRowView)?.isSelected == true
        guard rating > 0 || (isSelected && onRate != nil) else { return }
        let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor
            : rating > 0 ? .secondaryLabelColor : .tertiaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
            .applying(.init(paletteColors: [color]))
        var x = Self.inset
        for star in 0..<5 {
            guard let image = NSImage(systemSymbolName: RatingView.symbol(for: star, rating: rating), accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { continue }
            let size = image.size
            image.draw(in: NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height))
            x += Self.starSlot
        }
    }
}

// MARK: - Shared with the album view

struct RatingView: View {
    let rating: Double

    var body: some View {
        if rating > 0 {
            HStack(spacing: 1) {
                ForEach(0..<5) { star in
                    Image(systemName: Self.symbol(for: star, rating: rating))
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(rating.formatted()) stars")
        }
    }

    static func symbol(for star: Int, rating: Double) -> String {
        let value = rating - Double(star)
        if value >= 1 { return "star.fill" }
        if value >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

enum Format {
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// "44.1 kHz", "48 kHz".
    static func sampleRate(_ hertz: Int) -> String {
        let kHz = Double(hertz) / 1000
        return (kHz == kHz.rounded() ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)) + " kHz"
    }
}
