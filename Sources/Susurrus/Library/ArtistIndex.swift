import Foundation

/// The library's artists, for the Artists view: every name that appears as a track's artist or
/// album artist, with the tracks credited to it.
struct ArtistIndex {
    struct Artist: Identifiable, Hashable {
        /// `ArtistIndex.key(for:)` of the name.
        let id: String
        /// The spelling most of its tracks use.
        let name: String
        let trackCount: Int
        let albumCount: Int
    }

    private(set) var artists: [Artist] = []
    private var tracksByKey: [String: [Track]] = [:]

    init(tracks: [Track]) {
        var spellings: [String: [String: Int]] = [:]
        for track in tracks {
            var keys = Set<String>()
            for name in [track.artist, track.albumArtist] where !name.isEmpty {
                let key = Self.key(for: name)
                guard keys.insert(key).inserted else { continue }
                tracksByKey[key, default: []].append(track)
                spellings[key, default: [:]][name, default: 0] += 1
            }
        }
        artists = tracksByKey.map { key, tracks in
            let name = spellings[key]!.max { ($0.value, $1.key) < ($1.value, $0.key) }!.key
            let albums = Set(tracks.lazy.filter { !$0.album.isEmpty }.map { Self.key(for: $0.album) })
            return Artist(id: key, name: name, trackCount: tracks.count, albumCount: albums.count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func artist(named name: String) -> Artist? {
        let key = Self.key(for: name)
        return artists.first { $0.id == key }
    }

    /// Tracks credited to the artist, as artist or album artist.
    func tracks(for artist: Artist) -> [Track] {
        tracksByKey[artist.id] ?? []
    }

    /// Folds case, accents and width, and drops a leading "The ", so spellings of a name meet.
    static func key(for name: String) -> String {
        var folded = TextKey.folded(name).trimmingCharacters(in: .whitespaces)
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return folded
    }
}

/// Matches MusicBrainz release groups to the albums in the library.
enum DiscographyMatch {
    /// Folds a title for comparison: case, accents, punctuation, "&"/"and", and edition notes in
    /// brackets ("(Deluxe Edition)", "[Remastered 2011]") are all ignored.
    static func normalizedTitle(_ title: String) -> String {
        var text = TextKey.folded(title)
        // Drop bracketed notes, but keep the title if that's all it is.
        let withoutNotes = text.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if !withoutNotes.trimmingCharacters(in: .whitespaces).isEmpty { text = withoutNotes }
        return TextKey.words(text.replacingOccurrences(of: "&", with: " and "))
    }

    /// The library album (by its normalized title) that a release group is, if any: the same
    /// normalized title, or one that starts with the other at a word boundary ("Geogaddi" and
    /// "Geogaddi Bonus Disc"), so long as the shorter one has at least 4 characters.
    static func match(_ releaseTitle: String, in libraryTitles: [String: String]) -> String? {
        let release = normalizedTitle(releaseTitle)
        guard !release.isEmpty else { return nil }
        if let exact = libraryTitles[release] { return exact }
        for (normalized, original) in libraryTitles.sorted(by: { $0.key < $1.key }) {
            let (short, long) = normalized.count < release.count ? (normalized, release) : (release, normalized)
            if short.count >= 4, long.hasPrefix(short + " ") { return original }
        }
        return nil
    }

    /// Library album titles keyed by normalized title.
    static func libraryTitles(_ albums: some Sequence<String>) -> [String: String] {
        var result: [String: String] = [:]
        for album in albums where !album.isEmpty {
            let normalized = normalizedTitle(album)
            if !normalized.isEmpty, result[normalized] == nil { result[normalized] = album }
        }
        return result
    }
}
