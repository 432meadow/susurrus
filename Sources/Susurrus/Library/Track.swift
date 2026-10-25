import Foundation

/// One library track.
///
/// Subclasses NSObject and exposes `@objc` properties (`albumArtist`, `dateAdded`,
/// `playCount`, …) so archived smart playlist NSPredicates evaluate against it via KVC.
final class Track: NSObject, Identifiable {
    let id: Int64

    @objc var title = ""
    @objc var artist = ""
    @objc var album = ""
    @objc var albumArtist = ""
    @objc var genre = ""
    @objc var composer = ""
    @objc var grouping = ""
    @objc var comment = ""
    @objc var year = 0
    @objc var trackNumber = 0
    @objc var totalNumberOfTracks = 0
    @objc var discNumber = 0
    @objc var totalNumberOfDiscs = 0
    /// Seconds.
    @objc var length = 0.0
    /// kbps.
    @objc var bitRate = 0
    @objc var sampleRate = 0
    @objc var bitDepth = 0
    @objc var channels = 0
    @objc var bpm = 0
    /// The key as tagged or detected, in standard notation ("Am", "F#") when it could be read.
    @objc var musicalKey = ""
    @objc var fileSize: Int64 = 0
    @objc var compilation = false
    @objc var enabled = true
    /// 0–5 in half-star steps.
    @objc var rating = 0.0
    @objc var playCount = 0
    /// Times playback moved on before the end (from the listen log; not a file tag).
    @objc var skipCount = 0
    @objc var dateAdded: Date?
    @objc var lastPlayed: Date?
    @objc var dateModified: Date?
    @objc var dateCreated: Date?
    @objc var path = "" {
        didSet { sortKeys.removeAll() }
    }

    init(id: Int64) {
        self.id = id
    }

    @objc var fileName: String { (path as NSString).lastPathComponent }
    @objc var fileType: String { (path as NSString).pathExtension.uppercased() }
    @objc var kind: String { fileType }

    var displayArtist: String { artist.isEmpty ? albumArtist : artist }
    /// The title, or the file name for an untitled track.
    var displayTitle: String { title.isEmpty ? fileName : title }
    /// "Artist — Album", leaving out whichever is empty.
    var artistAndAlbum: String { [displayArtist, album].filter { !$0.isEmpty }.joined(separator: " — ") }

    /// Haystack for the search field, folded like everything else (`TextKey`).
    var searchText: String {
        if let cachedSearchText { return cachedSearchText }
        let text = TextKey.folded([title, artist, album, albumArtist, genre, composer].joined(separator: "\u{1}"))
        cachedSearchText = text
        return text
    }
    private var cachedSearchText: String?

    /// A text column's folded sort key, kept until the track's tags change (sorting 50k tracks
    /// by a text column otherwise folds every value again on each sort).
    func sortKey(_ keyPath: KeyPath<Track, String>) -> NSString {
        if let key = sortKeys[keyPath] { return key }
        let key = TextKey.folded(self[keyPath: keyPath]) as NSString
        sortKeys[keyPath] = key
        return key
    }
    private var sortKeys: [AnyKeyPath: NSString] = [:]

    /// Call after editing tags so search and sorting see the new values.
    func tagsDidChange() {
        cachedSearchText = nil
        sortKeys.removeAll()
    }

    /// Takes every stored value of `other` (the same track, freshly loaded), keeping this object.
    func update(from other: Track) {
        for column in Track.columns { column.copy(other, self) }
        tagsDidChange()
    }

    /// A copy for work off the main actor, which mustn't read tracks the main actor may be editing.
    func snapshot() -> Track {
        let copy = Track(id: id)
        for column in Track.columns { column.copy(self, copy) }
        copy.skipCount = skipCount
        return copy
    }

    // Comparable stand-ins for optional values, used by table sorting.
    var dateAddedSortKey: Double { dateAdded?.timeIntervalSinceReferenceDate ?? 0 }
    /// Round the Camelot wheel (1A, 1B, 2A, …); unknown keys last.
    var keySortKey: Int { key?.sortIndex ?? 100 }

    var key: MusicalKey? { MusicalKey(parsing: musicalKey) }
    var lastPlayedSortKey: Double { lastPlayed?.timeIntervalSinceReferenceDate ?? 0 }

    /// Older predicates and AppleScript use a few alternate spellings
    /// (raw column names like `albumartist`, or `disc`). Map those onto our
    /// properties and treat anything unknown as nil instead of raising.
    override func value(forUndefinedKey key: String) -> Any? {
        switch key.lowercased() {
        case "albumartist": return albumArtist
        case "disc", "discnumber": return discNumber
        case "totaldiscnumber", "totalnumberofdiscs": return totalNumberOfDiscs
        case "tracknumber": return trackNumber
        case "totaltracknumber", "totalnumberoftracks": return totalNumberOfTracks
        case "bitrate": return bitRate
        case "samplerate": return sampleRate
        case "bitdepth": return bitDepth
        case "filesize": return fileSize
        case "filename": return fileName
        case "filetype": return fileType
        case "playcount": return playCount
        case "skipcount", "skips": return skipCount
        case "dateadded": return dateAdded
        case "lastplayed": return lastPlayed
        case "datemodified": return dateModified
        case "datecreated": return dateCreated
        case "millisecondlength": return Int(length * 1000)
        default: return nil
        }
    }
}

struct Playlist: Identifiable, Hashable {
    enum Kind: Int {
        case regular = 0
        case smart = 1
        case folder = 2
    }

    let id: Int64
    var name: String
    var kind: Kind
    var parentID: Int64?
    var position: Int
    /// Human-readable predicate, for display only. Evaluation uses the archive.
    var predicateFormat: String?
    /// Child playlists, for folders. `nil` for leaves so OutlineGroup shows no disclosure triangle.
    var children: [Playlist]?

    var systemImage: String {
        switch kind {
        case .regular: "music.note.list"
        case .smart: "gearshape"
        case .folder: "folder"
        }
    }
}
