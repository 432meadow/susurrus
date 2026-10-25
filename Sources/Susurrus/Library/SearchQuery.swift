import Foundation

/// The search field's query: plain words (every one must match), `-word` to exclude, "quoted
/// phrases", and field scopes such as `artist:"aphex twin"`, `bpm:120-128`, `rating:>=4`,
/// `year:<1990`, `added:30d` (in the last 30 days), `played:>1y` (not in the last year), or
/// `key:8A` / `key:Am` (that key) and `key:~8A` (any key that mixes with it).
struct SearchQuery {
    enum TextField: String, CaseIterable {
        case title, artist, album, albumartist, genre, composer, comment, grouping, kind, file
    }

    enum NumberField: String, CaseIterable {
        case year, bpm, rating, plays, skips, track, disc, bitrate, time
    }

    enum DateField: String, CaseIterable {
        case added, played
    }

    enum Comparison: Equatable {
        case equal(Double)
        case less(Double, orEqual: Bool)
        case greater(Double, orEqual: Bool)
        case range(Double, Double)

        func matches(_ value: Double) -> Bool {
            switch self {
            case .equal(let target): abs(value - target) < 0.001
            case .less(let limit, let orEqual): orEqual ? value <= limit : value < limit
            case .greater(let limit, let orEqual): orEqual ? value >= limit : value > limit
            case .range(let low, let high): value >= low && value <= high
            }
        }
    }

    enum Condition: Equatable {
        case anywhere(String)
        case text(TextField, String)
        case number(NumberField, Comparison)
        /// Within the last `seconds` (or, `olderThan`, longer ago than that / never).
        case date(DateField, seconds: TimeInterval, olderThan: Bool)
        /// That key, or (`compatible`) any key that mixes with it.
        case key(MusicalKey, compatible: Bool)
    }

    struct Term: Equatable {
        var condition: Condition
        var negated = false
    }

    let terms: [Term]

    var isEmpty: Bool { terms.isEmpty }

    init(_ text: String) {
        terms = Self.tokenize(text).compactMap(Self.term)
    }

    func matches(_ track: Track, now: Date = Date()) -> Bool {
        terms.allSatisfy { term in Self.matches(term.condition, track, now: now) != term.negated }
    }

    // MARK: Parsing

    /// Splits on spaces outside double quotes; quotes are dropped.
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == " ", !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func term(_ token: String) -> Term? {
        var token = token.lowercased()
        var negated = false
        if token.hasPrefix("-"), token.count > 1 {
            negated = true
            token.removeFirst()
        }
        if let colon = token.firstIndex(of: ":") {
            let name = String(token[..<colon])
            let value = String(token[token.index(after: colon)...])
            if let condition = fieldCondition(name: name, value: value) {
                return Term(condition: condition, negated: negated)
            }
        }
        return token.isEmpty ? nil : Term(condition: .anywhere(TextKey.folded(token)), negated: negated)
    }

    private static let aliases: [String: String] = [
        "albumartist": "albumartist", "aa": "albumartist", "by": "artist",
        "format": "kind", "type": "kind", "filename": "file", "path": "file",
        "tempo": "bpm", "stars": "rating", "playcount": "plays", "skipcount": "skips", "length": "time", "duration": "time",
        "date": "added", "lastplayed": "played",
    ]

    private static func fieldCondition(name: String, value: String) -> Condition? {
        let name = aliases[name] ?? name
        guard !value.isEmpty else { return nil }
        if name == "key" {
            let compatible = value.hasPrefix("~")
            return MusicalKey(parsing: compatible ? String(value.dropFirst()) : value).map { .key($0, compatible: compatible) }
        }
        if let field = TextField(rawValue: name) {
            return .text(field, value)
        }
        if let field = NumberField(rawValue: name) {
            let parse: (String) -> Double? = field == .time ? parseTime : { Double($0) }
            return comparison(value, parse: parse).map { .number(field, $0) }
        }
        if let field = DateField(rawValue: name) {
            var value = Substring(value)
            var olderThan = false
            if value.hasPrefix(">") {
                olderThan = true
                value = value.dropFirst()
                if value.hasPrefix("=") { value = value.dropFirst() }
            } else if value.hasPrefix("<") {
                value = value.dropFirst()
                if value.hasPrefix("=") { value = value.dropFirst() }
            }
            return parseAge(String(value)).map { .date(field, seconds: $0, olderThan: olderThan) }
        }
        return nil
    }

    /// "4", ">=4", "<3.5", "120-128".
    private static func comparison(_ value: String, parse: (String) -> Double?) -> Comparison? {
        for (prefix, make) in [
            (">=", { Comparison.greater($0, orEqual: true) }), ("<=", { Comparison.less($0, orEqual: true) }),
            (">", { Comparison.greater($0, orEqual: false) }), ("<", { Comparison.less($0, orEqual: false) }),
            ("=", { Comparison.equal($0) }),
        ] as [(String, (Double) -> Comparison)] where value.hasPrefix(prefix) {
            return parse(String(value.dropFirst(prefix.count))).map(make)
        }
        if let dash = value.dropFirst().firstIndex(of: "-") {
            guard let low = parse(String(value[..<dash])), let high = parse(String(value[value.index(after: dash)...])) else { return nil }
            return .range(min(low, high), max(low, high))
        }
        return parse(value).map { .equal($0) }
    }

    /// Seconds from "245" or "4:05".
    private static func parseTime(_ text: String) -> Double? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let number = Double(part) else { return nil }
            seconds = seconds * 60 + number
        }
        return seconds
    }

    /// "30d", "2w", "6mo", "1y" (a bare number is days).
    private static func parseAge(_ text: String) -> TimeInterval? {
        let day = 86_400.0
        for (suffix, unit) in [("mo", 30 * day), ("d", day), ("w", 7 * day), ("m", 30 * day), ("y", 365 * day)] where text.hasSuffix(suffix) {
            return Double(text.dropLast(suffix.count)).map { $0 * unit }
        }
        return Double(text).map { $0 * day }
    }

    // MARK: Matching

    private static func matches(_ condition: Condition, _ track: Track, now: Date) -> Bool {
        switch condition {
        case .anywhere(let word):
            return track.searchText.contains(word)
        case .text(let field, let value):
            let haystack: String = switch field {
            case .title: track.title
            case .artist: track.artist + "\u{1}" + track.albumArtist
            case .album: track.album
            case .albumartist: track.albumArtist
            case .genre: track.genre
            case .composer: track.composer
            case .comment: track.comment
            case .grouping: track.grouping
            case .kind: track.fileType
            case .file: track.path
            }
            return haystack.range(of: value, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        case .number(let field, let comparison):
            let value: Double = switch field {
            case .year: Double(track.year)
            case .bpm: Double(track.bpm)
            case .rating: track.rating
            case .plays: Double(track.playCount)
            case .skips: Double(track.skipCount)
            case .track: Double(track.trackNumber)
            case .disc: Double(track.discNumber)
            case .bitrate: Double(track.bitRate)
            case .time: track.length
            }
            return comparison.matches(value)
        case .key(let key, let compatible):
            guard let trackKey = track.key else { return false }
            return compatible ? trackKey.isCompatible(with: key) : trackKey == key
        case .date(let field, let seconds, let olderThan):
            let date = field == .added ? track.dateAdded : track.lastPlayed
            guard let date else { return olderThan }
            let isRecent = now.timeIntervalSince(date) <= seconds
            return olderThan ? !isRecent : isRecent
        }
    }
}
