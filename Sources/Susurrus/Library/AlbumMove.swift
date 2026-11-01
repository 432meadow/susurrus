import Foundation

/// A matched Soulseek download on its way to the library folder, saved until it's there so it can
/// wait out a library folder that isn't mounted, across launches (see `AppModel.moveDownloadedAlbums`).
struct AlbumMove: Codable, Equatable, Sendable {
    /// The downloaded album's folder.
    var folder: String
    /// "Artist/Album", inside the library folder.
    var target: String
    /// "Artist – Album (Year)", for messages.
    var title: String
    /// New file names ("03 Title.flac") by track ID; a track without one keeps its name.
    var names: [Int64: String]
    /// Saved once the album is copied and checked, before anything else changes, so a move cut
    /// short from there on (a crash, the power, a share dropping) is finished instead of lost.
    var commit: Commit?

    struct Commit: Codable, Equatable, Sendable {
        /// The finished copy, in its hidden folder.
        var staging: String
        /// The folder it becomes.
        var destination: String
        /// Where the tracks were, by track ID.
        var oldPaths: [Int64: String]
        /// Each track's file name in the new folder, by track ID.
        var files: [Int64: String]

        /// Where the tracks go.
        var newPaths: [Int64: String] {
            let folder = URL(fileURLWithPath: destination, isDirectory: true)
            return files.mapValues { folder.appendingPathComponent($0).path }
        }
    }
}

/// Where a download goes in the library folder going by its own tags, for Move to Library when
/// MusicBrainz has no sure match (one track of a single, say). It follows how the library is laid
/// out: "Artist/Album/03 Title.flac", and "Compilations/Album" for various artists.
enum TagFiling {
    struct Plan: Equatable {
        /// Inside the library folder.
        var target: String
        var title: String
        /// New file names by track ID; a track without a title keeps its name.
        var names: [Int64: String]
    }

    enum Outcome: Equatable {
        case plan(Plan)
        /// Neither the tags nor the folder name say whose it is.
        case noArtist
        /// The tags name these different albums, so it isn't one album's folder.
        case severalAlbums([String])
    }

    private static let variousArtists: Set<String> = ["various artists", "various artist", "various", "va", "v/a", "v_a"]

    /// "Artist/Album", or "Compilations/Album", each part made safe for a folder name.
    static func libraryPath(artist: String, album: String, isCompilation: Bool) -> String {
        let folder = isCompilation ? "Compilations" : ReleaseMatcher.safeName(artist)
        return folder + "/" + ReleaseMatcher.safeName(album.isEmpty ? "Unknown Album" : album)
    }

    static func plan(for inputs: [ReleaseMatcher.Input], isCompilation: Bool, folderName: String) -> Outcome {
        func commonest(_ values: [String]) -> String {
            let counts = Dictionary(values.filter { !$0.isEmpty }.map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? ""
        }
        var byAlbum: [String: String] = [:]
        for album in inputs.map(\.album) where !album.isEmpty {
            byAlbum[DiscographyMatch.normalizedTitle(album)] = album
        }
        guard byAlbum.count <= 1 else { return .severalAlbums(byAlbum.values.sorted()) }

        // The folder name only counts as "Artist - Album": a bare name may just be the uploader's.
        let parsed = ReleaseMatcher.parseFolderName(folderName)
        let album = commonest(inputs.map(\.album)).isEmpty ? (parsed.artist.isEmpty ? "" : parsed.album) : commonest(inputs.map(\.album))
        let albumArtist = commonest(inputs.map(\.albumArtist))
        let artists = Set(inputs.map(\.artist).filter { !$0.isEmpty })
        let compilation = isCompilation || variousArtists.contains(albumArtist.lowercased())
            || (albumArtist.isEmpty && artists.count >= 3)
        var artist = albumArtist.isEmpty ? commonest(inputs.map(\.artist)) : albumArtist
        if artist.isEmpty { artist = parsed.artist }
        guard compilation || !artist.isEmpty else { return .noArtist }

        let manyDiscs = Set(inputs.map { max($0.discNumber, 1) }).count > 1
        var names: [Int64: String] = [:]
        for input in inputs where !input.title.isEmpty {
            let ext = (input.path as NSString).pathExtension
            var name = input.title
            if let number = trackNumber(of: input) {
                let padded = String(format: "%02d", number)
                name = (manyDiscs ? "\(max(input.discNumber, 1))-\(padded)" : padded) + " " + name
            }
            let safe = ReleaseMatcher.safeName(name)
            names[input.id] = ext.isEmpty ? safe : "\(safe).\(ext)"
        }
        return .plan(Plan(target: libraryPath(artist: artist, album: album, isCompilation: compilation),
                          title: "\(compilation ? "Various Artists" : artist) – \(album.isEmpty ? "Unknown Album" : album)",
                          names: names))
    }

    /// From the tag, else the file name ("03 Title", "Album - 03 - Title").
    private static func trackNumber(of input: ReleaseMatcher.Input) -> Int? {
        let number = ReleaseMatcher.numbers(of: input).track
        if number > 0 { return number }
        return input.fileName.firstMatch(of: #/\s-\s(\d{1,3})\s-\s/#).flatMap { Int($0.1) }
    }
}

/// The file work of moving an album to the library folder. Blocking, for `BlockingIO`: the
/// library folder is usually on a slow network share.
enum AlbumMoveFiles {
    /// An album copied into a hidden folder in the library folder, not yet in place.
    struct Copy: Sendable {
        var staging: URL
        /// Its "Artist/Album" folder, numbered if that's taken.
        var destination: URL
        /// Each track's copy: its file name in the album folder, with its date and size.
        var files: [(id: Int64, name: String, stamp: FileStamp)]
    }

    struct SizeMismatch: LocalizedError {
        let name: String
        var errorDescription: String? { "The copy of “\(name)” isn't the same size as the original." }
    }

    /// Hidden, so library scans and the share's walk pass over a copy that isn't finished.
    static let stagingPrefix = ".susurrus-moving-"

    /// Whether `url` is a folder that's there right now (one on a share that isn't mounted isn't).
    static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Copies the tracks (as `name`) and the rest of the album folder (covers, cue sheets, logs,
    /// scans; disc folders flattened) into a hidden folder in `root`, checking each copy's size,
    /// after clearing copies a move left there when it was cut short. Throws `CancellationError`
    /// once `isCancelled`; on any failure, what it copied is removed.
    static func copy(_ files: [(id: Int64, path: String, name: String)], from folder: URL, to root: URL, target: String,
                     isCancelled: () -> Bool, copied: (Int) -> Void) throws -> Copy {
        let fileManager = FileManager.default
        removeUnfinishedCopies(in: root)
        let staging = root.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var copies: [(id: Int64, name: String, stamp: FileStamp)] = []
            for (index, file) in files.enumerated() {
                if isCancelled() { throw CancellationError() }
                let copy = AppModel.unusedURL(staging.appendingPathComponent(file.name))
                try copyChecked(URL(fileURLWithPath: file.path), to: copy)
                copies.append((file.id, copy.lastPathComponent, try stamp(of: copy)))
                copied(index + 1)
            }
            for other in otherFiles(in: folder) {
                if isCancelled() { throw CancellationError() }
                let copy = staging.appendingPathComponent(other.path)
                guard !fileManager.fileExists(atPath: copy.path) else { continue }  // CD2's cover.jpg after CD1's
                try fileManager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyChecked(other.url, to: copy)
            }
            let destination = AppModel.unusedURL(root.appendingPathComponent(matchingExistingFolders(target, in: root), isDirectory: true))
            return Copy(staging: staging, destination: destination, files: copies)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// `target` with its folders spelled as the ones already in `root` where only the case differs,
    /// so an album joins "mike mind" instead of starting "Mike Mind" next to it.
    static func matchingExistingFolders(_ target: String, in root: URL) -> String {
        var current = root
        var parts: [String] = []
        for part in target.split(separator: "/").map(String.init) {
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: current.path))?
                .first { $0.caseInsensitiveCompare(part) == .orderedSame }
            parts.append(existing ?? part)
            current = current.appendingPathComponent(parts.last!, isDirectory: true)
        }
        return parts.joined(separator: "/")
    }

    /// Copies `source` to `destination` and checks the copy is the same size.
    static func copyChecked(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: source, to: destination)
        func size(_ url: URL) throws -> Int64? {
            (try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        }
        guard try size(source) == size(destination) else { throw SizeMismatch(name: source.lastPathComponent) }
    }

    static func stamp(of url: URL) throws -> FileStamp {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileStamp(modified: values.contentModificationDate, size: Int64(values.fileSize ?? 0))
    }

    /// The album folder's other files (not audio, not hidden), each with where it goes in the
    /// album's new folder: the same place, minus disc folders ("CD1/cover.jpg" → "cover.jpg").
    /// The album folder's own files come before a disc folder's of the same name.
    static func otherFiles(in folder: URL) -> [(url: URL, path: String)] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found: [(url: URL, path: String, depth: Int)] = []
        while let url = enumerator.nextObject() as? URL {
            guard !TagReader.isAudioFile(url), (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let parts = url.pathComponents.suffix(enumerator.level)
            let folders = parts.dropLast().filter { !SoulseekModel.isDiscFolder($0) }
            found.append((url, (folders + parts.suffix(1)).joined(separator: "/"), parts.count))
        }
        return found.sorted { ($0.path, $0.depth) < ($1.path, $1.depth) }.map { ($0.url, $0.path) }
    }

    /// Puts the copied album in its folder, making the artist folder if it's new.
    static func putInPlace(_ copy: Copy) throws {
        try putInPlace(staging: copy.staging, destination: copy.destination)
    }

    static func putInPlace(staging: URL, destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: staging, to: destination)
    }

    static func discard(_ copy: Copy) {
        try? FileManager.default.removeItem(at: copy.staging)
    }

    /// How far a committed move got, by what's in the library folder.
    enum Progress {
        /// The finished copy is still in its hidden folder.
        case staged([(id: Int64, stamp: FileStamp)])
        /// It's in its folder.
        case inPlace([(id: Int64, stamp: FileStamp)])
        /// The copy isn't there any more, or not all of it.
        case lost
    }

    /// Looks at what a move that was cut short left, with each file's date and size.
    static func progress(of commit: AlbumMove.Commit) -> Progress {
        func stamps(in folder: URL) -> [(id: Int64, stamp: FileStamp)]? {
            var found: [(id: Int64, stamp: FileStamp)] = []
            for (id, name) in commit.files {
                guard let stamp = try? stamp(of: folder.appendingPathComponent(name)) else { return nil }
                found.append((id, stamp))
            }
            return found
        }
        let staging = URL(fileURLWithPath: commit.staging, isDirectory: true)
        if isFolder(staging) { return stamps(in: staging).map(Progress.staged) ?? .lost }
        return stamps(in: URL(fileURLWithPath: commit.destination, isDirectory: true)).map(Progress.inPlace) ?? .lost
    }

    /// Copies left in `root` by a move that was cut short (susurrus quit, the share dropped).
    static func removeUnfinishedCopies(in root: URL) {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(stagingPrefix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// Deletes the downloaded files that were copied, then the album's folder if no audio is left
    /// in it (its covers, logs and the like went along), and the folders that empties, up to
    /// `downloads`. Nothing outside the download folder is touched.
    static func removeOriginals(_ paths: [String], folder: URL, downloads: URL) {
        let fileManager = FileManager.default
        let folder = folder.standardizedFileURL, downloads = downloads.standardizedFileURL
        let inside = downloads.path + "/"
        for path in paths where URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(inside) {
            try? fileManager.removeItem(atPath: path)
        }
        guard folder.path.hasPrefix(inside) else { return }
        let rest = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = rest?.nextObject() as? URL {
            if TagReader.isAudioFile(url) { return }  // files that didn't match stay, with the rest of the folder
        }
        try? fileManager.removeItem(at: folder)
        AppModel.removeEmptyFolders(from: folder.deletingLastPathComponent(), upTo: downloads)
    }

    // MARK: The queue on disk

    static func load(from url: URL) -> [AlbumMove] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AlbumMove].self, from: data)) ?? []
    }

    static func save(_ moves: [AlbumMove], to url: URL) throws {
        if moves.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            try JSONEncoder().encode(moves).write(to: url, options: .atomic)
        }
    }
}
