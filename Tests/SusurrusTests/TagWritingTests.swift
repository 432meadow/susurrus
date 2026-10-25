import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// Tag writing against generated files in a temp folder. Never touches the real library.
@Suite struct TagWritingTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TagWritingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    /// No temp copies may be left behind, whatever happened.
    private func expectNoTempFiles() throws {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".susurrus-") }
        #expect(leftovers.isEmpty)
    }

    private let everything = TagValues(
        title: "Ünïcode Title", artist: "Artist", album: "Album", albumArtist: "Album Artist", genre: "Dub Techno",
        composer: "Composer", grouping: "Group", comment: "A comment", year: 1999,
        track: .init(number: 3, total: 12), disc: .init(number: 1, total: 2), bpm: 128, compilation: true, rating: 4.5)

    // MARK: MP3

    @Test func mp3TagRoundTripKeepsOtherFramesAndAudio() async throws {
        let audio = MP3Fixture.audio() + MP3Fixture.id3v1
        let original = MP3Fixture.id3(version: 3, frames: [
            MP3Fixture.text("TIT2", "Old"),
            MP3Fixture.frame("APIC", [0, 0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F, 0x6A, 0x70, 0x65, 0x67, 0, 3, 0] + Array(repeating: 0xAB, count: 300)),
            MP3Fixture.frame("TXXX", [0] + Array("REPLAYGAIN_TRACK_GAIN".utf8) + [0] + Array("-3.2 dB".utf8)),
            MP3Fixture.frame("COMM", [0] + Array("eng".utf8) + Array("iTunSMPB".utf8) + [0] + Array(" 00000000 00000210".utf8)),
            MP3Fixture.frame("COMM", [0] + Array("eng".utf8) + [0] + Array("old comment".utf8)),
            MP3Fixture.frame("POPM", Array("MusicBee".utf8) + [0, 128, 0, 0, 0, 7]),
        ], padding: 64) + audio
        let url = try file("song.mp3", original)

        #expect(try await TagFileWriter.write(everything, to: url) != .unchanged)
        let written = try bytes(url)
        let tag = try ID3Tag.parse(written)
        #expect(tag.version == 3)
        #expect(Array(written[tag.end...]) == audio, "audio and ID3v1 are untouched")
        #expect(everything.isSatisfied(by: try ID3Tag.read(written)))

        // Unedited frames survive byte for byte; the plain comment was replaced, iTunSMPB kept.
        let ids = tag.frames.map(\.id)
        #expect(ids.filter { $0 == "APIC" }.count == 1 && ids.contains("TXXX"))
        let comments = tag.frames.filter { $0.id == "COMM" }
        #expect(comments.count == 2)
        #expect(comments.contains { String(decoding: $0.body, as: UTF8.self).contains("iTunSMPB") })
        // The existing POPM keeps its email and play counter; only the rating byte changes.
        let popm = try #require(tag.frames.first { $0.id == "POPM" })
        #expect(Array(popm.body) == Array("MusicBee".utf8) + [0, 242, 0, 0, 0, 7])

        // AVFoundation (what susurrus imports with) sees the new tags.
        let scanned = try #require(await TagReader.read(url))
        #expect(scanned.title == "Ünïcode Title")
        #expect(scanned.artist == "Artist")
        #expect(scanned.album == "Album")
        #expect(scanned.year == 1999)
        #expect(scanned.trackNumber == 3 && scanned.trackCount == 12)
        #expect(scanned.compilation)
        try expectNoTempFiles()
    }

    @Test func mp3WithoutTagGetsAnID3v23Tag() async throws {
        let audio = MP3Fixture.audio()
        let url = try file("bare.mp3", audio)
        _ = try await TagFileWriter.write(TagValues(title: "Fresh", rating: 3), to: url)
        let written = try bytes(url)
        let tag = try ID3Tag.parse(written)
        #expect(tag.version == 3)
        #expect(Array(written[tag.end...]) == audio)
        let popm = try #require(tag.frames.first { $0.id == "POPM" })
        #expect(Array(popm.body) == Array(ID3Tag.ratingEmail.utf8) + [0, 128])
        #expect(await TagReader.read(url)?.title == "Fresh")
    }

    @Test func id3v24UsesUTF8AndTDRC() async throws {
        let url = try file("v24.mp3", MP3Fixture.id3(version: 4, frames: [MP3Fixture.text("TDRC", "2001-02-03", version: 4)], padding: 10) + MP3Fixture.audio())
        _ = try await TagFileWriter.write(TagValues(title: "日本語", year: 2020), to: url)
        let tag = try ID3Tag.parse(try bytes(url))
        #expect(tag.version == 4)
        let title = try #require(tag.frames.first { $0.id == "TIT2" })
        #expect(Array(title.body) == [3] + Array("日本語".utf8))
        #expect(tag.frames.filter { $0.id == "TDRC" }.count == 1)
        #expect(try ID3Tag.read(try bytes(url)).year == 2020)
    }

    @Test func clearingFieldsRemovesFramesAndKeepsAudioOffsetWhenItFits() async throws {
        let original = MP3Fixture.id3(version: 3, frames: [
            MP3Fixture.text("TIT2", "Title"), MP3Fixture.text("TCMP", "1"), MP3Fixture.text("TBPM", "120"),
            MP3Fixture.frame("COMM", [0] + Array("eng".utf8) + [0] + Array("bye".utf8)),
        ], padding: 200) + MP3Fixture.audio()
        let url = try file("clear.mp3", original)
        _ = try await TagFileWriter.write(TagValues(comment: "", bpm: 0, compilation: false), to: url)
        let written = try bytes(url)
        let tag = try ID3Tag.parse(written)
        #expect(tag.frames.map(\.id) == ["TIT2"])
        #expect(tag.end == (try ID3Tag.parse(original)).end, "the freed space became padding")
        #expect(written.count == original.count)
    }

    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    @Test func tagsThatFitArePatchedInPlace() async throws {
        let audio = MP3Fixture.audio() + MP3Fixture.id3v1
        let original = MP3Fixture.id3(version: 3, frames: [
            MP3Fixture.text("TIT2", "Title"), MP3Fixture.text("TCON", "Other"),
            MP3Fixture.frame("APIC", [0, 0x69, 0x6D, 0x61, 0x67, 0x65, 0x2F, 0x6A, 0x70, 0x65, 0x67, 0, 3, 0] + Array(repeating: 0xAB, count: 300)),
        ], padding: 256) + audio
        let url = try file("patch.mp3", original)
        let node = inode(url)

        #expect(try await TagFileWriter.write(TagValues(artist: "Boards of Canada", genre: "IDM", year: 2002), to: url) != .unchanged)
        let written = try bytes(url)
        #expect(inode(url) == node, "written in place, not replaced by a copy")
        #expect(written.count == original.count)
        let tag = try ID3Tag.parse(written)
        #expect(tag.end == (try ID3Tag.parse(original)).end)
        #expect(Array(written[tag.end...]) == audio)
        #expect(TagValues(title: "Title", artist: "Boards of Canada", genre: "IDM", year: 2002).isSatisfied(by: try ID3Tag.read(written)))
        #expect(tag.frames.contains { $0.id == "APIC" })
        try expectNoTempFiles()
    }

    /// Byte ranges of each frame in an ID3 tag without an extended header.
    private func frameRanges(_ bytes: [UInt8]) throws -> [(id: String, range: Range<Int>)] {
        var start = 10
        return try ID3Tag.parse(bytes).frames.map { frame in
            defer { start += frame.raw.count }
            return (frame.id, start..<start + frame.raw.count)
        }
    }

    @Test func mp3TitleEditsBesideALargeCoverStaySmall() async throws {
        let cover = MP3Fixture.frame("APIC", [0] + Array("image/jpeg".utf8) + [0, 3, 0] + LargeCover.bytes)
        let url = try file("covered.mp3", MP3Fixture.id3(version: 3, frames: [
            MP3Fixture.text("TIT2", "Old title"), MP3Fixture.text("TPE1", "Artist"), cover,
        ], padding: 1024) + MP3Fixture.audio())
        let node = inode(url)

        // The first edit moves the title past the cover: too much to patch, so it's a verified copy.
        _ = try await TagFileWriter.write(TagValues(title: "A longer new title"), to: url)
        #expect(inode(url) != node, "replaced by a verified copy")
        let moved = try bytes(url)
        #expect(try frameRanges(moved).map(\.id) == ["TPE1", "APIC", "TIT2"])
        let coverRange = try #require(try frameRanges(moved).first { $0.id == "APIC" }).range
        #expect(Array(moved[coverRange]) == cover)
        #expect(Array(moved[try ID3Tag.parse(moved).end...]) == MP3Fixture.audio())

        // From then on, editing the title rewrites only the title.
        let node2 = inode(url)
        _ = try await TagFileWriter.write(TagValues(title: "Newer"), to: url)
        let retitled = try bytes(url)
        #expect(inode(url) == node2, "patched in place")
        let ranges = TagFileWriter.changedRanges(from: moved, to: retitled)
        #expect(ranges.reduce(0) { $0 + $1.count } < 100)
        #expect(ranges.allSatisfy { !$0.overlaps(coverRange) })
        #expect(try ID3Tag.read(retitled).title == "Newer")

        // A frame that keeps its size keeps its place, even before the cover.
        _ = try await TagFileWriter.write(TagValues(artist: "Artisx"), to: url)
        let renamed = try bytes(url)
        #expect(inode(url) == node2)
        #expect(TagFileWriter.changedRanges(from: retitled, to: renamed).reduce(0) { $0 + $1.count } == 1)
        #expect(try frameRanges(renamed).map(\.id) == ["TPE1", "APIC", "TIT2"])
        #expect(await TagReader.read(url)?.artist == "Artisx")
        try expectNoTempFiles()
    }

    @Test func tagsThatOutgrowTheirPaddingGetTheFullRewrite() async throws {
        let audio = MP3Fixture.audio()
        let url = try file("grow.mp3", MP3Fixture.id3(version: 3, frames: [MP3Fixture.text("TIT2", "T")], padding: 4) + audio)
        let node = inode(url)
        _ = try await TagFileWriter.write(TagValues(title: String(repeating: "Long title ", count: 10)), to: url)
        let written = try bytes(url)
        #expect(inode(url) != node, "replaced by a verified copy")
        #expect(Array(written[try ID3Tag.parse(written).end...]) == audio)
        try expectNoTempFiles()
    }

    @Test func halfStarRatingsMatchTheLibrary() {
        #expect(POPMRating.byte(for: 4.5) == 242)
        #expect(POPMRating.byte(for: 1) == 1)
        #expect(POPMRating.byte(for: 0) == 0)
        for stars in stride(from: 0.0, through: 5, by: 0.5) {
            #expect(POPMRating.rating(for: POPMRating.byte(for: stars)) == stars)
        }
        #expect(POPMRating.rating(for: 230) == 5, "WMP-style values from other apps still read sensibly")
    }

    // MARK: Refusals and safety

    @Test func id3v22KeepsItsThreeLetterFrames() async throws {
        func frame(_ id: String, _ body: [UInt8]) -> [UInt8] { Array(id.utf8) + [UInt8].be24(body.count) + body }
        let audio = MP3Fixture.audio()
        let picture = frame("PIC", [0] + Array("JPG".utf8) + [3, 0] + Array(repeating: 0xCD, count: 100))
        let normalization = frame("COM", [0] + Array("eng".utf8) + Array("iTunNORM".utf8) + [0] + Array(" 0000".utf8))
        let url = try file("v22.mp3", MP3Fixture.id3(version: 2, frames: [frame("TT2", [0] + Array("Old".utf8)), picture, normalization], padding: 32) + audio)

        _ = try await TagFileWriter.write(everything, to: url)
        let written = try bytes(url)
        let tag = try ID3Tag.parse(written)
        #expect(tag.version == 2)
        #expect(tag.frames.allSatisfy { $0.id.count == 3 })
        #expect(tag.frames.contains { $0.raw == picture } && tag.frames.contains { $0.raw == normalization })
        #expect(tag.frames.contains { $0.id == "POP" } && tag.frames.contains { $0.id == "TCP" })
        #expect(Array(written[tag.end...]) == audio)
        #expect(everything.isSatisfied(by: try ID3Tag.read(written)))
        let scanned = try #require(await TagReader.read(url))
        #expect(scanned.title == "Ünïcode Title")
        #expect(scanned.album == "Album")
    }

    @Test func unsupportedFilesAreLeftAlone() async throws {
        let unsync = try file("unsync.mp3", [0x49, 0x44, 0x33, 3, 0, 0x80, 0, 0, 0, 10] + Array(repeating: 0, count: 10) + MP3Fixture.audio())
        let before = try bytes(unsync)
        await #expect(throws: TagWriteError.unsupportedTag("An unsynchronised ID3 tag")) { try await TagFileWriter.write(TagValues(title: "x"), to: unsync) }
        #expect(try bytes(unsync) == before)

        let wav = dir.appendingPathComponent("tone.wav")
        try ToneFile.write(to: wav, seconds: 0.1)
        await #expect(throws: TagWriteError.unsupportedFormat("WAV")) { try await TagFileWriter.write(TagValues(title: "x"), to: wav) }

        // A frame that claims to run past the tag: refuse rather than guess.
        var broken = MP3Fixture.id3(version: 3, frames: [MP3Fixture.text("TIT2", "Title")], padding: 0) + MP3Fixture.audio()
        broken[17] = 0x7F
        let brokenURL = try file("broken.mp3", broken)
        await #expect(throws: TagWriteError.self) { try await TagFileWriter.write(TagValues(title: "x"), to: brokenURL) }
        #expect(try bytes(brokenURL) == broken)

        let missing = dir.appendingPathComponent("missing.mp3")
        await #expect(throws: TagWriteError.fileMissing) { try await TagFileWriter.write(TagValues(title: "x"), to: missing) }
        try expectNoTempFiles()
    }

    @Test func fileChangedDuringWriteIsSkipped() async throws {
        let url = try file("busy.mp3", MP3Fixture.id3(version: 3, frames: [MP3Fixture.text("TIT2", "Before")], padding: 0) + MP3Fixture.audio())
        let otherAppsVersion = try bytes(url) + [0xFF]
        await #expect(throws: TagWriteError.modifiedSinceRead) {
            try await TagFileWriter.write(TagValues(title: "After"), to: url) {
                // Another app saves the file while susurrus is verifying its copy.
                try Data(otherAppsVersion).write(to: url)
            }
        }
        #expect(try bytes(url) == otherAppsVersion, "the other app's version wins")
        try expectNoTempFiles()
    }

    @Test func unchangedValuesDontRewrite() async throws {
        let url = try file("same.mp3", MP3Fixture.audio())
        _ = try await TagFileWriter.write(TagValues(title: "Same"), to: url)
        let stamp = TagFileWriter.stamp(url)
        #expect(try await TagFileWriter.write(TagValues(title: "Same"), to: url) == .unchanged)
        #expect(TagFileWriter.stamp(url) == stamp)
    }

    @Test func keepsFinderTagsAndPermissions() async throws {
        let url = try file("meta.mp3", MP3Fixture.audio())
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let value = Array("hello".utf8)
        #expect(setxattr(url.path, "io.github.432meadow.susurrus.test", value, value.count, 0, 0) == 0)
        _ = try await TagFileWriter.write(TagValues(title: "Meta"), to: url)
        var buffer = [UInt8](repeating: 0, count: 16)
        let length = getxattr(url.path, "io.github.432meadow.susurrus.test", &buffer, buffer.count, 0, 0)
        #expect(length == value.count && Array(buffer.prefix(5)) == value)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o640)
    }

    @Test func copyGetsExactlyTheOriginalsExtendedAttributes() throws {
        let original = try file("orig.mp3", [1])
        let copy = try file("copy.mp3", [2])
        let keep = Array("keep".utf8), stale = Array("stale".utf8)
        #expect(setxattr(original.path, "io.github.432meadow.susurrus.keep", keep, keep.count, 0, 0) == 0)
        #expect(setxattr(copy.path, "io.github.432meadow.susurrus.keep", stale, stale.count, 0, 0) == 0)
        #expect(setxattr(copy.path, "io.github.432meadow.susurrus.extra", stale, stale.count, 0, 0) == 0)

        TagFileWriter.mirrorExtendedAttributes(from: original.path, to: copy.path)
        let names = TagFileWriter.extendedAttributeNames(copy.path).filter { $0 != "com.apple.provenance" }
        #expect(names == ["io.github.432meadow.susurrus.keep"])
        var buffer = [UInt8](repeating: 0, count: 16)
        #expect(getxattr(copy.path, "io.github.432meadow.susurrus.keep", &buffer, buffer.count, 0, 0) == keep.count)
        #expect(Array(buffer.prefix(keep.count)) == keep)
    }

    // MARK: FLAC

    @Test func flacCommentsRoundTripUsingPadding() async throws {
        let url = dir.appendingPathComponent("song.flac")
        try FLACFixture.write(to: url, extraComments: ["REPLAYGAIN_TRACK_GAIN=-3 dB", "TITLE=Old", "ALBUM ARTIST=Stale"], padding: 512)
        let original = try bytes(url)
        let before = try FLACTag.parse(original)
        let node = inode(url)

        _ = try await TagFileWriter.write(everything, to: url)
        let written = try bytes(url)
        let after = try FLACTag.parse(written)
        #expect(after.audioStart == before.audioStart, "padding absorbed the growth")
        #expect(inode(url) == node, "patched in place")
        #expect(Array(written[after.audioStart...]) == Array(original[before.audioStart...]))
        let comments = try FLACTag.parseComments(try #require(after.blocks.first { $0.type == 4 }).body).entries
        #expect(comments.contains("REPLAYGAIN_TRACK_GAIN=-3 dB"))
        #expect(comments.contains("RATING=90"))
        #expect(comments.contains("TRACKNUMBER=3") && comments.contains("TRACKTOTAL=12"))
        #expect(!comments.contains("TITLE=Old") && !comments.contains("ALBUM ARTIST=Stale"))
        #expect(everything.isSatisfied(by: try FLACTag.read(written)))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.05)
        try expectNoTempFiles()
    }

    /// Each metadata block's type and byte range, header included.
    private func flacBlocks(_ bytes: [UInt8]) throws -> [(type: UInt8, range: Range<Int>)] {
        var pos = try #require(FLACTag.findMarker(bytes)) + 4
        var blocks: [(type: UInt8, range: Range<Int>)] = []
        while true {
            let header = bytes[pos], end = pos + 4 + bytes.uint24BE(at: pos + 1)
            blocks.append((header & 0x7F, pos..<end))
            pos = end
            if header & 0x80 != 0 { return blocks }
        }
    }

    @Test func flacTitleEditsLeaveALargeCoverWhereItIs() async throws {
        let url = dir.appendingPathComponent("covered.flac")
        let picture = FLACTag.pictureBody(Artwork(data: Data(LargeCover.bytes), mimeType: "image/jpeg"))
        try FLACFixture.write(to: url, extraComments: ["TITLE=Old", "REPLAYGAIN_TRACK_GAIN=-3 dB"], padding: 8192, picture: picture)
        let original = try bytes(url)
        #expect(try flacBlocks(original).map(\.type).suffix(3) == [4, 6, 1], "comments, cover, then padding")
        let coverRange = try #require(try flacBlocks(original).first { $0.type == 6 }).range
        let node = inode(url)

        // The comments grow, and the padding is past the cover: they move into the padding, and
        // their old place becomes padding of the same size.
        _ = try await TagFileWriter.write(TagValues(title: "A much longer title than before"), to: url)
        let moved = try bytes(url)
        #expect(inode(url) == node, "patched in place")
        #expect(moved.count == original.count)
        #expect(try flacBlocks(moved).map(\.type).suffix(4) == [1, 6, 4, 1])
        #expect(try flacBlocks(moved).first { $0.type == 6 }?.range == coverRange)
        let ranges = TagFileWriter.changedRanges(from: original, to: moved)
        #expect(ranges.count == 2 && ranges.reduce(0) { $0 + $1.count } < 1024)
        #expect(ranges.allSatisfy { !$0.overlaps(coverRange) })
        let comments = try FLACTag.parseComments(try #require(try FLACTag.parse(moved).blocks.first { $0.type == 4 }).body).entries
        #expect(comments.contains("TITLE=A much longer title than before") && comments.contains("REPLAYGAIN_TRACK_GAIN=-3 dB"))
        #expect(try FLACTag.read(moved).artwork?.data == Data(LargeCover.bytes))

        // Now the padding follows the comments, so the next edit is one small write.
        _ = try await TagFileWriter.write(TagValues(title: "Short", rating: 4), to: url)
        let retitled = try bytes(url)
        #expect(inode(url) == node)
        let next = TagFileWriter.changedRanges(from: moved, to: retitled)
        #expect(next.count == 1 && next.allSatisfy { !$0.overlaps(coverRange) })
        #expect(TagValues(title: "Short", rating: 4).isSatisfied(by: try FLACTag.read(retitled)))
        #expect(Array(retitled[try FLACTag.parse(retitled).audioStart...]) == Array(original[try FLACTag.parse(original).audioStart...]))
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.05)
        try expectNoTempFiles()
    }

    @Test func flacCommentsThatShrinkLeavePaddingInPlace() async throws {
        let url = dir.appendingPathComponent("shrink.flac")
        let picture = FLACTag.pictureBody(Artwork(data: Data(LargeCover.bytes), mimeType: "image/jpeg"))
        try FLACFixture.write(to: url, extraComments: ["COMMENT=A comment to clear"], padding: 512, picture: picture)
        let original = try bytes(url)
        let coverRange = try #require(try flacBlocks(original).first { $0.type == 6 }).range

        _ = try await TagFileWriter.write(TagValues(comment: ""), to: url)
        let written = try bytes(url)
        #expect(try flacBlocks(written).map(\.type).suffix(4) == [4, 1, 6, 1], "the room left is padding right after the comments")
        #expect(try flacBlocks(written).first { $0.type == 6 }?.range == coverRange)
        #expect(TagFileWriter.changedRanges(from: original, to: written).allSatisfy { !$0.overlaps(coverRange) })
        #expect(try FLACTag.read(written).comment == nil)
    }

    @Test func aFileThatGetsShorterWhileItsTagsAreReadIsSkipped() throws {
        // FLAC metadata running past the end: what's left of a file that shrank after it was looked at.
        let url = try file("shrunk.flac", Array("fLaC".utf8) + [0] + [UInt8].be24(500_000) + [UInt8](repeating: 0, count: 100))
        #expect(throws: TagWriteError.modifiedSinceRead) {
            try TagFileWriter.leadingTags(of: url, size: 1_000_000)
        }
    }

    // MARK: M4A

    @Test func m4aItemsRoundTripAndAudioStillDecodes() async throws {
        let url = dir.appendingPathComponent("song.m4a")
        try ToneFile.write(to: url, seconds: 0.5, format: kAudioFormatMPEG4AAC)
        let originalDuration = try await AVURLAsset(url: url).load(.duration).seconds

        // First write creates udta/meta/ilst (and shifts chunk offsets: moov sits before mdat).
        _ = try await TagFileWriter.write(everything, to: url)
        var scanned = try #require(await TagReader.read(url))
        #expect(scanned.title == "Ünïcode Title")
        #expect(scanned.albumArtist == "Album Artist")
        #expect(scanned.trackNumber == 3 && scanned.trackCount == 12)
        #expect(scanned.discNumber == 1 && scanned.discCount == 2)
        #expect(scanned.bpm == 128)
        #expect(scanned.compilation)
        #expect(abs(scanned.duration - originalDuration) < 0.01)
        #expect(everything.isSatisfied(by: {
            var stored = (try? MP4Tag.read(try bytes(url))) ?? TagValues()
            stored.rating = everything.rating  // MP4 ratings aren't written
            return stored
        }()))

        // Second write edits an existing ilst; shrinking leaves a free atom instead of moving audio.
        _ = try await TagFileWriter.write(TagValues(title: "T", artist: ""), to: url)
        scanned = try #require(await TagReader.read(url))
        #expect(scanned.title == "T")
        #expect(try MP4Tag.read(try bytes(url)).artist == nil, "clearing a field removes its item")
        #expect(scanned.album == "Album")

        // And the audio still decodes to the same frames.
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / file.fileFormat.sampleRate - originalDuration) < 0.05)
        try expectNoTempFiles()
    }

    @Test func m4aRatingOnlyEditIsANoOp() async throws {
        let url = dir.appendingPathComponent("rated.m4a")
        try ToneFile.write(to: url, seconds: 0.2, format: kAudioFormatMPEG4AAC)
        #expect(try await TagFileWriter.write(TagValues(rating: 5), to: url) == .unchanged)
    }

    // MARK: Keys

    @Test func keysRoundTripInMP3AndFLAC() async throws {
        let mp3 = try file("keyed.mp3", MP3Fixture.id3(version: 3, frames: [MP3Fixture.text("TIT2", "Song")], padding: 64) + MP3Fixture.audio())
        _ = try await TagFileWriter.write(TagValues(key: "F#m"), to: mp3)
        #expect(try ID3Tag.read(try bytes(mp3)).key == "F#m")
        #expect(try #require(await TagReader.read(mp3)).musicalKey == "F#m")

        let flac = dir.appendingPathComponent("keyed.flac")
        try FLACFixture.write(to: flac, extraComments: ["KEY=8A"], padding: 256)
        _ = try await TagFileWriter.write(TagValues(key: "Am"), to: flac)
        let comments = try FLACTag.parseComments(try #require(try FLACTag.parse(try bytes(flac)).blocks.first { $0.type == 4 }).body).entries
        #expect(comments.contains("INITIALKEY=Am") && !comments.contains("KEY=8A"), "the old spelling is replaced")
        try expectNoTempFiles()
    }

    @Test func m4aKeyOnlyEditIsANoOp() async throws {
        let url = dir.appendingPathComponent("keyed.m4a")
        try ToneFile.write(to: url, seconds: 0.2, format: kAudioFormatMPEG4AAC)
        #expect(try await TagFileWriter.write(TagValues(key: "Am"), to: url) == .unchanged)
    }

    // MARK: Queue and model glue

    @Test func editValuesKeepTheOtherHalfOfNumberPairs() {
        let track = Track(id: 1)
        track.trackNumber = 2
        track.totalNumberOfTracks = 9
        let edit = TrackEdit(trackNumber: 5)
        edit.apply(to: track)
        let values = TagValues(edit: edit, track: track)
        #expect(values == TagValues(track: .init(number: 5, total: 9)))
        #expect(TagValues.numberText(.init(number: 5, total: 9)) == "5/9")
        #expect(TagValues.numberText(.init(number: 0, total: 0)) == "")
    }

    @MainActor @Test func queueMergesEditsAndWaitsForPlayingFiles() async {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var calls: [(String, TagValues)] = []
            func add(_ path: String, _ values: TagValues) { lock.withLock { calls.append((path, values)) } }
        }
        let log = Log()
        let queue = TagWriteQueue(retryDelay: .milliseconds(20)) { values, url in
            log.add(url.lastPathComponent, values)
            if url.lastPathComponent == "bad.mp3" { throw TagWriteError.fileMissing }
            try await Task.sleep(for: .milliseconds(30))
            return .written(fileSize: 1)
        }
        var playing: String? = "/x/playing.mp3"
        queue.isInUse = { $0 == playing }
        var rewritten: [String] = []
        queue.didWrite = { path, _ in rewritten.append(path) }

        queue.enqueue(TagValues(rating: 1), path: "/x/playing.mp3")
        queue.enqueue(TagValues(title: "A"), path: "/x/a.mp3")
        queue.enqueue(TagValues(artist: "B"), path: "/x/b.mp3")
        queue.enqueue(TagValues(rating: 2), path: "/x/b.mp3")  // merged into the pending b write
        queue.enqueue(TagValues(title: "Bad"), path: "/x/bad.mp3")
        #expect(queue.total == 4)

        // Everything else gets written while the playing file waits.
        let deadline = Date().addingTimeInterval(10)
        while queue.waitingForPath == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(queue.waitingForPath == "/x/playing.mp3")
        playing = nil
        await queue.waitUntilIdle()

        let calls = log.lock.withLock { log.calls }
        #expect(calls.map(\.0) == ["a.mp3", "b.mp3", "bad.mp3", "playing.mp3"])
        #expect(calls[1].1 == TagValues(artist: "B", rating: 2))
        #expect(queue.done == 4 && queue.written == 3)
        #expect(queue.failures.map(\.path) == ["/x/bad.mp3"])
        #expect(rewritten == ["/x/a.mp3", "/x/b.mp3", "/x/playing.mp3"])
        #expect(!queue.isRunning)
    }

    @MainActor @Test func editsMadeWhileAFileIsWrittenAreSavedWithTheValuesBeingWritten() async {
        let gate = Gate()
        let queue = TagWriteQueue(retryDelay: .milliseconds(10)) { _, _ in
            await gate.wait()
            return .written(fileSize: 1)
        }
        var saved: [TagValues?] = []
        queue.persist = { _, values in saved.append(values) }

        queue.enqueue(TagValues(title: "A"), path: "/x/a.mp3")
        let deadline = Date().addingTimeInterval(10)
        while queue.currentPath == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        queue.enqueue(TagValues(rating: 4), path: "/x/a.mp3")
        #expect(saved.last == TagValues(title: "A", rating: 4), "quitting now still leaves the title to write")

        gate.open()
        await queue.waitUntilIdle()
        #expect(saved == [TagValues(title: "A"), TagValues(title: "A", rating: 4), TagValues(rating: 4), nil],
                "once the title is written only the rating is left, then nothing")
    }

    @MainActor @Test func resumedWritesArentSavedAgain() async {
        let queue = TagWriteQueue { _, _ in .written(fileSize: 1) }
        var saved: [String: TagValues?] = [:]
        queue.persist = { path, values in saved[path] = values }
        queue.resume([("/x/a.mp3", TagValues(title: "A")), ("/x/b.mp3", TagValues(rating: 2))])
        #expect(queue.total == 2 && saved.isEmpty)
        await queue.waitUntilIdle()
        #expect(queue.written == 2)
        #expect(saved.count == 2 && saved.values.allSatisfy { $0 == nil }, "each is forgotten once written")
    }
}

/// Holds async callers until it's opened.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() { lock.withLock { isOpen = true } }

    func wait() async {
        while !lock.withLock({ isOpen }) { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

// MARK: - Fixtures

/// Hand-built MP3s: silent MPEG-1 Layer III frames (128 kbps, 44.1 kHz) with optional ID3 tags.
enum MP3Fixture {
    static func audio(frames: Int = 40) -> [UInt8] {
        (0..<frames).flatMap { _ in [0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0, count: 413) }
    }

    static let id3v1: [UInt8] = Array("TAG".utf8) + Array("v1 title".utf8) + [UInt8](repeating: 0, count: 117)

    static func frame(_ id: String, _ body: [UInt8], version: UInt8 = 3) -> [UInt8] {
        let size = version == 4
            ? [UInt8(body.count >> 21 & 0x7F), UInt8(body.count >> 14 & 0x7F), UInt8(body.count >> 7 & 0x7F), UInt8(body.count & 0x7F)]
            : [UInt8].be32(body.count)
        return Array(id.utf8) + size + [0, 0] + body
    }

    static func text(_ id: String, _ value: String, version: UInt8 = 3) -> [UInt8] {
        frame(id, (version == 4 ? [3] + Array(value.utf8) : [0] + value.unicodeScalars.map { UInt8($0.value) }), version: version)
    }

    static func id3(version: UInt8, frames: [[UInt8]], padding: Int) -> [UInt8] {
        let body = frames.flatMap { $0 } + [UInt8](repeating: 0, count: padding)
        let n = body.count
        return [0x49, 0x44, 0x33, version, 0, 0, UInt8(n >> 21 & 0x7F), UInt8(n >> 14 & 0x7F), UInt8(n >> 7 & 0x7F), UInt8(n & 0x7F)] + body
    }
}

/// Stand-in image bytes for an embedded cover the size of a real one (200 KB).
enum LargeCover {
    static let bytes: [UInt8] = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
}

/// FLAC files from AVAudioFile's encoder, with extra comments, optionally a picture block right
/// after them, and a padding block at the end.
enum FLACFixture {
    static func write(to url: URL, extraComments: [String], padding: Int, picture: [UInt8]? = nil) throws {
        try ToneFile.write(to: url, seconds: 0.5, format: kAudioFormatFLAC)
        let bytes = [UInt8](try Data(contentsOf: url))
        let parsed = try FLACTag.parse(bytes)
        var blocks = parsed.blocks.filter { $0.type != 1 }
        if let index = blocks.firstIndex(where: { $0.type == 4 }) {
            var comments = try FLACTag.parseComments(blocks[index].body)
            comments.entries += extraComments
            blocks[index].body = FLACTag.encodeComments(comments)
            if let picture { blocks.insert(FLACTag.Block(type: 6, body: picture), at: index + 1) }
        }
        blocks.append(FLACTag.Block(type: 1, body: [UInt8](repeating: 0, count: padding)))
        var out = Array("fLaC".utf8)
        for (i, block) in blocks.enumerated() {
            out += [(i == blocks.count - 1 ? 0x80 : 0) | block.type] + [UInt8].be24(block.body.count) + block.body
        }
        try Data(out + Array(bytes[parsed.audioStart...])).write(to: url)
    }
}
