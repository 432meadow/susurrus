import AVFoundation
import Foundation

/// Keeps what comes out of a node (the EQ: it's ahead of the volume, so it hears the tests' silent
/// playback), to check how it actually sounds.
final class AudioRecording: @unchecked Sendable {
    /// The tone `toneContinuity` looks for. In whole cycles per second, so one-second files of it
    /// join up at any sample rate.
    static let toneFrequency = 100.0

    private let lock = NSLock()
    private var channels: [[Float]] = [[], []]
    private var rate = 0.0
    private var nextSampleTime: AVAudioFramePosition?
    private var isBroken = false

    func start(on node: AVAudioNode) {
        node.installTap(onBus: 0, bufferSize: 2048, format: nil) { [self] buffer, time in
            lock.withLock {
                rate = buffer.format.sampleRate
                // A real overload, nothing to do with the player: its stretch can't be measured.
                if let nextSampleTime, time.isSampleTimeValid, time.sampleTime != nextSampleTime { isBroken = true }
                nextSampleTime = time.sampleTime + AVAudioFramePosition(buffer.frameLength)
                for channel in 0..<2 {
                    let source = buffer.floatChannelData![min(channel, Int(buffer.format.channelCount) - 1)]
                    channels[channel].append(contentsOf: UnsafeBufferPointer(start: source, count: Int(buffer.frameLength)))
                }
            }
        }
    }

    func stop(on node: AVAudioNode) {
        node.removeTap(onBus: 0)
    }

    /// Follows a tone (by default `toneFrequency`) through the recording, 50 ms at a time: how far
    /// its phase wanders from where it started, the quietest it gets, and how far any sample strays
    /// from the sine that fits its window, over the part where it sounds at all.
    func toneContinuity(channel: Int = 0, frequency: Double = toneFrequency)
        -> (slipInSamples: Double, quietestAmplitude: Double, worstDeviation: Double, seconds: Double) {
        let (samples, rate, isBroken) = lock.withLock { (self.channels[channel], self.rate, self.isBroken) }
        guard !isBroken, rate > 0, let first = samples.firstIndex(where: { abs($0) > 1e-3 }),
              let last = samples.lastIndex(where: { abs($0) > 1e-3 }), last > first else { return (0, 0, 0, 0) }
        let window = Int(rate * 0.05)
        var opening: Double?
        var slip = 0.0, quietest = Double.infinity, worst = 0.0
        // The tone's first and last windows hold its fade from nothing and into it.
        var start = first + window
        while start + 2 * window < last {
            var sine = 0.0, cosine = 0.0
            for n in 0..<window {
                let angle = 2 * Double.pi * frequency * Double(start + n) / rate
                sine += Double(samples[start + n]) * sin(angle)
                cosine += Double(samples[start + n]) * cos(angle)
            }
            sine *= 2 / Double(window)
            cosine *= 2 / Double(window)
            quietest = min(quietest, (sine * sine + cosine * cosine).squareRoot())
            for n in 0..<window {
                let angle = 2 * Double.pi * frequency * Double(start + n) / rate
                worst = max(worst, abs(Double(samples[start + n]) - sine * sin(angle) - cosine * cos(angle)))
            }
            let phase = atan2(cosine, sine)
            if let opening {
                var difference = phase - opening
                while difference > .pi { difference -= 2 * .pi }
                while difference < -.pi { difference += 2 * .pi }
                slip = max(slip, abs(difference) / (2 * .pi * frequency) * rate)
            } else {
                opening = phase
            }
            start += window
        }
        return (slip, quietest, worst, Double(last - first) / rate)
    }
}
