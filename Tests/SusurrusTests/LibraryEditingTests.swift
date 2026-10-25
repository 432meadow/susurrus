import AVFoundation
import Foundation
import Testing
@testable import Susurrus

@Suite struct LibraryEditingTests {
    let store: LibraryStore
    let ids: [Int64]

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Library.sqlite")
        store = try LibraryStore(url: url)
        let scanned = (1...5).map { ScannedTrack(path: "/music/\($0).mp3", title: "Track \($0)") }
        try store.insert(scanned)
        ids = try store.loadTracks().sorted { $0.title < $1.title }.map(\.id)
    }

    @Test func insertSkipsKnownPaths() throws {
        let added = try store.insert([ScannedTrack(path: "/music/1.mp3"), ScannedTrack(path: "/music/new.mp3")])
        #expect(added.count == 1)
        #expect(try store.allPaths().count == 6)
    }

    @Test func keysAreStoredAndEdited() throws {
        try store.insert([ScannedTrack(path: "/music/keyed.mp3", title: "Keyed", musicalKey: "Am")])
        var keyed = try #require(try store.loadTracks().first { $0.title == "Keyed" })
        #expect(keyed.musicalKey == "Am" && keyed.key == MusicalKey(tonic: 9, isMinor: true))
        try store.update(TrackEdit(musicalKey: "F#"), forTracks: [keyed.id])
        keyed = try #require(try store.loadTracks().first { $0.id == keyed.id })
        #expect(keyed.key?.camelot == "2B")
    }

    @Test func playlistEntriesAddRemoveMove() throws {
        let playlist = try store.createPlaylist(named: "Mix", trackIDs: [ids[0], ids[1]])
        try store.appendTracks([ids[2], ids[0]], toPlaylist: playlist)
        #expect(try store.trackIDs(inPlaylist: playlist) == [ids[0], ids[1], ids[2], ids[0]])

        try store.removeEntries(at: [1], fromPlaylist: playlist)
        #expect(try store.trackIDs(inPlaylist: playlist) == [ids[0], ids[2], ids[0]])

        try store.moveEntries(at: [2], to: 0, inPlaylist: playlist)
        #expect(try store.trackIDs(inPlaylist: playlist) == [ids[0], ids[0], ids[2]])
    }

    @Test func foldersNestAndDeleteCascades() throws {
        let folder = try store.createPlaylist(named: "Folder", kind: .folder)
        let a = try store.createPlaylist(named: "A")
        let b = try store.createPlaylist(named: "B", parentID: folder)
        try store.movePlaylist(a, toParent: folder, position: 0)

        let top = try store.loadPlaylists()
        #expect(top.map(\.name) == ["Folder"])
        #expect(top[0].children?.map(\.name) == ["A", "B"])

        try store.renamePlaylist(b, to: "Bee")
        #expect(try store.loadPlaylists()[0].children?.map(\.name) == ["A", "Bee"])

        try store.deletePlaylist(folder)
        #expect(try store.loadPlaylists().isEmpty)
    }

    @Test func tagEditsAndPlaysPersist() throws {
        try store.update(TrackEdit(artist: "New Artist", year: 1999, rating: 4.5), forTracks: [ids[0], ids[1]])
        try store.recordPlay(trackID: ids[0], at: Date(timeIntervalSince1970: 1_000_000))
        let tracks = Dictionary(uniqueKeysWithValues: try store.loadTracks().map { ($0.id, $0) })
        #expect(tracks[ids[0]]?.artist == "New Artist")
        #expect(tracks[ids[1]]?.year == 1999)
        #expect(tracks[ids[1]]?.rating == 4.5)
        #expect(tracks[ids[2]]?.artist == "", "untouched tracks keep their values")
        #expect(tracks[ids[0]]?.playCount == 1)
        #expect(tracks[ids[0]]?.lastPlayed == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func smartPlaylistRoundTrip() throws {
        let predicate = NSPredicate(format: "rating >= 4")
        let id = try store.createPlaylist(named: "Good", kind: .smart,
                                          smartPredicate: try SmartPredicate.archive(predicate),
                                          predicateFormat: predicate.predicateFormat)
        let restored = try SmartPredicate.unarchive(try #require(try store.smartPredicateArchive(forPlaylist: id)))
        #expect(restored.predicateFormat == predicate.predicateFormat)
    }

    @Test func editApplyResetsSearch() {
        let track = Track(id: 1)
        track.title = "Old"
        #expect(track.searchText.contains("old"))
        TrackEdit(title: "Fresh").apply(to: track)
        #expect(track.searchText.contains("fresh"))
    }
}

@Suite struct TagReaderTests {
    @Test func parsesNumberPairsAndGenres() {
        #expect(TagReader.numberPair("3/12") == (3, 12))
        #expect(TagReader.numberPair("7") == (7, 0))
        #expect(TagReader.mp4Pair(Data([0, 0, 0, 4, 0, 9, 0, 0])) == (4, 9))
        #expect(TagReader.cleanGenre("(18)") == "Techno")
        #expect(TagReader.cleanGenre("Dub Techno") == "Dub Techno")
    }

    @Test func titlesFromFileNames() {
        #expect(TagReader.titleFromFileName("01 Wave Emoji") == "Wave Emoji")
        #expect(TagReader.titleFromFileName("02 - Henry Hill") == "Henry Hill")
        #expect(TagReader.titleFromFileName("A1 FUORIORARIO") == "FUORIORARIO")
        #expect(TagReader.titleFromFileName("Untitled") == "Untitled")
    }

    @Test func readsUntaggedFileUsingFolderLayout() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Some Artist/Some Album")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("03 Song Name.wav")
        try ToneFile.write(to: url, seconds: 0.5)

        let track = try #require(await TagReader.read(url))
        #expect(track.title == "Song Name")
        #expect(track.album == "Some Album")
        #expect(track.artist == "Some Artist")
        #expect(abs(track.duration - 0.5) < 0.01)
        #expect(track.sampleRate == 44_100)
        #expect(track.channels == 2)
        // The temp dir is reached through the /var → /private/var symlink, so compare resolved paths.
        #expect(AppModel.audioFiles(in: [folder.deletingLastPathComponent()]).map { $0.url.resolvingSymlinksInPath().path }
                == [url.resolvingSymlinksInPath().path])
    }

}

/// Writes short stereo sine-wave WAV files for tests.
enum ToneFile {
    /// `format`: linear PCM (WAV/AIFF by extension), or an encoded format such as AAC or FLAC.
    static func write(to url: URL, seconds: Double, frequency: Double = 440, sampleRate: Double = 44_100,
                      format formatID: AudioFormatID = kAudioFormatLinearPCM) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        var settings: [String: Any] = [AVFormatIDKey: formatID, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2]
        switch formatID {
        case kAudioFormatLinearPCM:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            settings[AVEncoderBitDepthHintKey] = 16
        default:
            break
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            let samples = buffer.floatChannelData![channel]
            for frame in 0..<Int(frames) {
                samples[frame] = Float(sin(2 * .pi * frequency * Double(frame) / sampleRate) * 0.2)
            }
        }
        try file.write(from: buffer)
    }
}
