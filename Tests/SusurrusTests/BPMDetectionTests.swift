import AVFoundation
import Foundation
import Testing
@testable import Susurrus

/// BPM detection on generated drum patterns, and the background queue with a stand-in detector.
/// Serialized and async: run in parallel, these CPU-heavy cases starve the player tests' real-time
/// playback (which wants the main actor and the shared thread pool) and make them miss timings.
@Suite(.serialized) struct BPMDetectionTests {
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BPMDetectionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Cheap and repeatable (the system generator is slow for millions of samples in a debug
    /// build, and these tests run next to the player's real-time ones).
    private struct Noise: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    /// Kick on 1 and 3, snare on 2 and 4, closed hats on the eighths, over a quiet noise bed.
    private static func drums(bpm: Double, seconds: Double, sampleRate: Double = 44100) -> [Float] {
        var generator = Noise()
        let count = Int(seconds * sampleRate)
        var samples = (0..<count).map { _ in Float.random(in: -0.02...0.02, using: &generator) }
        let eighth = 60 / bpm / 2 * sampleRate
        func hit(at start: Int, length: Double, _ voice: (Double, inout Noise) -> Float) {
            for i in 0..<Int(length * sampleRate) where start + i < count {
                let t = Double(i) / sampleRate
                samples[start + i] += voice(t, &generator)
            }
        }
        var step = 0
        while Double(step) * eighth < Double(count) {
            let start = Int(Double(step) * eighth)
            switch step % 4 {
            case 0: hit(at: start, length: 0.25) { t, _ in Float(sin(2 * .pi * (50 + 100 * exp(-t * 30)) * t) * exp(-t * 12)) * 0.8 }
            case 2: hit(at: start, length: 0.2) { t, noise in Float.random(in: -1...1, using: &noise) * Float(exp(-t * 20)) * 0.5 }
            default: break
            }
            hit(at: start, length: 0.05) { t, noise in Float.random(in: -1...1, using: &noise) * Float(exp(-t * 80)) * 0.2 }
            step += 1
        }
        return samples
    }

    /// Tempos come back folded into 70–140, like the library's existing tags.
    @Test(arguments: [(84.0, 84.0), (100, 100), (124, 124), (150, 75), (172, 86)])
    func findsTheTempoOfASteadyBeat(bpm: Double, reported: Double) async throws {
        let detected = try #require(BPMDetector.tempo(of: .init(samples: Self.drums(bpm: bpm, seconds: 30, sampleRate: 11025), sampleRate: 11025)))
        #expect(abs(detected - reported) < 1, "detected \(detected) for \(bpm)")
    }

    @Test func noBeatInNoiseOrSilence() async {
        var generator = Noise()
        let noise = (0..<11025 * 30).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
        #expect(BPMDetector.tempo(of: .init(samples: noise, sampleRate: 11025)) == nil)
        #expect(BPMDetector.tempo(of: .init(samples: [Float](repeating: 0, count: 11025 * 30), sampleRate: 11025)) == nil)
        #expect(BPMDetector.tempo(of: .init(samples: Self.drums(bpm: 120, seconds: 3, sampleRate: 11025), sampleRate: 11025)) == nil)
    }

    private func write(_ samples: [Float], to url: URL, settings: [String: Any]) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) }
        }
        try file.write(from: buffer)
    }

    @Test func readsTheMiddleOfAWAVFile() async throws {
        let url = dir.appendingPathComponent("beat.wav")
        try write(Self.drums(bpm: 128, seconds: 40), to: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let excerpt = try BPMDetector.readExcerpt(url)
        #expect(abs(Double(excerpt.samples.count) / excerpt.sampleRate - 30) < 0.01)
        #expect(excerpt.sampleRate == 11025)
        #expect(abs(try #require(BPMDetector.tempo(of: excerpt)) - 128) < 1)
    }

    /// Long enough that only a fragment from the middle is read, rebuilt into its own FLAC file.
    @Test func readsAFragmentOfAFLACFile() async throws {
        let url = dir.appendingPathComponent("beat.flac")
        try write(Self.drums(bpm: 96, seconds: 70), to: url, settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
        ])
        func fragments() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return Set(names.filter { $0.hasPrefix("susurrus-bpm-") })
        }
        let before = fragments()
        let excerpt = try BPMDetector.readExcerpt(url)
        #expect(abs(Double(excerpt.samples.count) / excerpt.sampleRate - 30) < 0.01)
        #expect(abs(try #require(BPMDetector.tempo(of: excerpt)) - 96) < 1)
        // Its temp file is gone again. Other test runs on the Mac share the temp folder, so one of
        // theirs may be there for a moment; a leaked one would stay.
        let deadline = Date().addingTimeInterval(10)
        while !fragments().subtracting(before).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(fragments().subtracting(before).isEmpty)
    }

    @Test func findsFLACFrameHeadersByTheirChecksum() {
        // A fixed-blocksize frame header (4096 samples, 44.1 kHz, stereo, 16-bit, frame 1) and its CRC-8.
        let header: [UInt8] = [0xFF, 0xF8, 0xC9, 0x18, 0x01, 0xC5]
        let fakeSync: [UInt8] = [0xFF, 0xF8, 0xC9, 0x18, 0x01, 0x00]  // right shape, wrong checksum
        let data = Data([0x12, 0xFF, 0x00] + fakeSync + header + [UInt8](repeating: 0, count: 32))
        #expect(BPMDetector.firstFLACFrame(in: data) == 3 + fakeSync.count)
        #expect(BPMDetector.firstFLACFrame(in: Data(fakeSync + [UInt8](repeating: 0, count: 32))) == nil)
    }

    @Test func findsMP3FramesThatChain() {
        // MPEG-1 layer III, 128 kbps, 44.1 kHz, no padding: 417-byte frames.
        let frame = [0xFF, 0xFB, 0x90, 0x00] + [UInt8](repeating: 0x11, count: 413)
        let straySync: [UInt8] = [0xFF, 0xFB, 0x90, 0x00, 0x42]  // looks like a header, nothing follows
        let data = Data(straySync + frame + frame + frame)
        #expect(BPMDetector.firstMP3Frame(in: data) == straySync.count)
        #expect(BPMDetector.firstMP3Frame(in: Data(frame + frame)) == nil)
        #expect(BPMDetector.firstMP3Frame(in: Data(count: 4096)) == nil)
    }

    @MainActor @Test func queueSkipsDuplicatesRoundsAndCancels() async {
        let queue = TrackAnalysisQueue<Int>(width: 2) { url in
            Thread.sleep(forTimeInterval: 0.01)
            switch url.lastPathComponent {
            case "missing.mp3": throw CocoaError(.fileNoSuchFile)
            case "ambient.mp3": return nil
            default: return 128
            }
        }
        var saved: [(Int64, Int)] = []
        queue.didDetect = { saved += $0 }

        queue.enqueue([(1, "/x/a.mp3"), (2, "/x/missing.mp3"), (3, "/x/ambient.mp3"), (1, "/x/a.mp3")])
        #expect(queue.total == 3)
        await queue.waitUntilIdle()
        #expect(queue.done == 3)
        #expect(queue.detected == 1)
        #expect(saved.map(\.0) == [1] && saved.map(\.1) == [128])

        saved = []
        queue.enqueue((10..<40).map { (Int64($0), "/x/\($0).mp3") })
        queue.cancel()
        await queue.waitUntilIdle()
        // Only the files already being read when it was cancelled finish.
        #expect(queue.done == queue.total && queue.total <= 2)
        #expect(saved.count == queue.done)
    }
}
