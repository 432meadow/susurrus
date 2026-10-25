import Foundation

/// Finding duplicate tracks: same artist and title (ignoring case, accents and punctuation) and
/// lengths within two seconds of each other.
enum Duplicates {
    static let lengthTolerance = 2.0

    /// The duplicated tracks, each group's members next to each other, groups ordered by artist
    /// and title and members by length.
    static func find(in tracks: [Track]) -> [Track] {
        var groups: [String: [Track]] = [:]
        for track in tracks {
            guard let key = key(for: track) else { continue }
            groups[key, default: []].append(track)
        }
        var result: [(key: String, tracks: [Track])] = []
        for (key, members) in groups where members.count > 1 {
            // Split by length: a radio edit and an extended mix of one title aren't duplicates.
            let sorted = members.sorted { $0.length < $1.length }
            var cluster = [sorted[0]]
            func flush() {
                if cluster.count > 1 { result.append((key, cluster)) }
            }
            for track in sorted.dropFirst() {
                if track.length - cluster[cluster.count - 1].length <= lengthTolerance {
                    cluster.append(track)
                } else {
                    flush()
                    cluster = [track]
                }
            }
            flush()
        }
        return result
            .sorted { $0.key == $1.key ? $0.tracks[0].length < $1.tracks[0].length : $0.key < $1.key }
            .flatMap(\.tracks)
    }

    static func key(for track: Track) -> String? {
        let title = TextKey.alphanumerics(track.title)
        guard !title.isEmpty else { return nil }
        return TextKey.alphanumerics(track.displayArtist) + "\u{1}" + title
    }
}

/// Which library files can't be found right now.
enum MissingFiles {
    enum Status: Equatable, Sendable {
        /// The file's volume is there but the file isn't.
        case missing
        /// The volume the file lives on (e.g. the music share) isn't mounted.
        case offline
    }

    /// Checks each path. Over a network share every file system call is a round trip, so each
    /// folder is listed once instead of asking for every file; an unmounted volume under /Volumes
    /// marks all of its files offline with a single check.
    static func check(_ paths: [(id: Int64, path: String)],
                      listFolder: (String) -> [String]? = { try? FileManager.default.contentsOfDirectory(atPath: $0) },
                      fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Int64: Status] {
        var volumeMounted: [String: Bool] = [:]
        var result: [Int64: Status] = [:]
        var byFolder: [String: [(id: Int64, path: String)]] = [:]
        for (id, path) in paths {
            if let volume = volumeRoot(of: path) {
                let mounted = volumeMounted[volume] ?? {
                    let mounted = fileExists(volume)
                    volumeMounted[volume] = mounted
                    return mounted
                }()
                if !mounted {
                    result[id] = .offline
                    continue
                }
            }
            byFolder[(path as NSString).deletingLastPathComponent, default: []].append((id, path))
        }
        for (folder, files) in byFolder {
            guard let names = listFolder(folder).map({ Set($0.map(\.precomposedStringWithCanonicalMapping)) }) else {
                // A folder that's gone takes its files with it; one that can't be listed is asked file by file.
                let folderExists = fileExists(folder)
                for (id, path) in files where !folderExists || !fileExists(path) { result[id] = .missing }
                continue
            }
            for (id, path) in files where !names.contains((path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping) {
                // Not listed under that name: maybe it's spelled with another case. Ask for the file itself.
                if !fileExists(path) { result[id] = .missing }
            }
        }
        return result
    }

    /// "/Volumes/Music" for "/Volumes/Music/Artist/Song.mp3"; nil outside /Volumes.
    static func volumeRoot(of path: String) -> String? {
        let parts = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/\(parts[1])"
    }
}
