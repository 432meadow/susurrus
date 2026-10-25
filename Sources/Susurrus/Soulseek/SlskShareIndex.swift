import Foundation

/// One shared file: where it really lives, and what we advertise about it.
struct SlskSharedFile: Sendable {
    /// Path other users see, backslash-separated: `Music\Artist\Album\01 Song.flac`.
    let virtualPath: String
    let url: URL
    let size: UInt64
    var bitrate: Int?
    var durationSeconds: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var isVBR: Bool

    /// Lowercased virtual path, what the search index is built from.
    let searchText: String

    /// The last path component: `01 Song.flac`.
    var fileName: String {
        virtualPath.split(separator: "\\").last.map(String.init) ?? virtualPath
    }

    var isLossless: Bool {
        ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"].contains((virtualPath as NSString).pathExtension.lowercased())
    }
}

/// Everything known about a shared file before looking at the file's audio itself.
struct SlskFileAttributes: Sendable {
    var bitrate: Int?
    var durationSeconds: Int?
    var sampleRate: Int?
    var bitDepth: Int?
}

/// A library track the share can offer as it is: path, size and audio details are already
/// known, so sharing it costs no disk access.
struct SlskLibraryFile: Sendable {
    let path: String
    let size: UInt64
    let attributes: SlskFileAttributes
}

/// An audio file a walk of the shared folder found outside the library.
struct SlskFoundFile: Codable, Sendable {
    var path: String
    var size: UInt64
}

/// An immutable scan of the shared folder: what searches match against, what browsing
/// returns, and how queued upload paths map back to real files.
struct SlskShareSnapshot: Sendable {
    let files: [SlskSharedFile]
    let filesByVirtualPath: [String: SlskSharedFile]
    let folderCount: Int
    /// Prebuilt zlib payload of the `SharedFileListResponse` (peer code 5).
    let browsePayload: Data
    /// Lowercased word → indexes into `files` (ascending) of the files whose path has that word.
    private let wordIndex: [String: [Int32]]

    /// Searches longer than this, or with more words, aren't answered: no real search needs them,
    /// and they'd only keep the client busy.
    static let maxQueryLength = 256
    static let maxQueryTerms = 12

    init(files: [SlskSharedFile], folderCount: Int, browsePayload: Data) {
        self.files = files
        filesByVirtualPath = Dictionary(files.map { ($0.virtualPath, $0) }) { first, _ in first }
        self.folderCount = folderCount
        self.browsePayload = browsePayload
        var index: [String: [Int32]] = [:]
        for (position, file) in files.enumerated() {
            for word in Set(Self.words(in: file.searchText)) {
                index[word, default: []].append(Int32(position))
            }
        }
        wordIndex = index
    }

    static let empty = SlskShareSnapshot(files: [], folderCount: 0, browsePayload: (try? SlskZlib.deflate({
        var writer = SlskWriter()
        writer.u32(0)  // no folders
        writer.u32(0)  // unknown, always 0
        return writer.data
    }())) ?? Data())

    var isEmpty: Bool { files.isEmpty }

    /// All-words-match search, Soulseek style: every word of the query must be a word of the
    /// file's virtual path; terms starting with "-" must not be. Case-insensitive; words are runs
    /// of letters and digits, so "Neu!" matches "neu".
    func matches(query: String, limit: Int) -> [SlskSharedFile] {
        guard query.utf8.count <= Self.maxQueryLength else { return [] }
        var include: [String] = []
        var exclusions: [[String]] = []
        let terms = query.lowercased().split(separator: " ")
        guard terms.count <= Self.maxQueryTerms else { return [] }
        for term in terms {
            if term.hasPrefix("-"), term.count > 1 {
                let words = Self.words(in: term.dropFirst())
                if !words.isEmpty { exclusions.append(words) }
            } else {
                include += Self.words(in: term)
            }
        }
        // A bare or too-vague query would match the whole share; don't answer those.
        guard !include.isEmpty, include.joined().count >= 3 else { return [] }

        var lists: [[Int32]] = []
        for word in Set(include) {
            guard let list = wordIndex[word] else { return [] }
            lists.append(list)
        }
        lists.sort { $0.count < $1.count }
        var candidates = lists[0]
        for list in lists.dropFirst() {
            candidates = Self.intersection(candidates, list)
            if candidates.isEmpty { return [] }
        }

        // An excluded term with several words ("-a-ha") excludes paths having all of them.
        var excluded = Set<Int32>()
        for words in exclusions {
            var matching: [Int32]?
            for word in Set(words) {
                let list = wordIndex[word] ?? []
                matching = matching.map { Self.intersection($0, list) } ?? list
            }
            excluded.formUnion(matching ?? [])
        }

        var found: [SlskSharedFile] = []
        for position in candidates where !excluded.contains(position) {
            found.append(files[Int(position)])
            if found.count >= limit { break }
        }
        return found
    }

    /// Lowercased runs of letters and digits.
    static func words<S: StringProtocol>(in text: S) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Two ascending lists' common elements.
    private static func intersection(_ a: [Int32], _ b: [Int32]) -> [Int32] {
        var result: [Int32] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                result.append(a[i])
                i += 1
                j += 1
            } else if a[i] < b[j] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}

/// Builds `SlskShareSnapshot`s: from what the library already knows, and from walking a folder.
enum SlskShareScanner {
    static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "mp4", "aac", "ogg", "opus", "wav", "aiff", "aif",
        "alac", "ape", "wv", "mpc", "wma",
    ]
    private static let maxFiles = 200_000

    /// Walks `folder` and returns the snapshot. Slow on big or networked folders — call it
    /// off the main thread. `attributes` supplies audio details for files it knows (susurrus's
    /// own library); unknown files are shared with size only.
    static func scan(folder: URL, attributes: (String) -> SlskFileAttributes?) -> SlskShareSnapshot {
        let found = walk(folder, skipping: [])
        let files = found.map { SlskLibraryFile(path: $0.path, size: $0.size, attributes: attributes($0.path) ?? SlskFileAttributes()) }
        return snapshot(folder: folder, library: files, extra: [])
    }

    /// The share as far as it's already known — library tracks inside `folder`, plus `extra`
    /// files an earlier walk found outside the library — without touching the disk.
    static func snapshot(folder: URL, library: [SlskLibraryFile], extra: [SlskFoundFile]) -> SlskShareSnapshot {
        let root = folder.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let rootName = sanitizeComponent(folder.lastPathComponent)
        var filesByFolder: [String: [SlskSharedFile]] = [:]
        var seen = Set<String>()

        func add(_ path: String, size: UInt64, attributes: SlskFileAttributes) {
            let path = standardized(path)
            guard seen.count < maxFiles, path.hasPrefix(prefix) else { return }
            let pieces = path.dropFirst(prefix.count).split(separator: "/")
            // Hidden files and folders aren't shared, as in a walk.
            guard !pieces.isEmpty, !pieces.contains(where: { $0.hasPrefix(".") }),
                  seen.insert(path).inserted else { return }
            let components = pieces.map { sanitizeComponent(String($0)) }
            let virtualPath = ([rootName] + components).joined(separator: "\\")
            let virtualFolder = ([rootName] + components.dropLast()).joined(separator: "\\")
            filesByFolder[virtualFolder, default: []].append(SlskSharedFile(
                virtualPath: virtualPath,
                url: URL(fileURLWithPath: path, isDirectory: false),
                size: size,
                bitrate: attributes.bitrate,
                durationSeconds: attributes.durationSeconds,
                sampleRate: attributes.sampleRate,
                bitDepth: attributes.bitDepth,
                isVBR: false,
                searchText: virtualPath.lowercased()
            ))
        }

        // A size of 0 means the library doesn't know it; the walk measures those files.
        for file in library where file.size > 0 { add(file.path, size: file.size, attributes: file.attributes) }
        for file in extra { add(file.path, size: file.size, attributes: SlskFileAttributes()) }

        let folderOrder = filesByFolder.keys.sorted()
        for folder in folderOrder {
            filesByFolder[folder]?.sort { $0.virtualPath < $1.virtualPath }
        }
        return SlskShareSnapshot(
            files: folderOrder.flatMap { filesByFolder[$0] ?? [] },
            folderCount: folderOrder.count,
            browsePayload: browsePayload(folderOrder: folderOrder, filesByFolder: filesByFolder)
        )
    }

    /// The standardized paths of library files a walk can skip (their sizes are known).
    static func knownPaths(_ library: [SlskLibraryFile]) -> Set<String> {
        Set(library.lazy.filter { $0.size > 0 }.map { standardized($0.path) })
    }

    /// `path` without "." and ".." parts. Says it's a file, so nothing is looked up on disk (a
    /// round trip per file on a network share).
    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }

    /// Audio files under `folder` whose paths aren't in `known`. Slow on big or networked
    /// folders — call it off the main thread; it stops early once `isCancelled` says so.
    static func walk(_ folder: URL, skipping known: Set<String>, isCancelled: () -> Bool = { false }) -> [SlskFoundFile] {
        let enumerator = FileManager.default.enumerator(
            at: folder.standardizedFileURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var found: [SlskFoundFile] = []
        while let url = enumerator?.nextObject() as? URL {
            guard found.count < maxFiles, !isCancelled() else { break }
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let path = url.standardizedFileURL.path
            guard !known.contains(path),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            found.append(SlskFoundFile(path: path, size: UInt64(max(0, size))))
        }
        return found
    }

    /// Remote-facing path pieces can't contain the separator; also keep them non-empty.
    private static func sanitizeComponent(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "-")
        return cleaned.isEmpty ? "folder" : cleaned
    }

    /// `SharedFileListResponse` payload: zlib(u32 nfolders, per folder: string path +
    /// u32 nfiles + file infos, then u32 unknown = 0). Built once per scan. File infos here carry
    /// the bare file name (the folder path is sent once above them), as other clients send and
    /// expect; search responses carry the full path.
    private static func browsePayload(folderOrder: [String], filesByFolder: [String: [SlskSharedFile]]) -> Data {
        var writer = SlskWriter()
        writer.u32(UInt32(folderOrder.count))
        for folder in folderOrder {
            writer.string(folder)
            let files = filesByFolder[folder] ?? []
            writer.u32(UInt32(files.count))
            for file in files {
                writer.fileInfo(file, name: file.fileName)
            }
        }
        writer.u32(0)  // unknown, official clients send 0
        return (try? SlskZlib.deflate(writer.data)) ?? SlskShareSnapshot.empty.browsePayload
    }
}

/// What the last walk of the shared folder found outside the library, kept on disk so later
/// launches can share it straight away instead of walking the folder again.
struct SlskShareWalk: Codable, Sendable {
    var folder: String
    var date: Date
    var files: [SlskFoundFile]

    /// Walks older than this are done again (in the background) when the share is rebuilt.
    static let maxAge: TimeInterval = 24 * 60 * 60

    static var defaultURL: URL {
        LibraryStore.supportDirectory.appendingPathComponent("susurrus/Soulseek/Share.json")
    }

    static func load(from url: URL) -> SlskShareWalk? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SlskShareWalk.self, from: data)
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

extension SlskWriter {
    /// The file-info record used by search responses and share lists: code byte, name (the full
    /// virtual path unless `name` is given), size, empty extension (as modern clients send), and
    /// the quality attributes we know.
    /// Attribute codes: 0 bitrate, 1 duration, 2 VBR, 4 sample rate, 5 bit depth.
    mutating func fileInfo(_ file: SlskSharedFile, name: String? = nil) {
        u8(1)
        string(name ?? file.virtualPath)
        u64(file.size)
        u32(0)  // empty extension string

        var attributes: [(UInt32, UInt32)] = []
        if file.isLossless {
            if let duration = file.durationSeconds { attributes.append((1, UInt32(clamping: max(0, duration)))) }
            if let rate = file.sampleRate { attributes.append((4, UInt32(clamping: max(0, rate)))) }
            if let depth = file.bitDepth { attributes.append((5, UInt32(clamping: max(0, depth)))) }
        } else {
            if let bitrate = file.bitrate {
                attributes.append((0, UInt32(clamping: max(0, bitrate))))
                attributes.append((2, file.isVBR ? 1 : 0))
            }
            if let duration = file.durationSeconds { attributes.append((1, UInt32(clamping: max(0, duration)))) }
        }
        u32(UInt32(attributes.count))
        for (code, value) in attributes {
            u32(code)
            u32(value)
        }
    }
}
