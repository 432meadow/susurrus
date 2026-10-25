import AppKit
import SwiftUI

/// The library's artists on the left; the selected artist's page on the right.
struct ArtistsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let _ = model.libraryRevision  // tag edits rebuild the index
        let index = model.artists
        let filtered = filteredArtists(index)
        // A fixed-width list: in an HSplitView the divider moved whenever the page's content changed.
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                List(filtered, selection: $model.selectedArtistID) { artist in
                    HStack {
                        Text(artist.name).lineLimit(1)
                        Spacer()
                        Text("\(artist.trackCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(artist.id)
                    .paletteSelection(model.selectedArtistID == artist.id)
                }
                .frame(width: 250)
                .onAppear { if let id = model.selectedArtistID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.selectedArtistID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id) } }
                }
            }
            Divider()

            Group {
                if let id = model.selectedArtistID, let artist = index.artists.first(where: { $0.id == id }) {
                    ArtistPage(artist: artist)
                        .id(artist.id)
                } else {
                    ContentUnavailableView("Pick an Artist", systemImage: "music.mic",
                                           description: Text("See their albums in your library, their discography, and similar artists."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The toolbar search field narrows the list by name.
    private func filteredArtists(_ index: ArtistIndex) -> [ArtistIndex.Artist] {
        let words = model.searchText.split(separator: " ").map { ArtistIndex.key(for: String($0)) }
        guard !words.isEmpty else { return index.artists }
        return index.artists.filter { artist in words.allSatisfy { artist.id.contains($0) } }
    }
}

// MARK: - Loading

/// Everything the page fetches about one artist: the MusicBrainz match, discography, Wikipedia
/// summary and similar artists.
@MainActor
@Observable
final class ArtistPageModel {
    enum MatchState {
        case loading
        case matched
        /// No MusicBrainz artist has this name; the user can pick one of `candidates`.
        case notFound
        case failed(String)
    }

    let artist: ArtistIndex.Artist
    private(set) var match: MatchState = .loading

    var isLoading: Bool {
        if case .loading = match { return true }
        return false
    }
    private(set) var candidates: [MBArtist] = []
    private(set) var mbArtist: MBArtist?
    /// True when the match was picked by hand (it's remembered).
    private(set) var isLinked = false
    private(set) var releaseGroups: [MBReleaseGroup]?
    private(set) var discographyError: String?
    private(set) var summary: WikipediaSummary?
    private(set) var similar: [SimilarArtist]?
    private(set) var similarError: String?

    private let service = ArtistInfoService.shared

    init(artist: ArtistIndex.Artist) {
        self.artist = artist
    }

    func load(linkedMBID: String?, libraryTitles: [String: String]) async {
        isLinked = linkedMBID != nil
        match = .loading
        do {
            candidates = try await service.searchArtists(artist.name)
            if let linkedMBID {
                await show(mbid: linkedMBID, releaseGroups: nil)
                return
            }
            let wanted = Self.comparableName(artist.name)
            let sameName = candidates.filter { ($0.score ?? 0) >= 85 && Self.comparableName($0.name) == wanted }
            guard let first = sameName.first else {
                match = .notFound
                return
            }
            // Several artists share the name: pick the one whose discography overlaps the library most.
            var best = (artist: first, matches: -1, groups: [MBReleaseGroup]?.none)
            if sameName.count > 1, !libraryTitles.isEmpty {
                for candidate in sameName.prefix(3) {
                    guard let groups = try? await service.releaseGroups(candidate.id) else { continue }
                    let matches = groups.filter { DiscographyMatch.match($0.title, in: libraryTitles) != nil }.count
                    if matches > best.matches { best = (candidate, matches, groups) }
                }
            }
            await show(mbid: best.artist.id, releaseGroups: best.groups)
        } catch {
            match = .failed(error.localizedDescription)
        }
    }

    /// Switches to another MusicBrainz artist (nil: none of them).
    func choose(_ candidate: MBArtist?) async {
        mbArtist = nil
        releaseGroups = nil
        summary = nil
        similar = nil
        discographyError = nil
        similarError = nil
        isLinked = candidate != nil
        guard let candidate else {
            match = .notFound
            return
        }
        match = .loading
        await show(mbid: candidate.id, releaseGroups: nil)
    }

    private func show(mbid: String, releaseGroups known: [MBReleaseGroup]?) async {
        do {
            mbArtist = try await service.artist(mbid)
            match = .matched
        } catch {
            match = .failed(error.localizedDescription)
            return
        }
        async let groups: Void = loadDiscography(mbid, known: known)
        async let bio: Void = loadSummary()
        async let related: Void = loadSimilar(mbid)
        _ = await (groups, bio, related)
    }

    private func loadDiscography(_ mbid: String, known: [MBReleaseGroup]?) async {
        if let known {
            releaseGroups = known
            return
        }
        do {
            releaseGroups = try await service.releaseGroups(mbid)
        } catch {
            discographyError = error.localizedDescription
        }
    }

    private func loadSummary() async {
        guard let wikidata = mbArtist?.wikidataID else { return }
        summary = try? await service.wikipediaSummary(wikidataID: wikidata)
    }

    private func loadSimilar(_ mbid: String) async {
        do {
            similar = try await service.similarArtists(mbid)
        } catch {
            similarError = error.localizedDescription
        }
    }

    /// Names compared ignoring case, accents, punctuation and a leading "The".
    static func comparableName(_ name: String) -> String {
        var normalized = DiscographyMatch.normalizedTitle(name)
        if normalized.hasPrefix("the ") { normalized.removeFirst(4) }
        return normalized
    }
}

// MARK: - Page

private struct ArtistPage: View {
    @Environment(AppModel.self) private var model
    let artist: ArtistIndex.Artist
    @State private var page: ArtistPageModel
    @AppStorage("artist.showAllReleases") private var showAllReleases = false
    @AppStorage("artist.missingOnly") private var missingOnly = false
    /// The library album opened from a shelf; the page shows its tracklist instead.
    @State private var openAlbumID: Album.ID?

    init(artist: ArtistIndex.Artist) {
        self.artist = artist
        _page = State(initialValue: ArtistPageModel(artist: artist))
    }

    private var tracks: [Track] { model.artists.tracks(for: artist) }

    /// The artist's albums in the library, newest first; albums filed under someone else
    /// (compilations, guest spots) come separately.
    private var libraryAlbums: (own: [Album], appearsOn: [Album]) {
        let albums = Album.group(tracks, sortedBy: .year)
        let own = albums.filter { ArtistIndex.key(for: $0.artist) == artist.id }
        let appearsOn = albums.filter { ArtistIndex.key(for: $0.artist) != artist.id }
        return (own, appearsOn)
    }

    private var libraryTitles: [String: String] {
        DiscographyMatch.libraryTitles(tracks.map(\.album))
    }

    var body: some View {
        let albums = libraryAlbums
        let openAlbum = openAlbumID.flatMap { id in (albums.own + albums.appearsOn).first { $0.id == id } }
        // The artist page stays underneath, hidden, so going back keeps its scroll position.
        ZStack {
            artistPage(albums)
                .opacity(openAlbum == nil ? 1 : 0)
                .allowsHitTesting(openAlbum == nil)
                .accessibilityHidden(openAlbum != nil)
            if let openAlbum {
                ArtistAlbumPage(album: openAlbum, artistName: artist.name) { openAlbumID = nil }
            }
        }
        .task {
            await page.load(linkedMBID: model.linkedMBID(for: artist), libraryTitles: libraryTitles)
        }
    }

    private func artistPage(_ albums: (own: [Album], appearsOn: [Album])) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let summary = page.summary {
                    biography(summary)
                }
                if !albums.own.isEmpty {
                    albumShelf("In Your Library", albums.own)
                }
                if !albums.appearsOn.isEmpty {
                    albumShelf("Appears On", albums.appearsOn)
                }
                mostPlayed
                discography
                similarArtists
            }
            .padding(24)
            .frame(maxWidth: 980, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            headerImage
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 6) {
                Text(artist.name).font(.largeTitle.weight(.semibold)).lineLimit(2)
                matchLine
                if let genres = page.mbArtist?.topGenres, !genres.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre)
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Palette.cool.opacity(0.18), in: Capsule())
                        }
                    }
                }
                Text(libraryLine).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { model.playArtist(artist) } label: { Label("Play", systemImage: "play.fill") }
                    Button { model.playArtist(artist, shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    if let links = page.mbArtist?.links {
                        Menu("Links") {
                            if let url = page.summary?.pageURL { Link("Wikipedia", destination: url) }
                            ForEach(links, id: \.url) { link in Link(link.title, destination: link.url) }
                        }
                        .fixedSize()
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var headerImage: some View {
        if let url = page.summary?.imageURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
        } else {
            ArtworkView(request: libraryAlbums.own.first?.artworkRequest ?? tracks.first?.artworkRequest, pixelSize: 320, cornerRadius: 8)
        }
    }

    @ViewBuilder private var matchLine: some View {
        HStack(spacing: 6) {
            switch page.match {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Looking up on MusicBrainz…").foregroundStyle(.secondary)
            case .matched:
                if let mbArtist = page.mbArtist {
                    Text([mbArtist.summary, mbArtist.disambiguation ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
            case .notFound:
                Text("Not found on MusicBrainz").foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn't reach MusicBrainz: \(message)").foregroundStyle(Palette.ochre)
            }
            if !page.candidates.isEmpty, !page.isLoading {
                Menu(page.mbArtist == nil ? "Choose…" : "Not them?") {
                    ForEach(page.candidates) { candidate in
                        Button(candidateTitle(candidate)) {
                            model.setLinkedMBID(candidate.id, for: artist)
                            Task { await page.choose(candidate) }
                        }
                    }
                    if page.isLinked {
                        Divider()
                        Button("Match Automatically") {
                            model.setLinkedMBID(nil, for: artist)
                            Task { await page.load(linkedMBID: nil, libraryTitles: libraryTitles) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pick the MusicBrainz artist this is; the choice is remembered")
            }
        }
        .font(.callout)
    }

    private func candidateTitle(_ candidate: MBArtist) -> String {
        let details = [candidate.disambiguation ?? "", candidate.summary].filter { !$0.isEmpty }.joined(separator: " · ")
        let mark = candidate.id == page.mbArtist?.id ? "✓ " : ""
        return mark + candidate.name + (details.isEmpty ? "" : " (\(details))")
    }

    private var libraryLine: String {
        let plays = tracks.reduce(0) { $0 + $1.playCount }
        var parts = ["\(artist.trackCount.formatted()) \(artist.trackCount == 1 ? "track" : "tracks")"]
        if artist.albumCount > 0 { parts.append("\(artist.albumCount) \(artist.albumCount == 1 ? "album" : "albums")") }
        parts.append(Format.time(tracks.reduce(0) { $0 + $1.length }))
        if plays > 0 { parts.append("\(plays.formatted()) \(plays == 1 ? "play" : "plays")") }
        return parts.joined(separator: " · ")
    }

    private func biography(_ summary: WikipediaSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.extract)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let url = summary.pageURL {
                Link("Read more on Wikipedia", destination: url).font(.callout)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
    }

    // MARK: Library

    private func albumShelf(_ title: String, _ albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 16, alignment: .top)], alignment: .leading, spacing: 18) {
                ForEach(albums) { album in
                    VStack(alignment: .leading, spacing: 2) {
                        AlbumCell(album: album, isSelected: false)
                        if album.year > 0 {
                            Text(String(album.year)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture(count: 2) { model.play(album) }
                    .simultaneousGesture(TapGesture().onEnded { openAlbumID = album.id })
                    .contextMenu {
                        MenuEntries(entries: TrackMenu.entries(for: album, model: model,
                                                               leading: [.action("Open") { openAlbumID = album.id }, .separator]))
                    }
                    .help("Click to see the tracks, double-click to play")
                }
            }
        }
    }

    @ViewBuilder private var mostPlayed: some View {
        let top = tracks.filter { $0.playCount > 0 }.sorted { ($0.playCount, $1.title) > ($1.playCount, $0.title) }.prefix(5)
        if !top.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Most Played").font(.title3.weight(.semibold))
                ForEach(Array(top)) { track in
                    HStack(spacing: 10) {
                        ArtworkView(request: track.artworkRequest, pixelSize: 80, cornerRadius: 3)
                            .frame(width: 28, height: 28)
                        Text(track.title).lineLimit(1)
                        Text(track.album).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text("\(track.playCount) \(track.playCount == 1 ? "play" : "plays")")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { playMostPlayed(Array(top), from: track) }
                    .contextMenu {
                        MenuEntries(entries: TrackMenu.entries(for: [track], model: model) { playMostPlayed(Array(top), from: track) })
                    }
                    .help("Double-click to play")
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func playMostPlayed(_ tracks: [Track], from track: Track) {
        model.player.play(tracks, startingAt: tracks.firstIndex(of: track) ?? 0)
    }

    // MARK: Discography

    @ViewBuilder private var discography: some View {
        if page.mbArtist != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Text("Discography").font(.title3.weight(.semibold))
                    Picker("", selection: $showAllReleases) {
                        Text("Albums & EPs").tag(false)
                        Text("Everything").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Everything adds singles, live albums, compilations, demos and the like")
                    Toggle("Missing only", isOn: $missingOnly)
                    Spacer()
                    if let summary = discographySummary { Text(summary).font(.callout).foregroundStyle(.secondary) }
                }
                if let groups = page.releaseGroups {
                    let rows = discographyRows(groups)
                    if rows.isEmpty {
                        Text(missingOnly ? "Nothing missing." : "MusicBrainz lists no releases here.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(rows, id: \.group.id) { row in
                                DiscographyRow(artistName: page.mbArtist?.name ?? artist.name, group: row.group, libraryAlbum: row.libraryAlbum)
                                Divider()
                            }
                        }
                    }
                } else if let error = page.discographyError {
                    Text("Couldn't load the discography: \(error)").foregroundStyle(Palette.ochre)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("From MusicBrainz. An album counts as in your library when its title matches one of this artist's albums, ignoring edition notes like “(Deluxe Edition)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func discographyRows(_ groups: [MBReleaseGroup]) -> [(group: MBReleaseGroup, libraryAlbum: String?)] {
        let titles = libraryTitles
        return groups
            .filter { showAllReleases || $0.isMainRelease }
            .map { ($0, DiscographyMatch.match($0.title, in: titles)) }
            .filter { !missingOnly || $0.1 == nil }
    }

    private var discographySummary: String? {
        guard let groups = page.releaseGroups else { return nil }
        let main = groups.filter { showAllReleases || $0.isMainRelease }
        guard !main.isEmpty else { return nil }
        let owned = main.filter { DiscographyMatch.match($0.title, in: libraryTitles) != nil }.count
        return "\(owned) of \(main.count) in your library"
    }

    // MARK: Similar artists

    @ViewBuilder private var similarArtists: some View {
        if page.mbArtist != nil {
            VStack(alignment: .leading, spacing: 10) {
                Text("Similar Artists").font(.title3.weight(.semibold))
                if let similar = page.similar {
                    if similar.isEmpty {
                        Text("ListenBrainz has no similar artists for them yet.").foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(similar) { other in
                                SimilarArtistChip(name: other.name, mbid: other.artistMbid)
                            }
                        }
                        Text("From ListenBrainz: artists people listen to in the same sessions. Highlighted ones are in your library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = page.similarError {
                    Text("Couldn't load similar artists: \(error)").foregroundStyle(Palette.ochre)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Album

/// A library album opened from the artist page: cover, details and its tracklist.
private struct ArtistAlbumPage: View {
    @Environment(AppModel.self) private var model
    let album: Album
    let artistName: String
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button(action: onBack) {
                Label(artistName, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Back to \(artistName)")

            HStack(alignment: .bottom, spacing: 20) {
                ArtworkView(request: album.artworkRequest, pixelSize: 420, cornerRadius: 8)
                    .frame(width: 180, height: 180)
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title).font(.largeTitle.weight(.semibold)).lineLimit(2)
                    if let pageArtist = album.pageArtist, ArtistIndex.key(for: pageArtist) != ArtistIndex.key(for: artistName) {
                        Button(album.artist) { model.showArtist(pageArtist) }
                            .buttonStyle(.link)
                            .font(.title3)
                    } else {
                        Text(album.artist).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(details).font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button { model.play(album) } label: { Label("Play", systemImage: "play.fill") }
                        Button { shuffle() } label: { Label("Shuffle", systemImage: "shuffle") }
                        Button { model.playNext(album.tracks) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Button { model.addToQueue(album.tracks) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                    }
                    .padding(.top, 4)
                }
            }

            AlbumTrackTable(album: album)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Plays the album in random order, leaving the player's own Shuffle setting alone.
    private func shuffle() {
        model.player.play(album.tracks.shuffled(), startingAt: 0)
    }

    private var details: String {
        var parts: [String] = []
        if album.year > 0 { parts.append(String(album.year)) }
        parts.append("\(album.tracks.count) \(album.tracks.count == 1 ? "track" : "tracks")")
        parts.append(Format.time(album.duration))
        let plays = album.tracks.reduce(0) { $0 + $1.playCount }
        if plays > 0 { parts.append("\(plays.formatted()) \(plays == 1 ? "play" : "plays")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Rows and chips

private struct DiscographyRow: View {
    @Environment(AppModel.self) private var model
    let artistName: String
    let group: MBReleaseGroup
    /// The matching album title in the library, if there is one.
    let libraryAlbum: String?

    private var query: String { AppModel.soulseekQuery(artist: artistName, title: group.title) }

    var body: some View {
        HStack(spacing: 12) {
            Text(group.year.map(String.init) ?? "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).lineLimit(1)
                Text(group.typeLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let libraryAlbum {
                Label("In library", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .foregroundStyle(Palette.warm)
                    .help(libraryAlbum == group.title ? "In your library" : "In your library as “\(libraryAlbum)”")
            } else {
                Button { model.searchSoulseek(query) } label: {
                    Label("Search Soulseek", systemImage: "magnifyingglass")
                }
                .help("Search Soulseek for “\(query)”")
                Button { model.soulseek.addToWishlist(query) } label: {
                    Image(systemName: model.soulseek.wishlist.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) ? "star.fill" : "star")
                }
                .help("Add “\(query)” to the Soulseek wishlist")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
        .contextMenu {
            if libraryAlbum == nil {
                Button("Search Soulseek") { model.searchSoulseek(query) }
                Button("Add to Soulseek Wishlist") { model.soulseek.addToWishlist(query) }
            }
            if let url = URL(string: "https://musicbrainz.org/release-group/\(group.id)") {
                Link("Open in MusicBrainz", destination: url)
            }
        }
    }
}

private struct SimilarArtistChip: View {
    @Environment(AppModel.self) private var model
    let name: String
    let mbid: String

    var body: some View {
        if let inLibrary = model.artists.artist(named: name) {
            Button { model.showArtist(name) } label: {
                HStack(spacing: 4) {
                    Text(name)
                    Text("\(inLibrary.trackCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .chip(fill: Palette.warm.opacity(0.25))
            }
            .buttonStyle(.plain)
            .help("In your library: \(inLibrary.trackCount) tracks. Click to open.")
        } else {
            Menu {
                Button("Search Soulseek") { model.searchSoulseek(AppModel.soulseekQuery(artist: name, title: "")) }
                Button("Add to Soulseek Wishlist") { model.soulseek.addToWishlist(AppModel.soulseekQuery(artist: name, title: "")) }
                if let url = URL(string: "https://musicbrainz.org/artist/\(mbid)") {
                    Link("Open in MusicBrainz", destination: url)
                }
            } label: {
                Text(name).chip(fill: Color.secondary.opacity(0.12))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Not in your library")
        }
    }
}

private extension View {
    func chip(fill: Color) -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
