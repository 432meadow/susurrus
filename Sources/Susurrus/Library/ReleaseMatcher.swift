import Foundation

/// Matches a folder's worth of tracks to a MusicBrainz release's track list, and works out the
/// tag changes that follow from it.
enum ReleaseMatcher {
    /// What the matcher needs to know about one library track.
    struct Input: Sendable, Hashable {
        var id: Int64
        var title: String
        var artist: String
        var album: String
        var albumArtist: String
        var trackNumber: Int
        var discNumber: Int
        /// Seconds.
        var length: Double
        var path: String

        init(id: Int64, title: String = "", artist: String = "", album: String = "", albumArtist: String = "",
             trackNumber: Int = 0, discNumber: Int = 0, length: Double = 0, path: String = "") {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.albumArtist = albumArtist
            self.trackNumber = trackNumber
            self.discNumber = discNumber
            self.length = length
            self.path = path
        }

        init(_ track: Track) {
            self.init(id: track.id, title: track.title, artist: track.artist, album: track.album, albumArtist: track.albumArtist,
                      trackNumber: track.trackNumber, discNumber: track.discNumber, length: track.length, path: track.path)
        }

        var fileName: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    /// One track of the release, with where it sits.
    struct Slot: Sendable, Hashable {
        var disc: Int
        var discCount: Int
        var position: Int
        var tracksOnDisc: Int
        var title: String
        var artist: String
        /// Seconds; nil when MusicBrainz doesn't know.
        var length: Double?
    }

    struct Pair: Sendable, Hashable {
        var slot: Slot
        var score: Double
        /// Seconds between the file and the release track; nil when either length is unknown.
        var lengthDifference: Double?
        var titleSimilarity: Double
        var numberMatches: Bool
    }

    struct Match: Sendable, Identifiable {
        var release: MBRelease
        /// Library track ID → the release track it is.
        var pairs: [Int64: Pair]
        var inputCount: Int
        /// 0–1: how well the files and the track list line up, counting tracks left over on either side.
        var score: Double
        /// Every file paired, nothing left over, lengths within a few seconds: safe to apply unseen.
        var isConfident: Bool

        var id: String { release.id }
        var slotCount: Int { ReleaseMatcher.slots(of: release).count }
    }

    // MARK: Search terms

    /// The artist and album to search for: the tags most of the files agree on, else what the
    /// folder name says ("Artist - Album (2003) [FLAC]").
    static func searchTerms(for inputs: [Input], folderName: String) -> (artist: String, album: String) {
        func common(_ values: [String]) -> String {
            let counts = Dictionary(values.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }
        var artist = common(inputs.map { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist })
        var album = common(inputs.map(\.album))
        if album.isEmpty || artist.isEmpty {
            let parsed = parseFolderName(folderName)
            if album.isEmpty { album = parsed.album }
            if artist.isEmpty { artist = parsed.artist }
        }
        return (artist, album)
    }

    /// "Artist - Album (2003) [FLAC 24-96]" → ("Artist", "Album"); without a " - ", the whole
    /// name (minus bracketed notes) is the album.
    static func parseFolderName(_ name: String) -> (artist: String, album: String) {
        var text = name.replacingOccurrences(of: "_", with: " ")
        text = text.replacingOccurrences(of: #"\s*[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*\d{4}\s*-\s*"#, with: "", options: .regularExpression)  // "2003 - Album"
        let parts = text.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.count >= 2 {
            // "Artist - 2003 - Album" keeps the last part as the album.
            return (parts[0], parts.last!.replacingOccurrences(of: #"^\d{4}\s*"#, with: "", options: .regularExpression))
        }
        return ("", parts.first ?? name)
    }

    // MARK: Matching

    static func slots(of release: MBRelease) -> [Slot] {
        let media = (release.media ?? []).filter { !($0.tracks ?? []).isEmpty }
        var result: [Slot] = []
        for (index, medium) in media.enumerated() {
            let tracks = medium.tracks ?? []
            for (offset, track) in tracks.enumerated() {
                result.append(Slot(
                    disc: medium.position ?? index + 1, discCount: media.count,
                    position: track.position ?? offset + 1, tracksOnDisc: tracks.count,
                    title: track.title, artist: track.artistCredit?.text ?? release.artist,
                    length: track.length.map { Double($0) / 1000 }))
            }
        }
        return result
    }

    /// Pairs each file with the release track that fits it best (title, length, and track number
    /// from the tags or the file name), one to one.
    static func match(_ inputs: [Input], to release: MBRelease) -> Match {
        let slots = slots(of: release)
        let singleDisc = Set(slots.map(\.disc)).count <= 1
        var candidates: [(input: Int, slot: Int, pair: Pair)] = []
        for (i, input) in inputs.enumerated() {
            let number = numbers(of: input)
            for (s, slot) in slots.enumerated() {
                let similarity = titleSimilarity(input.title.isEmpty ? strippedFileName(input.fileName) : input.title, slot.title)
                let difference = input.length > 0 ? slot.length.map { abs($0 - input.length) } : nil
                let discMatches = number.disc == 0 ? (singleDisc || slot.disc == 1 || number.flat) : number.disc == slot.disc
                let numberMatches = number.track > 0
                    && ((discMatches && number.track == slot.position) || (number.flat && number.track == s + 1))
                let lengthScore = difference.map { max(0, 1 - $0 / 10) } ?? 0.5
                let numberScore = number.track > 0 ? (numberMatches ? 1.0 : 0) : 0.5
                let score = 0.4 * similarity + 0.35 * lengthScore + 0.25 * numberScore
                candidates.append((i, s, Pair(slot: slot, score: score, lengthDifference: difference,
                                              titleSimilarity: similarity, numberMatches: numberMatches)))
            }
        }
        candidates.sort { ($0.pair.score, -$0.input, -$0.slot) > ($1.pair.score, -$1.input, -$1.slot) }

        var pairs: [Int64: Pair] = [:]
        var usedInputs = Set<Int>(), usedSlots = Set<Int>()
        for candidate in candidates where candidate.pair.score >= 0.35 {
            guard !usedInputs.contains(candidate.input), !usedSlots.contains(candidate.slot) else { continue }
            usedInputs.insert(candidate.input)
            usedSlots.insert(candidate.slot)
            pairs[inputs[candidate.input].id] = candidate.pair
        }

        let total = pairs.values.reduce(0) { $0 + $1.score }
        let score = inputs.isEmpty || slots.isEmpty ? 0 : total / Double(max(inputs.count, slots.count))
        let lengths = pairs.values.compactMap(\.lengthDifference)
        let averageSimilarity = pairs.isEmpty ? 0 : pairs.values.reduce(0) { $0 + $1.titleSimilarity } / Double(pairs.count)
        let confident = !inputs.isEmpty && inputs.count == slots.count && pairs.count == inputs.count
            && lengths.count == pairs.count && lengths.allSatisfy { $0 <= 5 }
            && (averageSimilarity >= 0.6 || pairs.values.allSatisfy(\.numberMatches))
        return Match(release: release, pairs: pairs, inputCount: inputs.count, score: score, isConfident: confident)
    }

    /// The disc and track number from the tags, else from the file name ("03 Title", "1-03 Title",
    /// "103 Title"). `flat` = a number that counts across discs.
    private static func numbers(of input: Input) -> (disc: Int, track: Int, flat: Bool) {
        if input.trackNumber > 0 { return (input.discNumber, input.trackNumber, false) }
        let name = input.fileName
        if let match = name.firstMatch(of: #/^\s*(\d{1,2})[-\.](\d{1,3})\b/#) {
            return (Int(match.1) ?? 0, Int(match.2) ?? 0, false)
        }
        if let match = name.firstMatch(of: #/^\s*(\d{1,3})\b/#), let number = Int(match.1) {
            if match.1.count == 3, number >= 101 { return (number / 100, number % 100, false) }
            return (0, number, true)
        }
        return (0, 0, false)
    }

    /// The file name without a leading track number and "Artist - " prefix.
    private static func strippedFileName(_ name: String) -> String {
        var text = name.replacingOccurrences(of: #"^\s*\d{1,3}([-\.]\d{1,3})?[\s\.\-_]*"#, with: "", options: .regularExpression)
        if let dash = text.range(of: " - ") { text = String(text[dash.upperBound...]) }
        return text
    }

    /// 0–1: the share of words the two titles have in common (case, accents, punctuation and
    /// bracketed notes ignored; identical titles score 1).
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let x = DiscographyMatch.normalizedTitle(a), y = DiscographyMatch.normalizedTitle(b)
        if x == y { return x.isEmpty ? 0 : 1 }
        let wordsA = Set(x.split(separator: " ")), wordsB = Set(y.split(separator: " "))
        guard !wordsA.isEmpty, !wordsB.isEmpty else { return 0 }
        return Double(wordsA.intersection(wordsB).count) / Double(wordsA.union(wordsB).count)
    }

    /// Best first: closest match, then the earliest official edition.
    static func ranked(_ matches: [Match]) -> [Match] {
        matches.sorted {
            if $0.isConfident != $1.isConfident { return $0.isConfident }
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            let official0 = $0.release.status == "Official", official1 = $1.release.status == "Official"
            if official0 != official1 { return official0 }
            return ($0.release.date ?? "9999") < ($1.release.date ?? "9999")
        }
    }

    // MARK: Edits

    struct Fields: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let titles = Fields(rawValue: 1 << 0)
        static let artists = Fields(rawValue: 1 << 1)
        static let album = Fields(rawValue: 1 << 2)
        static let numbers = Fields(rawValue: 1 << 3)
        static let all: Fields = [.titles, .artists, .album, .numbers]
    }

    /// The edit for each paired track: only the fields asked for, and only where they differ.
    static func edits(for match: Match, inputs: [Input], fields: Fields = .all) -> [Int64: TrackEdit] {
        var result: [Int64: TrackEdit] = [:]
        let release = match.release
        for input in inputs {
            guard let slot = match.pairs[input.id]?.slot else { continue }
            var edit = TrackEdit()
            if fields.contains(.titles), input.title != slot.title { edit.title = slot.title }
            if fields.contains(.artists) {
                if input.artist != slot.artist { edit.artist = slot.artist }
                let albumArtist = release.isVariousArtists ? "Various Artists" : release.artist
                if input.albumArtist != albumArtist { edit.albumArtist = albumArtist }
                if release.isVariousArtists { edit.compilation = true }
            }
            if fields.contains(.album) {
                if input.album != release.title { edit.album = release.title }
                if let year = release.year { edit.year = year }
            }
            if fields.contains(.numbers) {
                edit.trackNumber = slot.position
                edit.trackCount = slot.tracksOnDisc
                edit.discNumber = slot.disc
                edit.discCount = slot.discCount
            }
            result[input.id] = edit
        }
        return result
    }

    // MARK: Organizing

    /// "Album Artist/Album (Year)" under `root`, each part made safe for a folder name.
    static func albumFolder(under root: URL, albumArtist: String, album: String, year: Int?) -> URL {
        root.appendingPathComponent(albumFolderPath(albumArtist: albumArtist, album: album, year: year), isDirectory: true)
    }

    /// "Album Artist/Album (Year)", relative to wherever albums are kept.
    static func albumFolderPath(albumArtist: String, album: String, year: Int?) -> String {
        let artistPart = safeName(albumArtist.isEmpty ? "Unknown Artist" : albumArtist)
        let albumPart = safeName((album.isEmpty ? "Unknown Album" : album) + (year.map { " (\($0))" } ?? ""))
        return artistPart + "/" + albumPart
    }

    /// "03 Title.flac", or "1-03 Title.flac" on a release with several discs.
    static func fileName(for slot: Slot, extension ext: String) -> String {
        let number = String(format: "%02d", slot.position)
        let prefix = slot.discCount > 1 ? "\(slot.disc)-\(number)" : number
        let name = safeName("\(prefix) \(slot.title)")
        return ext.isEmpty ? name : "\(name).\(ext)"
    }

    /// No slashes or colons, no leading dots, at most 120 characters.
    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 120 { cleaned = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
