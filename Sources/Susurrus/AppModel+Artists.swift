import Foundation

/// Artist pages, listening stats, and handing searches over to Soulseek.
extension AppModel {
    // MARK: Artists

    /// The library's artists (rebuilt after tags change or tracks come and go).
    var artists: ArtistIndex {
        if let artistIndex { return artistIndex }
        let index = ArtistIndex(tracks: tracks)
        artistIndex = index
        return index
    }

    /// Opens the artist's page in the Artists view.
    func showArtist(_ name: String) {
        guard let artist = artists.artist(named: name) else { return }
        selectedArtistID = artist.id
        searchText = ""
        selection = .artists
    }

    /// The MusicBrainz artist picked by hand for this artist, if any.
    func linkedMBID(for artist: ArtistIndex.Artist) -> String? {
        performQuietly("Couldn't read an artist link") { try $0.artistMBID(forKey: artist.id) } ?? nil
    }

    func setLinkedMBID(_ mbid: String?, for artist: ArtistIndex.Artist) {
        perform("Couldn't save the artist link") { try $0.setArtistMBID(mbid, forKey: artist.id) }
    }

    /// Plays every track by the artist, album by album, or in random order (without turning the
    /// player's own Shuffle on, which would outlast this).
    func playArtist(_ artist: ArtistIndex.Artist, shuffled: Bool = false) {
        let albums = Album.group(artists.tracks(for: artist), sortedBy: .year).reversed()
        let ordered = albums.flatMap(\.tracks) + artists.tracks(for: artist).filter(\.album.isEmpty)
        guard !ordered.isEmpty else { return }
        player.play(shuffled ? ordered.shuffled() : ordered, startingAt: 0)
    }

    // MARK: Soulseek

    /// Runs a Soulseek search and shows its results.
    func searchSoulseek(_ query: String) {
        soulseek.query = query
        soulseek.search()
        searchText = ""
        selection = .soulseek
    }

    /// "Artist Title" with bracketed edition notes and punctuation dropped, since Soulseek
    /// matches whole words in file paths. Apostrophes join their word ("Tomorrows"), and lone
    /// letters ("A", or the "s" of a split possessive) are left out as too short to match.
    static func soulseekQuery(artist: String, title: String) -> String {
        func clean(_ text: String) -> [Substring] {
            let withoutNotes = text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            let base = (withoutNotes.trimmingCharacters(in: .whitespaces).isEmpty ? text : withoutNotes)
                .replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
            let kept = String(base.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
            let words = kept.split(separator: " ")
            let long = words.filter { $0.count > 1 || $0.allSatisfy(\.isNumber) }
            return long.isEmpty ? words : long
        }
        return (clean(artist) + clean(title)).joined(separator: " ")
    }

    // MARK: Stats

    func listeningStats(for range: ListeningStats.Range) async -> ListeningStats {
        guard store != nil else { return ListeningStats() }
        let now = Date()
        let calendar = Calendar.current
        let start = ListeningStats.loadStart(for: range, now: now, calendar: calendar)
        let listens = performQuietly("Couldn't read the listening history") { try $0.listens(since: start) } ?? []
        let plays = performQuietly("Couldn't read the listening history") { try $0.plays(since: start) } ?? []
        let firstListen = performQuietly("Couldn't read the listening history") { try $0.firstListenDate() } ?? nil
        var info: [Int64: ListeningStats.TrackInfo] = [:]
        for id in Set(listens.map(\.trackID)).union(plays.map(\.trackID)) {
            if let track = tracksByID[id] { info[id] = ListeningStats.TrackInfo(track) }
        }
        return await Task.detached(priority: .userInitiated) {
            ListeningStats.compute(range: range, listens: listens, plays: plays, firstListen: firstListen,
                                   tracks: info, now: now, calendar: calendar)
        }.value
    }

    /// Library tracks of one album, in order (for playing a top album).
    func albumTracks(albumOf track: Track) -> [Track] {
        let key = track.albumKey
        return tracks.filter { $0.albumKey == key }
            .sorted { ($0.discNumber, $0.trackNumber, $0.title) < ($1.discNumber, $1.trackNumber, $1.title) }
    }
}
