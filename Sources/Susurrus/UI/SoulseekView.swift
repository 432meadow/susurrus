import SwiftUI

/// Soulseek: Search (query field, live results), Wishlist (saved searches repeated in the
/// background), Browse (one user's whole share), Messages (private conversations) and
/// Downloads (transfers in both directions).
struct SoulseekView: View {
    typealias Pane = SoulseekModel.Pane

    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selectedWishlistQuery: String?
    @State private var newWishlistQuery = ""
    @State private var newConversationUser = ""

    private var soulseek: SoulseekModel { model.soulseek }
    private var pane: Pane { soulseek.pane }

    var body: some View {
        if !soulseek.hasCredentials {
            ContentUnavailableView {
                Label("Soulseek", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Enter your Soulseek username and password in Settings. A new username is registered on the network the first time it connects.")
            } actions: {
                Button("Open Settings…") { openSettings() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            @Bindable var soulseek = soulseek
            VStack(spacing: 0) {
                topBar
                Divider()
                if pane != .downloads, pane != .messages {
                    ResultFilterBar(showsSlotFilter: pane != .browse, showsGrouping: pane != .browse)
                    Divider()
                }
                // Fill the rest of the pane so the bar stays pinned to the top; an empty state on
                // its own sizes to fit, which centered the whole stack vertically.
                Group {
                    switch pane {
                    case .search:
                        resultsArea
                    case .wishlist:
                        wishlistPane
                    case .browse:
                        BrowsePane()
                    case .messages:
                        MessagesPane()
                    case .downloads:
                        TransfersList()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .sheet(item: $soulseek.userSheet) { sheet in
                UserInfoSheet(user: sheet.user)
            }
        }
    }

    private var topBar: some View {
        @Bindable var soulseek = soulseek
        return HStack(spacing: 12) {
            Picker("", selection: $soulseek.pane) {
                Text("Search").tag(Pane.search)
                Text(soulseek.wishlistNewTotal > 0 ? "Wishlist (\(soulseek.wishlistNewTotal))" : "Wishlist").tag(Pane.wishlist)
                Text("Browse").tag(Pane.browse)
                Text(soulseek.chats.unreadTotal > 0 ? "Messages (\(soulseek.chats.unreadTotal))" : "Messages").tag(Pane.messages)
                Text(downloadsTabLabel).tag(Pane.downloads)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch pane {
            case .search:
                TextField("Search Soulseek", text: $soulseek.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                    .onSubmit { soulseek.search() }
                Button("Search") { soulseek.search() }
                    .disabled(soulseek.query.trimmingCharacters(in: .whitespaces).isEmpty)
                if let query = soulseek.activeQuery {
                    Button {
                        soulseek.addToWishlist(query)
                        selectedWishlistQuery = query
                    } label: {
                        Image(systemName: soulseek.wishlist.contains(query) ? "star.fill" : "star")
                    }
                    .buttonStyle(.borderless)
                    .help(soulseek.wishlist.contains(query) ? "In the wishlist" : "Add “\(query)” to the wishlist: it's searched again every so often and you're told about new results")
                    .disabled(soulseek.wishlist.contains(query))
                }
            case .wishlist:
                TextField("Add a saved search", text: $newWishlistQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(addWishlistQuery)
                Button("Add", action: addWishlistQuery)
                    .disabled(newWishlistQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            case .browse:
                TextField("Username", text: $soulseek.browseUser)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { soulseek.browse(user: soulseek.browseUser) }
                Button("Browse") { soulseek.browse(user: soulseek.browseUser) }
                    .disabled(soulseek.browseUser.trimmingCharacters(in: .whitespaces).isEmpty)
            case .messages:
                TextField("Username", text: $newConversationUser)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(startConversation)
                Button("Message", action: startConversation)
                    .disabled(newConversationUser.trimmingCharacters(in: .whitespaces).isEmpty)
            case .downloads:
                Picker("Sort", selection: $soulseek.downloadSort) {
                    ForEach(SoulseekModel.DownloadSort.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Button("Cancel All…") { soulseek.confirmCancelAll() }
                    .disabled(soulseek.activeDownloadCount == 0)
                Button("Clear Finished") { soulseek.clearInactiveDownloads() }
                    .disabled(!soulseek.hasInactiveDownloads)
            }
            Spacer()
            statusLabel
        }
        .padding(10)
    }

    private func addWishlistQuery() {
        let query = newWishlistQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        soulseek.addToWishlist(query)
        selectedWishlistQuery = query
        newWishlistQuery = ""
    }

    private func startConversation() {
        soulseek.message(newConversationUser)
        newConversationUser = ""
    }

    private var downloadsTabLabel: String {
        let active = soulseek.activeDownloadCount
        return active > 0 ? "Downloads (\(active))" : "Downloads"
    }

    private var statusLabel: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusTextWithCounts)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(soulseek.statusText)
    }

    private var statusColor: Color {
        switch soulseek.state {
        case .connected: Palette.warm
        case .connecting: Palette.ochre
        case .disconnected: .secondary.opacity(0.5)
        case .failed: Palette.error
        }
    }

    private var statusTextWithCounts: String {
        if pane == .search, soulseek.activeQuery != nil, !soulseek.results.isEmpty {
            return "\(soulseek.results.count.formatted()) files from \(soulseek.resultUserCount) users · \(soulseek.statusText)"
        }
        return soulseek.statusText
    }

    @ViewBuilder private var resultsArea: some View {
        if soulseek.activeQuery == nil {
            ContentUnavailableView(
                "Search Soulseek",
                systemImage: "magnifyingglass",
                description: Text("Results come straight from other users on the network, so they can take a few seconds to trickle in.")
            )
        } else if soulseek.results.isEmpty {
            searchingPlaceholder
        } else {
            ResultsTable(rows: soulseek.resultRows, version: "search \(soulseek.resultsVersion)")
        }
    }

    @ViewBuilder private var searchingPlaceholder: some View {
        let query = soulseek.activeQuery ?? ""
        if case .failed(let reason) = soulseek.state {
            ContentUnavailableView("Can't Search", systemImage: "exclamationmark.triangle", description: Text(reason))
        } else if soulseek.searchFoundNothing {
            ContentUnavailableView {
                Label("No Results Yet", systemImage: "magnifyingglass")
            } description: {
                Text("Nobody has answered “\(query)” so far. Late answers still show up here — or add it to the wishlist, and susurrus keeps looking in the background.")
            } actions: {
                Button("Search Again") { soulseek.searchAgain() }
                Button("Add to Wishlist") {
                    soulseek.addToWishlist(query)
                    selectedWishlistQuery = query
                }
                .disabled(soulseek.wishlist.contains { $0.caseInsensitiveCompare(query) == .orderedSame })
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching for “\(query)”…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Wishlist tab

    @ViewBuilder private var wishlistPane: some View {
        if soulseek.wishlist.isEmpty {
            ContentUnavailableView(
                "No Saved Searches",
                systemImage: "star",
                description: Text("Add a search here (or with the star next to a search) and susurrus repeats it in the background while connected, telling you when something new turns up.")
            )
        } else {
            HSplitView {
                List(selection: $selectedWishlistQuery) {
                    ForEach(soulseek.wishlist, id: \.self) { query in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(query).lineLimit(1)
                            Text(wishlistSubtitle(for: query))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .badge(soulseek.wishlistNewCounts[query] ?? 0)
                        .tag(query)
                        .contextMenu {
                            Button("Search Now") { soulseek.searchWishlistItem(query) }
                                .disabled(soulseek.state == .disconnected)
                            Button("Remove", role: .destructive) {
                                soulseek.removeFromWishlist(query)
                                if selectedWishlistQuery == query { selectedWishlistQuery = nil }
                            }
                        }
                    }
                }
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                Group {
                    if let query = selectedWishlistQuery, soulseek.wishlist.contains(query) {
                        if let rows = soulseek.wishlistRows[query], !rows.isEmpty {
                            ResultsTable(rows: rows, version: "wishlist \(soulseek.wishlistVersion) \(query)")
                        } else {
                            ContentUnavailableView(
                                "Nothing Yet",
                                systemImage: "hourglass",
                                description: Text(soulseek.state == .disconnected
                                    ? "Saved searches run while susurrus is connected to Soulseek."
                                    : "“\(query)” is searched again about every \(soulseek.wishlistInterval / 60) minutes, taking turns with the other saved searches.")
                            )
                        }
                    } else {
                        ContentUnavailableView("Choose a Saved Search", systemImage: "star")
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
            .onChange(of: selectedWishlistQuery) { _, query in
                if let query { soulseek.markWishlistSeen(query) }
            }
            .onChange(of: soulseek.wishlistNewCounts) { _, _ in
                if let query = selectedWishlistQuery { soulseek.markWishlistSeen(query) }
            }
        }
    }

    private func wishlistSubtitle(for query: String) -> String {
        let count = soulseek.wishlistResults[query]?.count ?? 0
        let found = count == 1 ? "1 result" : "\(count.formatted()) results"
        guard let date = soulseek.wishlistLastSearched[query] else { return "\(found) · not searched yet" }
        return "\(found) · searched \(date.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Downloads tab

/// Downloads (newest first or by folder) and uploads. Rows take the download itself and look up
/// actions through the model, so a progress update redraws only its own row.
private struct TransfersList: View {
    @Environment(AppModel.self) private var model

    private var soulseek: SoulseekModel { model.soulseek }

    var body: some View {
        if soulseek.downloads.isEmpty, soulseek.uploads.isEmpty {
            ContentUnavailableView(
                "No Transfers",
                systemImage: "arrow.up.arrow.down",
                description: Text("Files you download — and files other users fetch from your shared folder — show up here.")
            )
        } else {
            List {
                if !soulseek.downloads.isEmpty {
                    switch soulseek.downloadSort {
                    case .newestFirst:
                        Section("Downloads") {
                            ForEach(soulseek.downloads.reversed()) { download in
                                DownloadRow(download: download).equatable()
                            }
                        }
                    case .folder:
                        ForEach(soulseek.downloadFolders) { folder in
                            Section {
                                ForEach(folder.downloadIDs, id: \.self) { id in
                                    if let download = soulseek.download(withID: id) {
                                        DownloadRow(download: download).equatable()
                                    }
                                }
                            } header: {
                                DownloadFolderHeader(folder: folder).equatable()
                            }
                        }
                    }
                }
                if !soulseek.uploads.isEmpty {
                    Section {
                        ForEach(soulseek.uploads.reversed()) { upload in
                            UploadRow(upload: upload).equatable()
                        }
                    } header: {
                        HStack {
                            Text("Uploads")
                            Spacer()
                            Button("Clear Finished") { soulseek.clearInactiveUploads() }
                                .controlSize(.small)
                                .disabled(!soulseek.hasInactiveUploads)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .alert(
                soulseek.cancelRequest?.title ?? "",
                isPresented: Binding(
                    get: { soulseek.cancelRequest != nil },
                    set: { if !$0 { soulseek.cancelRequest = nil } }),
                presenting: soulseek.cancelRequest
            ) { request in
                Button(request.downloadIDs.count == 1 ? "Stop Download" : "Stop Downloads", role: .destructive) {
                    soulseek.cancel(request.downloadIDs)
                }
                Button("Keep Downloading", role: .cancel) {}
            } message: { _ in
                Text("What has arrived so far is deleted.")
            }
        }
    }
}

/// Section header for one folder when downloads are grouped: name, who it's from, and how far along.
private struct DownloadFolderHeader: View, Equatable {
    @Environment(AppModel.self) private var model
    let folder: SoulseekModel.DownloadFolder

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.folder == rhs.folder }

    var body: some View {
        HStack {
            Text(folder.name)
                .help(folder.url.path)
            Text("· \(folder.users.joined(separator: ", ")) · \(summary)")
                .foregroundStyle(.secondary)
            Spacer()
            if folder.activeCount > 0 {
                Button("Cancel Folder…") { model.soulseek.confirmCancelFolder(folder.url) }
                    .controlSize(.small)
            }
        }
        .lineLimit(1)
    }

    private var summary: String {
        let total = folder.downloadIDs.count
        let done = folder.finishedCount
        return done == total ? "\(total) \(total == 1 ? "file" : "files")" : "\(done) of \(total) done"
    }
}

/// One downloads-list row: name, status line, and a progress bar while transferring.
private struct DownloadRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let download: SoulseekDownload

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.download == rhs.download }

    private var soulseek: SoulseekModel { model.soulseek }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(download.fileName)
                    .lineLimit(1)
                    .help(download.remotePath.replacingOccurrences(of: "\\", with: " ▸ "))
                Text("\(download.username) · \(statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .transferring(let received, let total) = download.state {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }
            if download.isActive {
                Button {
                    soulseek.cancel([download.id])
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancel Download")
            }
        }
        .padding(.vertical, 2)
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if download.isActive {
            Button("Cancel") { soulseek.cancel([download.id]) }
            Button("Cancel Folder…") { soulseek.confirmCancelFolder(download.localURL.deletingLastPathComponent()) }
        }
        switch download.state {
        case .failed, .cancelled:
            Button("Retry") { soulseek.retry(download.id) }
        default:
            EmptyView()
        }
        if case .finished(let url) = download.state {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Look Up Album on MusicBrainz…") { model.lookUpDownload(folder: url.deletingLastPathComponent()) }
                .disabled(model.track(atPath: url.path) == nil)
        }
        if !download.isActive {
            Button("Remove") { soulseek.remove(download.id) }
        }
        Divider()
        SoulseekUserMenu(soulseek: soulseek, user: download.username)
    }

    private var icon: (name: String, color: Color) {
        switch download.state {
        case .connecting, .requested: ("arrow.down.circle.dotted", .secondary)
        case .queued: ("hourglass", .secondary)
        case .transferring: (("arrow.down.circle", Palette.cool))
        case .finished: (("checkmark.circle.fill", Palette.warm))
        case .failed: (("exclamationmark.triangle.fill", Palette.ochre))
        case .cancelled: ("xmark.circle", .secondary)
        }
    }

    private var statusText: String {
        switch download.state {
        case .connecting: "Connecting…"
        case .requested: "Waiting for the uploader…"
        case .queued(let place):
            place.map { "In queue (position \($0.formatted()))" } ?? "In queue"
        case .transferring(let received, let total):
            "\(byteCount(received)) of \(byteCount(total))"
        case .finished: "Done — added to the library"
        case .failed(let reason): reason
        case .cancelled: "Cancelled"
        }
    }
}

/// One uploads-list row: who is fetching what, with progress while sending.
private struct UploadRow: View, Equatable {
    @Environment(AppModel.self) private var model
    let upload: SoulseekUpload

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.upload == rhs.upload }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(upload.fileName)
                    .lineLimit(1)
                    .help(upload.remotePath.replacingOccurrences(of: "\\", with: " ▸ "))
                Text("to \(upload.username) · \(statusText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if case .transferring(let sent, let total) = upload.state {
                ProgressView(value: Double(sent), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 140)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            SoulseekUserMenu(soulseek: model.soulseek, user: upload.username)
        }
    }

    private var icon: (name: String, color: Color) {
        switch upload.state {
        case .waiting: ("hourglass", .secondary)
        case .transferring: (("arrow.up.circle", Palette.cool))
        case .finished: (("checkmark.circle.fill", Palette.warm))
        case .failed: (("exclamationmark.triangle.fill", Palette.ochre))
        }
    }

    private var statusText: String {
        switch upload.state {
        case .waiting: "Waiting for a slot…"
        case .transferring(let sent, let total):
            "\(byteCount(sent)) of \(byteCount(total))"
        case .finished: "Sent"
        case .failed(let reason): reason
        }
    }
}

/// A file size for display. Sizes come from peers, so huge ones are clamped rather than trusted.
private func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

// MARK: - Filters

/// Filter field, format and free-slot filters, and the group-by-folder switch.
private struct ResultFilterBar: View {
    @Environment(AppModel.self) private var model
    let showsSlotFilter: Bool
    let showsGrouping: Bool

    var body: some View {
        @Bindable var soulseek = model.soulseek
        HStack(spacing: 12) {
            TextField("Filter results (-word excludes)", text: $soulseek.filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Picker("Format", selection: $soulseek.formatFilter) {
                ForEach(SoulseekModel.FormatFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .fixedSize()
            if showsSlotFilter {
                Toggle("Free slot only", isOn: $soulseek.freeSlotsOnly)
            }
            Spacer()
            if showsGrouping {
                Toggle("Group by folder", isOn: $soulseek.groupByFolder)
            }
            if !soulseek.blockedUsers.isEmpty {
                Text("\(soulseek.blockedUsers.count) blocked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Blocked users' results are hidden. Manage the list in Settings ▸ Soulseek.")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Results table

/// One row of the results table: a file, or (grouped by folder) a remote folder holding files.
/// Everything shown is formatted once, when the row is made.
struct ResultRow: Identifiable {
    let id: String
    /// The files this row downloads: itself, or every file in the folder.
    let files: [SlskSearchResult]
    let isFolder: Bool
    var children: [ResultRow]?

    let name: String
    let folder: String
    let fullPath: String
    /// The remote folder (full path), for grouping.
    let parentPath: String
    /// The full path lowercased, for the filter.
    let searchText: String
    let qualityRank: Int
    let qualityText: String
    let duration: Int
    let durationText: String
    let size: UInt64
    let sizeText: String
    let username: String
    let availability: Int
    let availabilityText: String
    let slotFree: Bool
    let speed: UInt32
    let speedText: String

    init(file: SlskSearchResult) {
        id = "f\u{1}\(file.username)\u{1}\(file.path)"
        files = [file]
        isFolder = false
        name = file.fileName
        folder = file.folder.replacingOccurrences(of: "\\", with: " ▸ ")
        fullPath = file.path
        parentPath = file.parentPath
        searchText = file.path.lowercased()
        qualityRank = file.qualityRank
        qualityText = file.qualityDescription
        duration = file.durationSortValue
        durationText = file.durationText
        size = file.size
        sizeText = file.sizeText
        username = file.username
        availability = file.availability
        availabilityText = file.availabilityText
        slotFree = file.slotFree
        speed = file.averageSpeed
        speedText = file.speedText
    }

    /// A folder row over `rows`, the file rows of one user's remote folder.
    init(folderPath: String, rows: [ResultRow]) {
        let first = rows[0]
        id = "d\u{1}\(first.username)\u{1}\(folderPath)"
        files = rows.flatMap(\.files)
        isFolder = true
        let components = folderPath.split(separator: "\\")
        name = String(components.last ?? "")
        folder = components.dropLast().suffix(2).joined(separator: " ▸ ")
        fullPath = folderPath
        parentPath = String(components.dropLast().joined(separator: "\\"))
        searchText = folderPath.lowercased()
        let qualities = Set(rows.map(\.qualityText))
        qualityText = qualities.count == 1 ? first.qualityText : "Mixed"
        qualityRank = rows.map(\.qualityRank).min() ?? 0
        duration = rows.reduce(0) { $0 + $1.duration }
        durationText = duration > 0
            ? Duration.seconds(duration).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
            : "–"
        size = rows.reduce(UInt64(0)) { $0.saturatingAdd($1.size) }
        sizeText = byteCount(size)
        username = first.username
        availability = first.availability
        availabilityText = first.availabilityText
        slotFree = first.slotFree
        speed = first.speed
        speedText = first.speedText
        children = rows
    }
}

/// The rows a results table shows, kept between redraws: filtering, grouping and sorting a few
/// thousand results runs again only when the results, the filters or the order change.
@MainActor
private final class ResultRowCache {
    struct Key: Equatable {
        let version: String
        let filter: SoulseekModel.ResultFilter
        let grouped: Bool
        let sortOrder: [KeyPathComparator<ResultRow>]
    }

    private var key: Key?
    private var rows: [ResultRow] = []

    func rows(for key: Key, _ make: () -> [ResultRow]) -> [ResultRow] {
        if key != self.key {
            rows = make()
            self.key = key
        }
        return rows
    }
}

/// Search, wishlist and browse results: filtered, sortable, optionally grouped by folder, with
/// download and user actions.
struct ResultsTable: View {
    @Environment(AppModel.self) private var model
    /// File rows, one per result.
    let rows: [ResultRow]
    /// Changes whenever `rows` does.
    let version: String
    var allowsGrouping = true
    /// Browsed files carry no slot information, so the free-slot filter doesn't apply to them.
    var usesSlotFilter = true

    @State private var sortOrder = [
        KeyPathComparator(\ResultRow.availability),
        KeyPathComparator(\ResultRow.speed, order: .reverse),
    ]
    @State private var selection = Set<ResultRow.ID>()
    @State private var cache = ResultRowCache()

    private var soulseek: SoulseekModel { model.soulseek }

    var body: some View {
        var filter = soulseek.resultFilter
        if !usesSlotFilter { filter.freeSlotsOnly = false }
        let grouped = allowsGrouping && soulseek.groupByFolder
        let key = ResultRowCache.Key(version: version, filter: filter, grouped: grouped, sortOrder: sortOrder)
        let visible = cache.rows(for: key) { displayRows(filter: filter, grouped: grouped) }
        return Group {
            if visible.isEmpty {
                ContentUnavailableView(
                    "No Matching Results",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("\(rows.count.formatted()) results are hidden by the filters\(soulseek.blockedUsers.isEmpty ? "" : " or come from blocked users").")
                )
            } else {
                table(visible)
            }
        }
    }

    private func displayRows(filter: SoulseekModel.ResultFilter, grouped: Bool) -> [ResultRow] {
        let matching = rows.filter { filter.matches($0.files[0], lowercasedPath: $0.searchText) }
        guard grouped else { return matching.sorted(using: sortOrder) }
        var order: [String] = []
        var groups: [String: (path: String, rows: [ResultRow])] = [:]
        for row in matching {
            let key = row.username + "\u{1}" + row.parentPath
            if groups[key] == nil {
                order.append(key)
                groups[key] = (row.parentPath, [])
            }
            groups[key]?.rows.append(row)
        }
        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            return ResultRow(folderPath: group.path, rows: group.rows.sorted(using: sortOrder))
        }
        .sorted(using: sortOrder)
    }

    private func table(_ rows: [ResultRow]) -> some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                Label {
                    Text(row.name)
                } icon: {
                    Image(systemName: row.isFolder ? "folder" : "music.note")
                        .foregroundStyle(row.isFolder ? Palette.cool : .secondary)
                }
                .help(row.fullPath.replacingOccurrences(of: "\\", with: " ▸ "))
            }
            .width(min: 180, ideal: 320)
            TableColumn("Folder", value: \.folder) { row in
                Text(row.folder).foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 200)
            TableColumn("Format", value: \.qualityRank) { row in
                Text(row.isFolder ? "\(row.qualityText) · \(row.files.count) files" : row.qualityText)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Length", value: \.duration) { row in
                Text(row.durationText).monospacedDigit()
            }
            .width(56)
            TableColumn("Size", value: \.size) { row in
                Text(row.sizeText).monospacedDigit()
            }
            .width(70)
            TableColumn("User", value: \.username)
                .width(min: 80, ideal: 130)
            TableColumn("Queue", value: \.availability) { row in
                Text(row.availabilityText)
                    .foregroundStyle(row.slotFree ? .primary : .secondary)
            }
            .width(60)
            TableColumn("Speed", value: \.speed) { row in
                Text(row.speedText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: ResultRow.ID.self) { ids in
            menu(for: selectedRows(ids, in: rows))
        } primaryAction: { ids in
            soulseek.download(files(of: selectedRows(ids, in: rows)))
        }
    }

    @ViewBuilder
    private func menu(for selected: [ResultRow]) -> some View {
        let files = files(of: selected)
        if !files.isEmpty {
            Button(files.count == 1 ? "Download" : "Download \(files.count) Files") {
                soulseek.download(files)
            }
            if selected.count == 1, let row = selected.first, !row.isFolder, let file = row.files.first {
                let mates = folderMates(of: file)
                if mates.count > 1 {
                    Button("Download Folder (\(mates.count) Files)") { soulseek.download(mates) }
                }
            }
            Divider()
        }
        if let row = selected.first {
            SoulseekUserMenu(soulseek: soulseek, user: row.username)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.fullPath, forType: .string)
            }
            Button("Copy User") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.username, forType: .string)
            }
        }
    }

    /// The rows for `ids`, looking inside folders too.
    private func selectedRows(_ ids: Set<ResultRow.ID>, in rows: [ResultRow]) -> [ResultRow] {
        var found: [ResultRow] = []
        func walk(_ rows: [ResultRow]) {
            for row in rows {
                if ids.contains(row.id) { found.append(row) }
                if let children = row.children { walk(children) }
            }
        }
        walk(rows)
        return found
    }

    /// Every file the rows stand for, once each (a folder and one of its files may both be selected).
    private func files(of rows: [ResultRow]) -> [SlskSearchResult] {
        var seen = Set<String>()
        return rows.flatMap(\.files).filter { seen.insert($0.username + "\u{1}" + $0.path).inserted }
    }

    /// Every result from the same user in the same remote folder — the whole-album grab.
    private func folderMates(of result: SlskSearchResult) -> [SlskSearchResult] {
        let folder = result.parentPath
        return rows.filter { $0.username == result.username && $0.parentPath == folder }.flatMap(\.files)
    }
}

// MARK: - Browse tab

/// One user's whole share: their folders on the left, the chosen folder's files on the right.
private struct BrowsePane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedFolder: String?
    @State private var cache = BrowseFolderCache()

    private var soulseek: SoulseekModel { model.soulseek }

    var body: some View {
        switch soulseek.browseState {
        case .idle:
            ContentUnavailableView(
                "Browse a User",
                systemImage: "person.crop.rectangle.stack",
                description: Text("Enter a username above, or right-click a search result ▸ Browse.")
            )
        case .loading(let user):
            VStack(spacing: 12) {
                ProgressView()
                Text("Asking \(user) for their file list…").foregroundStyle(.secondary)
                Text("Big shares can take a minute to arrive.").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let user, let reason):
            ContentUnavailableView {
                Label("Can't Browse \(user)", systemImage: "exclamationmark.triangle")
            } description: {
                Text(reason)
            } actions: {
                Button("Try Again") { soulseek.browse(user: user) }
            }
        case .loaded(let list):
            if list.folders.isEmpty {
                ContentUnavailableView("\(list.username) Shares Nothing", systemImage: "folder",
                                       description: Text("Their share list is empty (or only open to their buddies)."))
            } else {
                loaded(list)
            }
        }
    }

    private func loaded(_ list: SlskSharedFileList) -> some View {
        let folders = cache.visibleFolders(of: list, version: soulseek.browseVersion, filter: soulseek.resultFilter)
        return HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("\(list.username) · \(list.fileCount.formatted()) files in \(list.folders.count.formatted()) folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Menu {
                        SoulseekUserMenu(soulseek: soulseek, user: list.username, showsBrowse: false)
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Message \(list.username), see their info, or block them")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .contextMenu {
                    SoulseekUserMenu(soulseek: soulseek, user: list.username, showsBrowse: false)
                }
                List(folders, selection: $selectedFolder) { folder in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(folder.path.split(separator: "\\").last.map(String.init) ?? folder.path)
                            .lineLimit(1)
                        Text("\(folder.path.split(separator: "\\").dropLast().joined(separator: " ▸ ")) · \(folder.files.count) files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .help(folder.path.replacingOccurrences(of: "\\", with: " ▸ "))
                    .tag(folder.path)
                    .contextMenu {
                        Button("Download Folder (\(folder.files.count) Files)") { soulseek.download(folder.files) }
                            .disabled(folder.files.isEmpty)
                        let nested = cache.nestedFileCount(of: folder.path)
                        if nested > folder.files.count {
                            Button("Download Folder and Subfolders (\(nested) Files)") {
                                soulseek.download(filesUnder(folder.path, in: list))
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 300, maxWidth: 480)
            Group {
                if let path = selectedFolder, let folder = list.folders.first(where: { $0.path == path }) {
                    if folder.files.isEmpty {
                        ContentUnavailableView("No Files Here", systemImage: "folder", description: Text("This folder only holds other folders."))
                    } else {
                        ResultsTable(
                            rows: folder.files.map(ResultRow.init(file:)),
                            version: "browse \(soulseek.browseVersion) \(path)",
                            allowsGrouping: false,
                            usesSlotFilter: false)
                    }
                } else {
                    ContentUnavailableView("Choose a Folder", systemImage: "folder")
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filesUnder(_ path: String, in list: SlskSharedFileList) -> [SlskSearchResult] {
        let prefix = path + "\\"
        return list.folders.filter { $0.path == path || $0.path.hasPrefix(prefix) }.flatMap(\.files)
    }
}

/// What the browse pane derives from a share list, kept until the list or the filter changes:
/// matching a big share against the filter on every redraw is slow.
@MainActor
private final class BrowseFolderCache {
    private var key: (version: Int, filter: SoulseekModel.ResultFilter)?
    private var folders: [SlskSharedFileList.Folder] = []
    private var nestedCounts: (version: Int, counts: [String: Int])?

    /// Folders whose path matches the filter's words, or that hold a file that does.
    func visibleFolders(of list: SlskSharedFileList, version: Int, filter: SoulseekModel.ResultFilter) -> [SlskSharedFileList.Folder] {
        if let key, key.version == version, key.filter == filter { return folders }
        var fileFilter = filter
        fileFilter.freeSlotsOnly = false
        let words = filter.include
        folders = words.isEmpty ? list.folders : list.folders.filter { folder in
            let path = folder.path.lowercased()
            return words.allSatisfy(path.contains)
                || folder.files.contains { fileFilter.matches($0, lowercasedPath: $0.path.lowercased()) }
        }
        key = (version, filter)
        if nestedCounts?.version != version { nestedCounts = (version, Self.nestedCounts(list)) }
        return folders
    }

    /// Files in a folder and all its subfolders.
    func nestedFileCount(of path: String) -> Int {
        nestedCounts?.counts[path] ?? 0
    }

    private static func nestedCounts(_ list: SlskSharedFileList) -> [String: Int] {
        let paths = Set(list.folders.map(\.path))
        var counts: [String: Int] = [:]
        for folder in list.folders where !folder.files.isEmpty {
            var path = Substring(folder.path)
            while true {
                if paths.contains(String(path)) { counts[String(path), default: 0] += folder.files.count }
                guard let cut = path.lastIndex(of: "\\") else { break }
                path = path[..<cut]
            }
        }
        return counts
    }
}

// MARK: Display helpers

extension SlskSearchResult {
    /// The remote folder the file is in (full path).
    var parentPath: String {
        guard let cut = path.lastIndex(of: "\\") else { return "" }
        return String(path[..<cut])
    }

    /// Lower is better: free slots first, then by queue length.
    var availability: Int { slotFree ? 0 : Int(queueLength) + 1 }

    var availabilityText: String { slotFree ? "Free" : queueLength.formatted() }

    var durationSortValue: Int { durationSeconds ?? 0 }

    var durationText: String {
        guard let seconds = durationSeconds, seconds > 0 else { return "–" }
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    var sizeText: String { byteCount(size) }

    var speedText: String {
        guard averageSpeed > 0 else { return "–" }
        return "\(byteCount(UInt64(averageSpeed)))/s"
    }

    /// "FLAC 16/44.1", "MP3 320", "MP3 245 VBR", or just the extension.
    var qualityDescription: String {
        let kind = fileExtension.isEmpty ? "?" : fileExtension.uppercased()
        if kind == "FLAC" || kind == "ALAC" || kind == "WAV" || kind == "AIFF" {
            if let depth = bitDepth, let rate = sampleRate {
                return "\(kind) \(depth)/\(formatkHz(rate))"
            }
            return kind
        }
        if let bitrate {
            return "\(kind) \(bitrate)\(isVBR ? " VBR" : "")"
        }
        return kind
    }

    /// Higher is better; used to make the Format column sortable in a meaningful way.
    var qualityRank: Int {
        switch fileExtension {
        case "flac", "alac", "wav", "aiff":
            return 10_000 + (bitDepth ?? 16) * 100 + (sampleRate ?? 44100) / 1000
        default:
            return bitrate ?? 0
        }
    }

    private func formatkHz(_ hertz: Int) -> String {
        let kHz = Double(hertz) / 1000
        return kHz == kHz.rounded() ? String(format: "%.0f", kHz) : String(format: "%.1f", kHz)
    }
}
