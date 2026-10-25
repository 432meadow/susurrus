import Foundation
import ImageIO

/// Vorbis comments and the front cover in FLAC files.
///
/// Only the comment block (and, when the cover is edited, the front-cover PICTURE block) changes:
/// comments for edited fields are replaced, all others (and the vendor string) are kept in order.
/// Other metadata blocks (STREAMINFO, other pictures, seek table, …) are copied byte for byte, in
/// order. Padding absorbs the size change when it can, so the audio frames usually stay at the same
/// offset; for that the comment block may move into the padding (see `keepSize`).
enum FLACTag: TagFormat {
    struct Block: Equatable {
        var type: UInt8
        var body: [UInt8]
    }

    struct Parsed {
        /// Offset of "fLaC" (after an ID3v2 tag some taggers put in front, which is kept as is).
        var marker: Int
        var blocks: [Block]
        /// Offset of the first audio frame.
        var audioStart: Int
    }

    struct Comments: Equatable {
        var vendor: [UInt8]
        /// "KEY=value" strings in file order.
        var entries: [String]
    }

    /// Keys per field; the first is written, the rest are aliases that get removed.
    static let keys: [PartialKeyPath<TagValues>: [String]] = [
        \TagValues.title: ["TITLE"],
        \TagValues.artist: ["ARTIST"],
        \TagValues.album: ["ALBUM"],
        \TagValues.albumArtist: ["ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"],
        \TagValues.genre: ["GENRE"],
        \TagValues.composer: ["COMPOSER"],
        \TagValues.grouping: ["GROUPING"],
        \TagValues.comment: ["COMMENT", "DESCRIPTION"],
        \TagValues.year: ["DATE", "YEAR"],
        \TagValues.bpm: ["BPM"],
        \TagValues.key: ["INITIALKEY", "KEY"],
        \TagValues.compilation: ["COMPILATION"],
        // RATING is 0–100 (20 per star), as already found in this library's FLAC files.
        \TagValues.rating: ["RATING"],
    ]
    static let trackKeys = ["TRACKNUMBER", "TRACKTOTAL", "TOTALTRACKS"]
    static let discKeys = ["DISCNUMBER", "DISCTOTAL", "TOTALDISCS"]

    static func findMarker(_ bytes: [UInt8]) -> Int? {
        var offset = 0
        if bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
           bytes[6..<10].allSatisfy({ $0 < 0x80 }) {
            offset = 10 + (Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9]))
            if bytes[5] & 0x10 != 0 { offset += 10 }
        }
        guard offset + 4 <= bytes.count, bytes[offset..<offset + 4].elementsEqual("fLaC".utf8) else { return nil }
        return offset
    }

    static func tagRegion(in prefix: [UInt8]) -> TagRegion {
        guard let marker = findMarker(prefix) else { return .none }
        var pos = marker + 4
        while true {
            guard pos + 4 <= prefix.count else { return .needMore }
            let header = prefix[pos]
            pos += 4 + prefix.uint24BE(at: pos + 1)
            if header & 0x80 != 0 { return .length(pos) }
        }
    }

    static func parse(_ bytes: [UInt8]) throws -> Parsed {
        guard let marker = findMarker(bytes) else { throw TagWriteError.malformed("no fLaC marker") }
        var pos = marker + 4
        var blocks: [Block] = []
        while true {
            guard pos + 4 <= bytes.count else { throw TagWriteError.malformed("metadata runs past the end") }
            let header = bytes[pos]
            let length = bytes.uint24BE(at: pos + 1)
            guard pos + 4 + length <= bytes.count else { throw TagWriteError.malformed("metadata block runs past the end") }
            blocks.append(Block(type: header & 0x7F, body: Array(bytes[pos + 4..<pos + 4 + length])))
            pos += 4 + length
            if header & 0x80 != 0 { break }
        }
        guard blocks.first?.type == 0 else { throw TagWriteError.malformed("STREAMINFO isn't first") }
        guard blocks.filter({ $0.type == 4 }).count <= 1 else { throw TagWriteError.unsupportedTag("More than one Vorbis comment block") }
        return Parsed(marker: marker, blocks: blocks, audioStart: pos)
    }

    static func parseComments(_ body: [UInt8]) throws -> Comments {
        var pos = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, pos + count <= body.count else { throw TagWriteError.malformed("truncated Vorbis comment") }
            defer { pos += count }
            return body[pos..<pos + count]
        }
        func length() throws -> Int { let slice = Array(try take(4)); return Int(slice.uint32LE(at: 0)) }
        let vendor = Array(try take(try length()))
        let count = try length()
        var entries: [String] = []
        for _ in 0..<count {
            guard let entry = String(bytes: try take(try length()), encoding: .utf8) else {
                throw TagWriteError.malformed("comment isn't UTF-8")
            }
            entries.append(entry)
        }
        return Comments(vendor: vendor, entries: entries)
    }

    static func encodeComments(_ comments: Comments) -> [UInt8] {
        var out = [UInt8].le32(comments.vendor.count) + comments.vendor + [UInt8].le32(comments.entries.count)
        for entry in comments.entries {
            let utf8 = Array(entry.utf8)
            out += [UInt8].le32(utf8.count) + utf8
        }
        return out
    }

    private static func key(of entry: String) -> String {
        String(entry.prefix { $0 != "=" }).uppercased()
    }

    /// Keys whose comments an edit replaces.
    static func touchedKeys(_ values: TagValues) -> Set<String> {
        var result = Set<String>()
        for field in values.setFields { result.formUnion(keys[field] ?? []) }
        if values.track != nil { result.formUnion(trackKeys) }
        if values.disc != nil { result.formUnion(discKeys) }
        return result
    }

    static func rewrite(_ bytes: [UInt8], with values: TagValues) throws -> [UInt8] {
        let parsed = try parse(bytes)
        var blocks = parsed.blocks
        let commentIndex = blocks.firstIndex { $0.type == 4 }
        var comments = try commentIndex.map { try parseComments(blocks[$0].body) }
            ?? Comments(vendor: Array("susurrus".utf8), entries: [])

        let touched = touchedKeys(values)
        comments.entries.removeAll { touched.contains(key(of: $0)) }
        func add(_ key: String, _ value: String) { if !value.isEmpty { comments.entries.append("\(key)=\(value)") } }
        func number(_ n: Int) -> String { n > 0 ? String(n) : "" }
        if let v = values.title { add("TITLE", v) }
        if let v = values.artist { add("ARTIST", v) }
        if let v = values.album { add("ALBUM", v) }
        if let v = values.albumArtist { add("ALBUMARTIST", v) }
        if let v = values.genre { add("GENRE", v) }
        if let v = values.composer { add("COMPOSER", v) }
        if let v = values.grouping { add("GROUPING", v) }
        if let v = values.comment { add("COMMENT", v) }
        if let v = values.year { add("DATE", number(v)) }
        if let v = values.track {
            add("TRACKNUMBER", number(v.number))
            add("TRACKTOTAL", number(v.total))
        }
        if let v = values.disc {
            add("DISCNUMBER", number(v.number))
            add("DISCTOTAL", number(v.total))
        }
        if let v = values.bpm { add("BPM", number(v)) }
        if let v = values.key { add("INITIALKEY", v) }
        if let v = values.compilation { add("COMPILATION", v ? "1" : "") }
        if let v = values.rating { add("RATING", number(Int((v.clamped(to: 0...5) * 20).rounded()))) }

        let body = encodeComments(comments)
        guard body.count < 1 << 24 else { throw TagWriteError.malformed("comments too large") }
        if let commentIndex {
            blocks[commentIndex].body = body
        } else if !touched.isEmpty {
            blocks.insert(Block(type: 4, body: body), at: 1)
        }
        if let artwork = values.artwork {
            let index = blocks.firstIndex(where: isFrontCover)
            blocks.removeAll(where: isFrontCover)
            if !artwork.data.isEmpty {
                let picture = pictureBody(artwork)
                guard picture.count < 1 << 24 else { throw TagWriteError.unsupportedTag("A cover over 16 MB") }
                let afterLast = (blocks.lastIndex { $0.type != 1 } ?? 0) + 1
                blocks.insert(Block(type: 6, body: picture), at: index ?? afterLast)
            }
        }
        keepSize(&blocks, of: parsed.blocks)

        var out = Array(bytes[..<parsed.marker]) + Array("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            let last: UInt8 = index == blocks.count - 1 ? 0x80 : 0
            out += [last | block.type] + [UInt8].be24(block.body.count) + block.body
        }
        return out + Array(bytes[parsed.audioStart...])
    }

    /// Lets padding take up a change in the metadata's size so the audio doesn't move, moving as
    /// few other bytes as possible (the fast path rewrites only the bytes that differ). When only
    /// the comments changed size:
    /// 1. padding right after them gives or takes the difference;
    /// 2. if they shrank by 4 bytes or more, the room left becomes new padding right after them;
    /// 3. else they move into padding further on and their old place becomes padding of the same
    ///    size, so the blocks in between (usually the cover) stay where they are;
    /// 4. else the first padding with room takes the difference and moves right after them, so
    ///    the next edit is case 1.
    /// A cover change is taken up by the first padding with room, where it is. Without padding to
    /// spare, the metadata changes size. Only comments and padding move, so all other blocks keep
    /// their order (which `verify` requires).
    private static func keepSize(_ blocks: inout [Block], of original: [Block]) {
        func size(_ blocks: [Block]) -> Int { blocks.filter { $0.type != 1 }.reduce(0) { $0 + 4 + $1.body.count } }
        func padding(_ count: Int) -> Block { Block(type: 1, body: [UInt8](repeating: 0, count: count)) }
        let growth = size(blocks) - size(original)
        guard growth != 0 else { return }
        let oldComments = original.first { $0.type == 4 }
        guard let comments = blocks.firstIndex(where: { $0.type == 4 }),
              size([blocks[comments]]) - size(oldComments.map { [$0] } ?? []) == growth else {
            if let index = blocks.firstIndex(where: { $0.type == 1 && $0.body.count >= growth }) {
                blocks[index] = padding(blocks[index].body.count - growth)
            }
            return
        }
        if comments + 1 < blocks.count, blocks[comments + 1].type == 1, blocks[comments + 1].body.count >= growth {
            blocks[comments + 1] = padding(blocks[comments + 1].body.count - growth)
        } else if growth <= -4 {
            blocks.insert(padding(-growth - 4), at: comments + 1)
        } else if let target = blocks.indices.first(where: {
            // Room for the comments, and for nothing or a whole padding block after them.
            let room = blocks[$0].body.count - blocks[comments].body.count
            return $0 > comments && blocks[$0].type == 1 && (room == 0 || room >= 4)
        }) {
            let moved = blocks[comments]
            let rest = blocks[target].body.count - blocks[comments].body.count - 4
            if rest >= 0 { blocks[target] = padding(rest) } else { blocks.remove(at: target) }
            blocks.insert(moved, at: target)
            if let oldComments {
                blocks[comments] = padding(oldComments.body.count)
            } else {
                blocks.remove(at: comments)
            }
        } else if let index = blocks.firstIndex(where: { $0.type == 1 && $0.body.count >= growth }) {
            let absorbing = padding(blocks.remove(at: index).body.count - growth)
            blocks.insert(absorbing, at: blocks.firstIndex { $0.type == 4 }! + 1)
        }
    }

    /// A front cover (picture type 3) with no description. Size and depth come from the image.
    static func pictureBody(_ artwork: Artwork) -> [UInt8] {
        var width = 0, height = 0, depth = 24
        if let source = CGImageSourceCreateWithData(artwork.data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            if let bits = properties[kCGImagePropertyDepth] as? Int {
                depth = bits * (properties[kCGImagePropertyHasAlpha] as? Bool == true ? 4 : 3)
            }
        }
        let mime = Array(artwork.mimeType.utf8)
        return [UInt8].be32(3) + [UInt8].be32(mime.count) + mime + [UInt8].be32(0)
            + [UInt8].be32(width) + [UInt8].be32(height) + [UInt8].be32(depth) + [UInt8].be32(0)
            + [UInt8].be32(artwork.data.count) + [UInt8](artwork.data)
    }

    /// A PICTURE block's picture type, MIME type and image bytes.
    static func picture(_ block: Block) -> (type: Int, mimeType: String, data: [UInt8])? {
        let body = block.body
        guard block.type == 6, body.count >= 32 else { return nil }
        let mimeLength = Int(body.uint32BE(at: 4))
        let descriptionAt = 8 + mimeLength
        guard descriptionAt + 4 <= body.count else { return nil }
        let dataLengthAt = descriptionAt + 4 + Int(body.uint32BE(at: descriptionAt)) + 16
        guard dataLengthAt + 4 <= body.count else { return nil }
        let dataStart = dataLengthAt + 4, dataLength = Int(body.uint32BE(at: dataLengthAt))
        guard dataStart + dataLength <= body.count else { return nil }
        return (Int(body.uint32BE(at: 0)), body.ascii(8..<descriptionAt), Array(body[dataStart..<dataStart + dataLength]))
    }

    private static func isFrontCover(_ block: Block) -> Bool { picture(block)?.type == 3 }

    static func read(_ bytes: [UInt8]) throws -> TagValues {
        let parsed = try parse(bytes)
        var values = try readComments(parsed)
        if let cover = parsed.blocks.lazy.compactMap(picture).first(where: { $0.type == 3 }) {
            values.artwork = Artwork(data: Data(cover.data), mimeType: cover.mimeType)
        }
        return values
    }

    private static func readComments(_ parsed: Parsed) throws -> TagValues {
        guard let block = parsed.blocks.first(where: { $0.type == 4 }) else { return TagValues() }
        let entries = try parseComments(block.body).entries
        func value(_ key: String) -> String? {
            entries.first { Self.key(of: $0) == key }.map { String($0.drop { $0 != "=" }.dropFirst()) }
        }
        func int(_ key: String) -> Int? { value(key).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func pair(_ numberKey: String, _ totalKey: String) -> TagValues.NumberPair? {
            guard value(numberKey) != nil || value(totalKey) != nil else { return nil }
            let (n, t) = TagReader.numberPair(value(numberKey) ?? "")
            return TagValues.NumberPair(number: n, total: int(totalKey) ?? t)
        }
        var values = TagValues()
        values.title = value("TITLE")
        values.artist = value("ARTIST")
        values.album = value("ALBUM")
        values.albumArtist = value("ALBUMARTIST")
        values.genre = value("GENRE")
        values.composer = value("COMPOSER")
        values.grouping = value("GROUPING")
        values.comment = value("COMMENT")
        values.year = value("DATE").flatMap { Int($0.prefix(4)) }
        values.track = pair("TRACKNUMBER", "TRACKTOTAL")
        values.disc = pair("DISCNUMBER", "DISCTOTAL")
        values.bpm = int("BPM")
        values.key = value("INITIALKEY")
        values.compilation = value("COMPILATION").map { $0 == "1" }
        values.rating = int("RATING").map { (Double($0) / 10).rounded() / 2 }
        return values
    }

    static func verify(original: [UInt8], rewritten: [UInt8], values: TagValues) throws {
        let before = try parse(original)
        let after: Parsed
        do { after = try parse(rewritten) } catch { throw TagWriteError.verificationFailed("metadata doesn't parse") }
        guard rewritten[..<after.marker] == original[..<before.marker],
              rewritten[after.audioStart...] == original[before.audioStart...] else {
            throw TagWriteError.verificationFailed("audio data differs")
        }
        func others(_ blocks: [Block]) -> [Block] {
            blocks.filter { $0.type != 4 && $0.type != 1 && !(values.artwork != nil && isFrontCover($0)) }
        }
        guard others(before.blocks) == others(after.blocks) else { throw TagWriteError.verificationFailed("other metadata changed") }
        let touched = touchedKeys(values)
        func untouched(_ parsed: Parsed) throws -> [String] {
            guard let block = parsed.blocks.first(where: { $0.type == 4 }) else { return [] }
            return try parseComments(block.body).entries.filter { !touched.contains(key(of: $0)) }
        }
        guard try untouched(before) == untouched(after) else { throw TagWriteError.verificationFailed("other comments changed") }
        guard values.isSatisfied(by: try read(rewritten)) else { throw TagWriteError.verificationFailed("tags read back differently") }
    }
}
