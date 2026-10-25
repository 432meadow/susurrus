import Foundation

/// A matched Soulseek download on its way to the library folder, saved until it's there so it can
/// wait out a library folder that isn't mounted, across launches (see `AppModel.moveDownloadedAlbums`).
struct AlbumMove: Codable, Equatable, Sendable {
    /// The downloaded album's folder.
    var folder: String
    /// "Artist/Album (Year)", inside the library folder.
    var target: String
    /// "Artist – Album (Year)", for messages.
    var title: String
    /// New file names ("03 Title.flac") by track ID; a track without one keeps its name.
    var names: [Int64: String]
}

/// The file work of moving an album to the library folder. Blocking, for `BlockingIO`: the
/// library folder is usually on a slow network share.
enum AlbumMoveFiles {
    /// An album copied into a hidden folder in the library folder, not yet in place.
    struct Copy: Sendable {
        var staging: URL
        /// Its "Artist/Album (Year)" folder, numbered if that's taken.
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
            let destination = AppModel.unusedURL(root.appendingPathComponent(target, isDirectory: true))
            return Copy(staging: staging, destination: destination, files: copies)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
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
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: copy.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: copy.staging, to: copy.destination)
    }

    static func discard(_ copy: Copy) {
        try? FileManager.default.removeItem(at: copy.staging)
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
