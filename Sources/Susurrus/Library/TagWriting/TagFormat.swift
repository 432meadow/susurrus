import Foundation

enum TagWriteError: LocalizedError, Equatable {
    /// Not a format susurrus can write (WAV, AIFF, …).
    case unsupportedFormat(String)
    /// A tag layout susurrus won't touch (e.g. unsynchronised ID3, fragmented MP4).
    case unsupportedTag(String)
    case malformed(String)
    case verificationFailed(String)
    case modifiedSinceRead
    case fileMissing
    /// Writing the tags in place stopped partway, and the old bytes couldn't be put back either.
    case partlyWritten

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let kind): "\(kind) files can't be tagged yet"
        case .unsupportedTag(let what): "\(what) isn't supported"
        case .malformed(let what): "The file's tags look damaged (\(what))"
        case .verificationFailed(let what): "The rewritten copy didn't check out (\(what)); the original was left alone"
        case .modifiedSinceRead: "The file changed while susurrus was writing it; skipped"
        case .fileMissing: "The file isn't there (is the share mounted?)"
        case .partlyWritten: "Writing the tags stopped partway and the old ones couldn't be put back; check the file"
        }
    }
}

/// One container's tag reader/writer. Both functions work on the whole file in memory.
protocol TagFormat {
    /// The file with `values` written into its tags. Everything else (audio, other tags and frames)
    /// is carried over byte for byte.
    static func rewrite(_ bytes: [UInt8], with values: TagValues) throws -> [UInt8]
    /// Checks a rewritten file: its tags parse and hold `values`, fields that weren't edited are
    /// unchanged, and the audio data is identical to the original's.
    static func verify(original: [UInt8], rewritten: [UInt8], values: TagValues) throws
    /// The fields susurrus writes, as currently stored in the file (absent fields are nil).
    static func read(_ bytes: [UInt8]) throws -> TagValues
    /// Where the tags at the start of the file end, judging from its first bytes. A format
    /// returns `.length` only when `rewrite` and `verify` work on just those bytes, so a
    /// same-size rewrite can be patched into the file in place.
    static func tagRegion(in prefix: [UInt8]) -> TagRegion
}

enum TagRegion: Equatable {
    /// The tags are the file's first `n` bytes.
    case length(Int)
    /// The prefix ends inside the tags; read more.
    case needMore
    /// No leading tag region (no tag yet, or tags elsewhere in the file).
    case none
}

extension TagFormat {
    static func tagRegion(in prefix: [UInt8]) -> TagRegion { .none }
}

enum TagFormats {
    /// The handler for a file, by extension and then by its first bytes.
    static func handler(for url: URL, bytes: [UInt8]) throws -> TagFormat.Type {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp3":
            return ID3Tag.self
        case "flac":
            guard FLACTag.findMarker(bytes) != nil else { throw TagWriteError.malformed("no fLaC marker") }
            return FLACTag.self
        case "m4a", "m4b", "mp4", "alac":
            guard bytes.count >= 8, Array(bytes[4..<8]) == Array("ftyp".utf8) else { throw TagWriteError.malformed("no ftyp atom") }
            return MP4Tag.self
        default:
            throw TagWriteError.unsupportedFormat(ext.isEmpty ? "Extensionless" : ext.uppercased())
        }
    }

    static func canWrite(path: String) -> Bool {
        ["mp3", "flac", "m4a", "m4b", "mp4", "alac"].contains((path as NSString).pathExtension.lowercased())
    }
}

// MARK: - Byte helpers

extension Array where Element == UInt8 {
    func uint32BE(at i: Int) -> UInt32 {
        UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    func uint64BE(at i: Int) -> UInt64 { UInt64(uint32BE(at: i)) << 32 | UInt64(uint32BE(at: i + 4)) }

    func uint32LE(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }

    func uint24BE(at i: Int) -> Int { Int(self[i]) << 16 | Int(self[i + 1]) << 8 | Int(self[i + 2]) }

    func ascii(_ range: Range<Int>) -> String { String(decoding: self[range], as: UTF8.self) }

    static func be32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func be16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }

    static func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }

    static func be24(_ value: Int) -> [UInt8] { [UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
}
