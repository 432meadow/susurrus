import Foundation

/// Fast stand-in for `[Track].sort(using: [KeyPathComparator<Track>])`.
///
/// `KeyPathComparator`'s String comparison is localized and resolves the locale on every call, so
/// sorting 50k tracks by a text column took about two seconds on the main thread. Here each
/// track's key is folded once (`Track.sortKey`, kept until its tags change) and then compared
/// numerically, which orders like Finder ("Track 2" before "Track 10") in a fraction of the time.
/// Main actor only: the folded keys are cached on the tracks.
enum TrackSort {
    static func sorted(_ tracks: [Track], by comparators: [KeyPathComparator<Track>]) -> [Track] {
        guard !comparators.isEmpty, tracks.count > 1 else { return tracks }
        let columns = comparators.map { comparator in
            (keys: tracks.map { Key($0, comparator.keyPath) }, ascending: comparator.order == .forward)
        }
        let order = tracks.indices.sorted { a, b in
            for column in columns {
                let result = column.keys[a].compare(column.keys[b])
                if result != .orderedSame {
                    return (result == .orderedAscending) == column.ascending
                }
            }
            return a < b  // keep ties in their current order
        }
        return order.map { tracks[$0] }
    }

    private enum Key {
        case text(NSString)
        case number(Double)
        case none

        init(_ track: Track, _ keyPath: PartialKeyPath<Track>) {
            if let text = keyPath as? KeyPath<Track, String> {
                self = .text(track.sortKey(text))
                return
            }
            switch track[keyPath: keyPath] {
            case let number as Int: self = .number(Double(number))
            case let number as Int64: self = .number(Double(number))
            case let number as Double: self = .number(number)
            case let flag as Bool: self = .number(flag ? 1 : 0)
            case let date as Date: self = .number(date.timeIntervalSinceReferenceDate)
            default: self = .none
            }
        }

        func compare(_ other: Key) -> ComparisonResult {
            switch (self, other) {
            case let (.text(a), .text(b)):
                return a.compare(b as String, options: [.numeric, .literal])
            case let (.number(a), .number(b)):
                return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
            case (.none, .none):
                return .orderedSame
            case (.none, _):
                return .orderedAscending
            case (_, .none):
                return .orderedDescending
            default:
                return .orderedSame
            }
        }
    }
}
