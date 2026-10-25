import Foundation

/// ID3v2.2 / v2.3 / v2.4 tags at the start of MP3 files.
///
/// Only the frames for edited fields are replaced. Every other frame (artwork, TXXX, iTunes'
/// COMM frames, PRIV, …) is copied over with its original header and bytes, in order. An edited
/// frame that changes size moves to the end, so changing it again doesn't shift other frames
/// (such as the cover). The tag keeps its version (v2.2 keeps its 3-letter frames); files without
/// a tag get a new v2.3 one (the version most of the library uses and every player reads). ID3v1
/// and APE tags at the end of the file are left as they are.
enum ID3Tag: TagFormat {
    struct Frame: Equatable {
        var id: String
        /// The header (10 bytes; 6 in v2.2) plus body, exactly as stored.
        var raw: [UInt8]
        var headerSize: Int { id.count == 3 ? 6 : 10 }
        var body: ArraySlice<UInt8> { raw[headerSize...] }
    }

    /// v2.2's 3-letter names for the frames susurrus writes or reads.
    private static let v22Names: [String: String] = [
        "TIT2": "TT2", "TPE1": "TP1", "TALB": "TAL", "TPE2": "TP2", "TCON": "TCO", "TCOM": "TCM",
        "TIT1": "TT1", "TYER": "TYE", "TRCK": "TRK", "TPOS": "TPA", "TBPM": "TBP", "TKEY": "TKE", "TCMP": "TCP",
        "COMM": "COM", "POPM": "POP", "APIC": "PIC",
    ]

    /// A frame's name in this tag version (nil: v2.2 has no such frame).
    private static func name(_ id: String, _ version: UInt8) -> String? {
        version == 2 ? v22Names[id] : id
    }

    struct Parsed {
        var version: UInt8
        var frames: [Frame]
        /// Size of the tag's body (frames + padding) from its header; 0 without a tag.
        var declaredSize: Int
        /// Offset of the first byte after the tag (header, body and any footer).
        var end: Int
    }

    /// Frame IDs replaced for each field. The first is written; the others are cleared (except
    /// grouping's GRP1, which is updated only if already there).
    private static func ids(for field: PartialKeyPath<TagValues>, version: UInt8) -> [String] {
        let ids: [String] = switch field {
        case \TagValues.title: ["TIT2"]
        case \TagValues.artist: ["TPE1"]
        case \TagValues.album: ["TALB"]
        case \TagValues.albumArtist: ["TPE2"]
        case \TagValues.genre: ["TCON"]
        case \TagValues.composer: ["TCOM"]
        case \TagValues.grouping: ["TIT1", "GRP1"]
        case \TagValues.year: version == 4 ? ["TDRC", "TYER"] : ["TYER", "TDRC"]
        case \TagValues.track: ["TRCK"]
        case \TagValues.disc: ["TPOS"]
        case \TagValues.bpm: ["TBPM"]
        case \TagValues.key: ["TKEY"]
        case \TagValues.compilation: ["TCMP"]
        default: []
        }
        return ids.compactMap { name($0, version) }
    }

    static let ratingEmail = "Windows Media Player 9 Series"

    // MARK: Parsing

    static func parse(_ bytes: [UInt8]) throws -> Parsed {
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else {
            return Parsed(version: 3, frames: [], declaredSize: 0, end: 0)
        }
        let version = bytes[3], flags = bytes[5]
        guard (2...4).contains(version) else {
            throw TagWriteError.unsupportedTag("ID3v2.\(version)")
        }
        guard flags & 0x80 == 0 else { throw TagWriteError.unsupportedTag("An unsynchronised ID3 tag") }
        guard version != 2 || flags & 0x40 == 0 else { throw TagWriteError.unsupportedTag("A compressed ID3v2.2 tag") }
        guard let size = syncsafe(bytes, at: 6) else { throw TagWriteError.malformed("bad ID3 size") }
        let bodyStart = 10, bodyEnd = 10 + size
        let end = bodyEnd + (version == 4 && flags & 0x10 != 0 ? 10 : 0)
        guard end <= bytes.count else { throw TagWriteError.malformed("ID3 tag runs past the end of the file") }

        var pos = bodyStart
        if flags & 0x40 != 0 {  // extended header: dropped on rewrite (its CRC would be stale anyway)
            guard pos + 4 <= bodyEnd else { throw TagWriteError.malformed("bad extended header") }
            if version == 3 {
                pos += 4 + Int(bytes.uint32BE(at: pos))
            } else {
                guard let extSize = syncsafe(bytes, at: pos) else { throw TagWriteError.malformed("bad extended header") }
                pos += extSize
            }
            guard pos <= bodyEnd else { throw TagWriteError.malformed("bad extended header") }
        }

        let idLength = version == 2 ? 3 : 4, headerSize = version == 2 ? 6 : 10
        var frames: [Frame] = []
        while pos + headerSize <= bodyEnd, bytes[pos] != 0 {
            guard isFrameID(bytes, at: pos, length: idLength) else { throw TagWriteError.malformed("unreadable frame at byte \(pos)") }
            var frameSize = version == 2 ? bytes.uint24BE(at: pos + 3) : Int(bytes.uint32BE(at: pos + 4))
            if version == 4 {
                // v2.4 sizes are syncsafe, but old iTunes wrote plain ones; use whichever lands on
                // a frame boundary.
                let safe = syncsafe(bytes, at: pos + 4)
                if let safe, landsOnBoundary(bytes, at: pos + 10 + safe, end: bodyEnd) {
                    frameSize = safe
                } else if !landsOnBoundary(bytes, at: pos + 10 + frameSize, end: bodyEnd) {
                    throw TagWriteError.malformed("frame size at byte \(pos)")
                }
            }
            let frameEnd = pos + headerSize + frameSize
            guard frameEnd <= bodyEnd else { throw TagWriteError.malformed("frame runs past the tag") }
            frames.append(Frame(id: bytes.ascii(pos..<pos + idLength), raw: Array(bytes[pos..<frameEnd])))
            pos = frameEnd
        }
        return Parsed(version: version, frames: frames, declaredSize: size, end: end)
    }

    static func tagRegion(in prefix: [UInt8]) -> TagRegion {
        guard prefix.count >= 10 else { return .needMore }
        guard prefix[0] == 0x49, prefix[1] == 0x44, prefix[2] == 0x33, let size = syncsafe(prefix, at: 6) else { return .none }
        return .length(10 + size + (prefix[3] == 4 && prefix[5] & 0x10 != 0 ? 10 : 0))
    }

    private static func syncsafe(_ bytes: [UInt8], at i: Int) -> Int? {
        guard i + 4 <= bytes.count, bytes[i..<i + 4].allSatisfy({ $0 < 0x80 }) else { return nil }
        return Int(bytes[i]) << 21 | Int(bytes[i + 1]) << 14 | Int(bytes[i + 2]) << 7 | Int(bytes[i + 3])
    }

    private static func isFrameID(_ bytes: [UInt8], at i: Int, length: Int = 4) -> Bool {
        bytes[i..<i + length].allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) }
    }

    private static func landsOnBoundary(_ bytes: [UInt8], at i: Int, end: Int) -> Bool {
        i == end || (i < end && (bytes[i] == 0 || (i + 4 <= end && isFrameID(bytes, at: i))))
    }

    // MARK: Writing

    static func rewrite(_ bytes: [UInt8], with values: TagValues) throws -> [UInt8] {
        let parsed = try parse(bytes)
        let version = parsed.version
        var frames = parsed.frames

        // Replaces the frames `isOld` matches with `frame` (nil: removes them). A frame that keeps
        // its size keeps its place, so nothing else moves; one that grows or shrinks goes last,
        // before the padding, where changing it again moves nothing else either.
        func put(_ frame: Frame?, replacing isOld: (Frame) -> Bool) {
            let old = frames.indices.filter { isOld(frames[$0]) }
            let sameSize = old.count == 1 && frames[old[0]].raw.count == frame?.raw.count
            frames.removeAll(where: isOld)
            guard let frame else { return }
            frames.insert(frame, at: sameSize ? old[0] : frames.count)
        }
        func replace(_ ids: [String], with body: [UInt8]?) {
            guard !ids.isEmpty else { return }
            put(body.map { makeFrame(ids[0], body: $0, version: version) }, replacing: { ids.contains($0.id) })
        }
        func text(_ field: KeyPath<TagValues, String?>) {
            guard let value = values[keyPath: field] else { return }
            let body = value.isEmpty ? nil : textBody(value, version: version)
            if field == \TagValues.grouping {
                // GRP1 (iTunes 12.5+ grouping) is updated alongside TIT1 only when the file uses it.
                if frames.contains(where: { $0.id == "GRP1" }) { replace(["GRP1"], with: body) }
                replace(ids(for: field, version: version).prefix(1).map { $0 }, with: body)
            } else {
                replace(ids(for: field, version: version), with: body)
            }
        }
        func number(_ field: KeyPath<TagValues, Int?>) {
            guard let value = values[keyPath: field] else { return }
            replace(ids(for: field, version: version), with: value > 0 ? textBody(String(value), version: version) : nil)
        }
        func pair(_ field: KeyPath<TagValues, TagValues.NumberPair?>) {
            guard let value = values[keyPath: field] else { return }
            let text = TagValues.numberText(value)
            replace(ids(for: field, version: version), with: text.isEmpty ? nil : textBody(text, version: version))
        }

        text(\.title)
        text(\.artist)
        text(\.album)
        text(\.albumArtist)
        text(\.genre)
        text(\.composer)
        text(\.grouping)
        number(\.year)
        pair(\.track)
        pair(\.disc)
        number(\.bpm)
        text(\.key)
        if let compilation = values.compilation {
            replace(ids(for: \TagValues.compilation, version: version), with: compilation ? textBody("1", version: version) : nil)
        }
        if let comment = values.comment {
            put(comment.isEmpty ? nil : makeFrame(name("COMM", version)!, body: commentBody(comment, version: version), version: version),
                replacing: isPlainComment)
        }
        if let rating = values.rating {
            let byte = POPMRating.byte(for: rating)
            var found = false
            let popm = name("POPM", version)!
            for i in frames.indices where frames[i].id == popm {
                // Body: email, NUL, rating byte, optional play counter. Keep email and counter.
                var body = Array(frames[i].body)
                guard let nul = body.firstIndex(of: 0), nul + 1 < body.count else { continue }
                body[nul + 1] = byte
                frames[i] = makeFrame(popm, body: body, version: version, flags: version == 2 ? [] : Array(frames[i].raw[8..<10]))
                found = true
            }
            if !found, byte > 0 {
                frames.append(makeFrame(popm, body: Array(ratingEmail.utf8) + [0, byte], version: version))
            }
        }

        if let artwork = values.artwork {
            put(artwork.data.isEmpty ? nil : makeFrame(name("APIC", version)!, body: pictureBody(artwork, version: version), version: version),
                replacing: isFrontCover)
        }

        let frameBytes = frames.flatMap(\.raw)
        // Keep the old tag size when the frames still fit, so the audio stays at the same offset;
        // otherwise leave a little room for next time.
        let padding = frameBytes.count <= parsed.declaredSize ? parsed.declaredSize - frameBytes.count : 2048
        let size = frameBytes.count + padding
        guard size < 1 << 28 else { throw TagWriteError.malformed("tag too large") }
        let header: [UInt8] = [0x49, 0x44, 0x33, version, 0, 0] + syncsafeBytes(size)
        return header + frameBytes + [UInt8](repeating: 0, count: padding) + Array(bytes[parsed.end...])
    }

    private static func makeFrame(_ id: String, body: [UInt8], version: UInt8, flags: [UInt8] = [0, 0]) -> Frame {
        if version == 2 { return Frame(id: id, raw: Array(id.utf8) + [UInt8].be24(body.count) + body) }
        let size = version == 4 ? syncsafeBytes(body.count) : [UInt8].be32(body.count)
        return Frame(id: id, raw: Array(id.utf8) + size + flags + body)
    }

    private static func syncsafeBytes(_ value: Int) -> [UInt8] {
        [UInt8(value >> 21 & 0x7F), UInt8(value >> 14 & 0x7F), UInt8(value >> 7 & 0x7F), UInt8(value & 0x7F)]
    }

    /// v2.4: UTF-8. v2.2/v2.3: Latin-1 when possible, else UTF-16 with BOM.
    private static func encode(_ string: String, version: UInt8) -> (encoding: UInt8, bytes: [UInt8]) {
        if version == 4 { return (3, Array(string.utf8)) }
        if string.unicodeScalars.allSatisfy({ $0.value < 0x100 }) {
            return (0, string.unicodeScalars.map { UInt8($0.value) })
        }
        return (1, [0xFF, 0xFE] + string.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
    }

    private static func textBody(_ string: String, version: UInt8) -> [UInt8] {
        let (encoding, bytes) = encode(string, version: version)
        return [encoding] + bytes
    }

    private static func commentBody(_ string: String, version: UInt8) -> [UInt8] {
        let (encoding, bytes) = encode(string, version: version)
        // Language, then an empty description (terminator only; UTF-16 needs a BOM before it).
        let description: [UInt8] = encoding == 1 ? [0xFF, 0xFE, 0, 0] : [0]
        return [encoding] + Array("eng".utf8) + description + bytes
    }

    /// A front cover (picture type 3) with an empty description. v2.2's PIC names the format with
    /// three letters instead of a MIME type.
    private static func pictureBody(_ artwork: Artwork, version: UInt8) -> [UInt8] {
        let format = version == 2 ? Array((artwork.isPNG ? "PNG" : "JPG").utf8) : Array(artwork.mimeType.utf8) + [0]
        return [0] + format + [3, 0] + [UInt8](artwork.data)
    }

    /// An APIC/PIC frame's picture type, MIME type and image bytes.
    static func picture(_ frame: Frame) -> (type: UInt8, mimeType: String, data: [UInt8])? {
        guard frame.id == "APIC" || frame.id == "PIC" else { return nil }
        let body = Array(frame.body)
        guard body.count >= 5 else { return nil }
        let encoding = body[0]
        let mimeType: String, typeIndex: Int
        if frame.id == "PIC" {
            mimeType = body.ascii(1..<4).uppercased() == "PNG" ? "image/png" : "image/jpeg"
            typeIndex = 4
        } else {
            guard let nul = body[1...].firstIndex(of: 0), nul + 1 < body.count else { return nil }
            let declared = body.ascii(1..<nul).lowercased()
            mimeType = declared.contains("png") ? "image/png" : "image/jpeg"
            typeIndex = nul + 1
        }
        guard let dataStart = afterTerminator(body, from: typeIndex + 1, wide: encoding == 1 || encoding == 2) else { return nil }
        return (body[typeIndex], mimeType, Array(body[dataStart...]))
    }

    /// The index just past a text field's terminator (one NUL, or two for UTF-16).
    private static func afterTerminator(_ bytes: [UInt8], from start: Int, wide: Bool) -> Int? {
        var i = start
        while i < bytes.count {
            if wide {
                if i + 1 < bytes.count, bytes[i] == 0, bytes[i + 1] == 0 { return i + 2 }
                i += 2
            } else {
                if bytes[i] == 0 { return i + 1 }
                i += 1
            }
        }
        return nil
    }

    /// Front covers are what susurrus writes; other pictures (back cover, artist, …) are kept.
    private static func isFrontCover(_ frame: Frame) -> Bool {
        picture(frame)?.type == 3
    }

    /// COMM frames with an empty description hold the user's comment; others (iTunNORM,
    /// iTunSMPB gapless info, …) belong to other apps and are never touched.
    private static func isPlainComment(_ frame: Frame) -> Bool {
        guard frame.id == "COMM" || frame.id == "COM", let (description, _) = splitComment(frame) else { return false }
        return description.isEmpty
    }

    private static func splitComment(_ frame: Frame) -> (description: String, text: String)? {
        let body = Array(frame.body)
        guard body.count >= 4 else { return nil }
        let encoding = body[0]
        let rest = Array(body[4...])
        let wide = encoding == 1 || encoding == 2
        var end = 0
        while end < rest.count {
            if wide {
                if end + 1 < rest.count, rest[end] == 0, rest[end + 1] == 0 { break }
                end += 2
            } else {
                if rest[end] == 0 { break }
                end += 1
            }
        }
        guard end < rest.count else { return nil }
        let description = decode(Array(rest[..<end]), encoding: encoding)
        let text = decode(Array(rest[min(rest.count, end + (wide ? 2 : 1))...]), encoding: encoding)
        return (description, text)
    }

    // MARK: Reading back

    static func read(_ bytes: [UInt8]) throws -> TagValues {
        let parsed = try parse(bytes)
        func text(_ id: String) -> String? {
            guard let id = name(id, parsed.version),
                  let frame = parsed.frames.first(where: { $0.id == id }), let encoding = frame.body.first else { return nil }
            return decode(Array(frame.body.dropFirst()), encoding: encoding)
        }
        func number(_ id: String) -> Int? { text(id).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        func pair(_ id: String) -> TagValues.NumberPair? {
            text(id).map { let (n, t) = TagReader.numberPair($0); return TagValues.NumberPair(number: n, total: t) }
        }
        var values = TagValues()
        values.title = text("TIT2")
        values.artist = text("TPE1")
        values.album = text("TALB")
        values.albumArtist = text("TPE2")
        values.genre = text("TCON")
        values.composer = text("TCOM")
        values.grouping = text("TIT1")
        values.year = (text("TYER") ?? text("TDRC")).flatMap { Int($0.prefix(4)) }
        values.track = pair("TRCK")
        values.disc = pair("TPOS")
        values.bpm = number("TBPM")
        values.key = text("TKEY")
        values.compilation = text("TCMP").map { $0 == "1" }
        values.comment = parsed.frames.lazy.filter(isPlainComment).compactMap { splitComment($0)?.text }.first
        if let popm = parsed.frames.first(where: { $0.id == name("POPM", parsed.version) }) {
            let body = Array(popm.body)
            if let nul = body.firstIndex(of: 0), nul + 1 < body.count { values.rating = POPMRating.rating(for: body[nul + 1]) }
        }
        if let cover = parsed.frames.lazy.compactMap(picture).first(where: { $0.type == 3 }) {
            values.artwork = Artwork(data: Data(cover.data), mimeType: cover.mimeType)
        }
        return values
    }

    static func decode(_ bytes: [UInt8], encoding: UInt8) -> String {
        var string: String
        switch encoding {
        case 0: string = String(decoding: bytes.map { UInt16($0) }, as: UTF16.self)
        case 1, 2:
            var units: [UInt16] = []
            var bigEndian = encoding == 2
            var start = 0
            if bytes.count >= 2, encoding == 1 {
                if bytes[0] == 0xFE, bytes[1] == 0xFF { bigEndian = true; start = 2 }
                else if bytes[0] == 0xFF, bytes[1] == 0xFE { start = 2 }
            }
            var i = start
            while i + 1 < bytes.count {
                units.append(bigEndian ? UInt16(bytes[i]) << 8 | UInt16(bytes[i + 1]) : UInt16(bytes[i + 1]) << 8 | UInt16(bytes[i]))
                i += 2
            }
            string = String(decoding: units, as: UTF16.self)
        default: string = String(decoding: bytes, as: UTF8.self)
        }
        while string.hasSuffix("\0") { string.removeLast() }
        return string
    }

    // MARK: Verifying

    static func verify(original: [UInt8], rewritten: [UInt8], values: TagValues) throws {
        let before = try parse(original)
        let after: Parsed
        do { after = try parse(rewritten) } catch { throw TagWriteError.verificationFailed("tag doesn't parse") }
        guard after.version == before.version else { throw TagWriteError.verificationFailed("tag version changed") }
        guard rewritten[after.end...] == original[before.end...] else {
            throw TagWriteError.verificationFailed("audio data differs")
        }
        guard values.isSatisfied(by: try read(rewritten)) else { throw TagWriteError.verificationFailed("tags read back differently") }

        // Frames for fields that weren't edited must survive unchanged and in order.
        var touched = Set<String>()
        for field in values.setFields { touched.formUnion(ids(for: field, version: before.version)) }
        if values.rating != nil { touched.insert(name("POPM", before.version)!) }
        func untouched(_ frames: [Frame]) -> [Frame] {
            frames.filter {
                !touched.contains($0.id) && !(values.comment != nil && isPlainComment($0))
                    && !(values.artwork != nil && isFrontCover($0))
            }
        }
        guard untouched(before.frames) == untouched(after.frames) else {
            throw TagWriteError.verificationFailed("other frames changed")
        }
    }
}
