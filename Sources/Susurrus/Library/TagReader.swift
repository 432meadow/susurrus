import AVFoundation
import Foundation

/// A file's tags and audio properties, ready to insert into the library.
struct ScannedTrack: Sendable {
    var path: String
    var title = ""
    var artist = ""
    var album = ""
    var albumArtist = ""
    var genre = ""
    var composer = ""
    var comment = ""
    var year = 0
    var trackNumber = 0
    var trackCount = 0
    var discNumber = 0
    var discCount = 0
    var bpm = 0
    var musicalKey = ""
    var compilation = false
    var duration = 0.0
    var bitRate = 0
    var sampleRate = 0
    var channels = 0
    var fileSize: Int64 = 0
    var dateCreated: Date?
    var dateModified: Date?
    var bookmark: Data?
    /// Values that came from the file's name and folders rather than its tags.
    var inferred: InferredFields = []
}

/// Which of a scanned track's values were guessed from its file name and folders.
struct InferredFields: OptionSet, Sendable {
    let rawValue: Int
    static let title = InferredFields(rawValue: 1)
    static let album = InferredFields(rawValue: 2)
    static let artist = InferredFields(rawValue: 4)
}

/// Reads tags with AVFoundation (ID3, iTunes/MP4, and whatever it exposes for FLAC/WAV/AIFF),
/// falling back to the Artist/Album/Track folder layout for anything untagged.
enum TagReader {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "alac", "flac", "wav", "aif", "aiff", "aifc", "caf", "mp4"]

    static func isAudioFile(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    static func read(_ url: URL) async -> ScannedTrack? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else {
            return nil  // not decodable audio
        }
        var track = ScannedTrack(path: url.path)
        track.duration = duration.seconds

        // Plain file system calls, which can hang on a stalled network share.
        let file = await BlockingIO.library.run { () -> (size: Int, created: Date?, modified: Date?, bookmark: Data?) in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            return (values?.fileSize ?? 0, values?.creationDate, values?.contentModificationDate, try? url.bookmarkData())
        }
        track.fileSize = Int64(file.size)
        track.dateCreated = file.created
        track.dateModified = file.modified
        track.bitRate = track.duration > 0 ? Int(Double(track.fileSize) * 8 / track.duration / 1000) : 0
        track.bookmark = file.bookmark

        if let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let description = try? await audio.load(.formatDescriptions).first,
           let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            track.sampleRate = Int(stream.mSampleRate)
            track.channels = Int(stream.mChannelsPerFrame)
        }

        let metadata = (try? await asset.load(.metadata)) ?? []
        func string(_ identifiers: [AVMetadataIdentifier]) async -> String? {
            for identifier in identifiers {
                for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier) {
                    if let value = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                        return value
                    }
                }
            }
            return nil
        }
        func data(_ identifier: AVMetadataIdentifier) async -> Data? {
            guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier).first else { return nil }
            return try? await item.load(.dataValue)
        }

        track.title = await string([.commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName]) ?? ""
        track.artist = await string([.commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist]) ?? ""
        track.album = await string([.commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum]) ?? ""
        track.albumArtist = await string([.id3MetadataBand, .iTunesMetadataAlbumArtist]) ?? ""
        track.composer = await string([.id3MetadataComposer, .iTunesMetadataComposer]) ?? ""
        track.comment = await string([.id3MetadataComments, .iTunesMetadataUserComment]) ?? ""
        track.genre = Self.cleanGenre(await string([.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre]) ?? "")
        track.bpm = Int(await string([.id3MetadataBeatsPerMinute, .iTunesMetadataBeatsPerMin]) ?? "") ?? 0
        // ID3's TKEY, or the free-form "initialkey" item that MP4 and Vorbis taggers write.
        let keyIdentifiers = metadata.compactMap(\.identifier).filter {
            $0 == .id3MetadataInitialKey || $0.rawValue.lowercased().hasSuffix("initialkey")
        }
        if let key = await string(keyIdentifiers) {
            track.musicalKey = MusicalKey(parsing: key)?.name ?? key
        }
        if let year = await string([.id3MetadataYear, .id3MetadataRecordingTime, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate]) {
            track.year = Int(year.prefix(4)) ?? 0
        }

        // ID3 stores "3/12"; MP4 stores binary (pad, pad, number, number, total, total, …).
        if let text = await string([.id3MetadataTrackNumber]) {
            (track.trackNumber, track.trackCount) = Self.numberPair(text)
        } else if let bytes = await data(.iTunesMetadataTrackNumber) {
            (track.trackNumber, track.trackCount) = Self.mp4Pair(bytes)
        }
        if let text = await string([.id3MetadataPartOfASet]) {
            (track.discNumber, track.discCount) = Self.numberPair(text)
        } else if let bytes = await data(.iTunesMetadataDiscNumber) {
            (track.discNumber, track.discCount) = Self.mp4Pair(bytes)
        }
        if let flag = await string([AVMetadataIdentifier("id3/TCMP"), .iTunesMetadataDiscCompilation]) {
            track.compilation = flag == "1" || flag.lowercased() == "true"
        }

        // Untagged files: infer from …/Artist/Album/NN Title.ext
        let components = url.deletingPathExtension().pathComponents
        if track.title.isEmpty {
            track.title = Self.titleFromFileName(url.deletingPathExtension().lastPathComponent)
            track.inferred.insert(.title)
        }
        if track.album.isEmpty, components.count >= 2 {
            track.album = components[components.count - 2]
            track.inferred.insert(.album)
        }
        if track.artist.isEmpty, components.count >= 3 {
            track.artist = components[components.count - 3]
            track.inferred.insert(.artist)
        }
        return track
    }

    /// "3/12" → (3, 12); "3" → (3, 0)
    static func numberPair(_ text: String) -> (Int, Int) {
        let parts = text.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        return (parts.first ?? 0, parts.count > 1 ? parts[1] : 0)
    }

    static func mp4Pair(_ data: Data) -> (Int, Int) {
        let bytes = [UInt8](data)
        guard bytes.count >= 6 else { return (0, 0) }
        return (Int(bytes[2]) << 8 | Int(bytes[3]), Int(bytes[4]) << 8 | Int(bytes[5]))
    }

    /// ID3v1-style numeric genres like "(17)" or "17" → name; otherwise unchanged.
    static func cleanGenre(_ genre: String) -> String {
        let digits = genre.trimmingCharacters(in: CharacterSet(charactersIn: "() "))
        if let number = Int(digits), id3Genres.indices.contains(number) { return id3Genres[number] }
        return genre
    }

    /// "01 Title" / "01 - Title" / "A1 Title" → "Title"
    static func titleFromFileName(_ name: String) -> String {
        let pattern = #"^\s*([A-Da-d]?\d{1,3})\s*[-._ ]\s*"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return name }
        let rest = name[range.upperBound...]
        return rest.isEmpty ? name : String(rest)
    }

    private static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk",
        "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise",
        "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave", "Psychadelic", "Rave", "Showtunes",
        "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]
}
