import SwiftUI
import UniformTypeIdentifiers

/// The two-deck mixer, above the now-playing bar: deck A, the mixer section, deck B. Styled like
/// the bar below it and the Equalizer: system controls on the bar material, the deck colours
/// (rose for A, slate for B) only where they say which deck something belongs to.
struct MixerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mixer = model.mixer
        VStack(spacing: 0) {
            if model.isShowingBeatView {
                BeatView(mixer: mixer)
                Divider()
            }
            HStack(spacing: 0) {
                DeckView(deck: mixer.a, other: mixer.b, accent: Palette.warm)
                Divider()
                MixerSection(mixer: mixer)
                    .frame(width: 280)
                Divider()
                DeckView(deck: mixer.b, other: mixer.a, accent: Palette.cool)
            }
            .frame(height: 176)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

extension UTType {
    /// One track ID per dragged row, as the track table writes it.
    static let susurrusTrackID = UTType(importedAs: "io.github.432meadow.susurrus.track-ids")
}

// MARK: - Beats

/// Both decks close up, one above the other, scrolling past a shared playhead at the same speed,
/// with each track's beat grid drawn over it. The beats are lined up when the grid lines meet.
private struct BeatView: View {
    let mixer: Mixer
    /// How much playing time the strips span.
    static let seconds = 4.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !mixer.a.isPlaying && !mixer.b.isPlaying)) { _ in
            HStack(spacing: 12) {
                VStack(spacing: 3) {
                    BeatStrip(deck: mixer.a, time: mixer.a.currentTime, accent: Palette.warm)
                    BeatStrip(deck: mixer.b, time: mixer.b.currentTime, accent: Palette.cool)
                }
                .overlay { Rectangle().fill(.primary).frame(width: 1.5).allowsHitTesting(false) }
                PhaseReadout(offset: mixer.beatOffset)
                    .frame(width: 58)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private struct BeatStrip: View {
    let deck: Deck
    let time: TimeInterval
    let accent: Color
    @State private var dragStart: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in draw(in: &context, size: size) }
                .contentShape(Rectangle())
                .gesture(
                    // Paused, dragging moves the track under the playhead, for cueing on a beat.
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            guard deck.isReady, !deck.isPlaying, geometry.size.width > 0 else { return }
                            let start = dragStart ?? time
                            dragStart = start
                            let secondsPerPoint = BeatView.seconds * deck.playbackRate / geometry.size.width
                            deck.seek(to: max(0, start - drag.translation.width * secondsPerPoint))
                        }
                        .onEnded { _ in dragStart = nil }
                )
        }
        .frame(height: 28)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
        .help(deck.isReady && !deck.isPlaying ? "Drag to move deck \(deck.side.name) under the playhead" : "")
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard let analysis = deck.analysis, deck.track != nil else { return }
        let half = BeatView.seconds / 2 * deck.playbackRate  // track seconds either side
        let middle = size.width / 2
        let scale = middle / half  // points per track second
        let rate = analysis.detailRate
        let first = max(0, Int(((time - half) * rate).rounded(.down)))
        let last = min(analysis.detail.count - 1, Int(((time + half) * rate).rounded(.up)))
        if first <= last {
            let width = max(1, scale / rate * 0.75)
            var bars = Path()
            for index in first...last {
                let x = middle + (Double(index) / rate - time) * scale
                let height = max(1, CGFloat(analysis.detail[index]) * (size.height - 4))
                bars.addRect(CGRect(x: x, y: (size.height - height) / 2, width: width, height: height))
            }
            context.fill(bars, with: .color(accent.opacity(0.8)))
        }
        if let grid = analysis.grid {
            var lines = Path()
            for beat in grid.beats(from: time - half, to: time + half) {
                lines.addRect(CGRect(x: middle + (beat - time) * scale - 0.5, y: 0, width: 1, height: size.height))
            }
            context.fill(lines, with: .color(.primary.opacity(0.55)))
        }
    }
}

/// How far apart the two decks' beats are, while both play.
private struct PhaseReadout: View {
    let offset: TimeInterval?

    var body: some View {
        VStack(spacing: 1) {
            Text("Phase").font(.caption2).foregroundStyle(.secondary)
            if let offset {
                let ms = Int((abs(offset) * 1000).rounded())
                if ms <= 5 {
                    Text("Locked").font(.caption.weight(.semibold))
                } else {
                    Text("\(offset > 0 ? "A" : "B") +\(ms) ms").font(.caption.monospacedDigit())
                }
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .help("How far ahead one deck's beat is. Hold a nudge button on the deck that's ahead to slow it.")
    }
}

// MARK: - Deck

private struct DeckView: View {
    @Environment(AppModel.self) private var model
    let deck: Deck
    let other: Deck
    let accent: Color
    @State private var isDropTarget = false

    var body: some View {
        @Bindable var deck = deck
        VStack(alignment: .leading, spacing: 10) {
            header
            WaveformView(deck: deck, accent: accent)
                .frame(height: 50)
            HStack(spacing: 12) {
                HStack(spacing: 14) {
                    Button { deck.togglePlay() } label: {
                        Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2)
                            .frame(width: 20)
                    }
                    .help(deck.isPlaying ? "Pause" : "Play")
                    Button { deck.cue() } label: {
                        Text("CUE").font(.caption.weight(.semibold))
                    }
                    .help("Playing: back to the cue point. Paused: set the cue point here.")
                }
                .buttonStyle(.borderless)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    NudgeButton(deck: deck, direction: -1)
                    Slider(value: $deck.tempo, in: -Deck.tempoRange...Deck.tempoRange)
                        .accessibilityLabel("Deck \(deck.side.name) tempo")
                        .controlSize(.mini)
                        .frame(minWidth: 60, maxWidth: 120)
                        .onTapGesture(count: 2) { deck.tempo = 0 }
                        .onScrollWheel { deck.tempo = min(max(deck.tempo + $0 * 0.0002, -Deck.tempoRange), Deck.tempoRange) }
                        .help("Tempo ±8% — double-click to reset")
                    NudgeButton(deck: deck, direction: 1)
                }
                Button("Match") { deck.matchTempo(to: other) }
                    .controlSize(.small)
                    .disabled(deck.tempoMatching(other) == nil)
                    .help(matchHelp)
            }
            .disabled(!deck.isReady)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.12))
                    .strokeBorder(accent, lineWidth: 1.5)
                    .padding(4)
            }
        }
        .onDrop(of: [.susurrusTrackID, .fileURL], isTargeted: $isDropTarget, perform: load)
        .contextMenu { deckMenu }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArtworkView(request: deck.track?.artworkRequest, pixelSize: 96)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(deck.side.name)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    if let track = deck.track {
                        Text(track.displayTitle).font(.headline).lineLimit(1)
                        if deck.isLoading { ProgressView().controlSize(.mini) }
                    } else {
                        Text("Empty").font(.headline).foregroundStyle(.secondary)
                    }
                }
                if let error = deck.errorMessage {
                    Text(error).font(.subheadline).foregroundStyle(Palette.error).lineLimit(1)
                } else if let track = deck.track {
                    Text([track.displayArtist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Drag a track here, or Track ▸ Load on Deck \(deck.side.name)")
                        .font(.subheadline).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(deck.effectiveBPM.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(deck.effectiveBPM == nil ? .tertiary : .primary)
                Text(deck.tempo == 0 ? "BPM" : String(format: "BPM %+.1f%%", deck.tempo * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(deck.tempo == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(accent))
            }
            .help(deck.track != nil && deck.effectiveBPM == nil ? "No BPM yet — Track ▸ Detect BPM" : "")
            KeyReadout(deck: deck, other: other)
            Menu { deckMenu } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Load or eject")
        }
    }

    @ViewBuilder private var deckMenu: some View {
        Button("Load Now Playing") {
            if let track = model.player.currentTrack { model.load(track, on: deck.side) }
        }
        .disabled(model.player.currentTrack == nil)
        Button("Load Selected Track") {
            if let track = model.selectedTracks.first { model.load(track, on: deck.side) }
        }
        .disabled(model.selectedTrackIDs.isEmpty)
        Divider()
        Button("Eject") { deck.eject() }
            .disabled(deck.track == nil)
    }

    private var matchHelp: String {
        guard let target = other.effectiveBPM else { return "Match tempo to deck \(other.side.name) (needs both BPMs)" }
        return String(format: "Match tempo to deck %@ (%.1f BPM)", other.side.name, target)
    }

    /// Takes a track dragged from a track list (or a library file dragged from the Finder).
    private func load(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let model = model
        let side = deck.side
        if provider.hasItemConformingToTypeIdentifier(UTType.susurrusTrackID.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.susurrusTrackID.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8),
                      let id = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
                Task { @MainActor in model.loadTrack(id: id, on: side) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let path = url?.path else { return }
                Task { @MainActor in
                    if let track = model.track(atPath: path) { model.load(track, on: side) }
                }
            }
            return true
        }
        return false
    }
}

/// The deck's key in Camelot and standard notation, as it sounds at the current tempo, with a
/// check or a warning for how it sits with the other deck's.
private struct KeyReadout: View {
    let deck: Deck
    let other: Deck

    var body: some View {
        let key = deck.effectiveKey
        let otherKey = other.effectiveKey
        VStack(alignment: .trailing, spacing: 1) {
            Text(key?.camelot ?? "—")
                .font(.title3.monospacedDigit())
                .foregroundStyle(key == nil ? .tertiary : .primary)
            HStack(spacing: 2) {
                if let key, let otherKey {
                    Image(systemName: key.isCompatible(with: otherKey) ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(key.isCompatible(with: otherKey) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.ochre))
                }
                Text(key?.name ?? "Key").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 30, alignment: .trailing)
        .help(help)
    }

    private var help: String {
        guard let key = deck.effectiveKey else {
            return deck.track == nil ? "" : "No key yet — Track ▸ Detect Key"
        }
        var lines: [String] = []
        if deck.pitchShift != 0, let original = deck.key {
            lines.append("\(original.label), shifted \(deck.pitchShift > 0 ? "up" : "down") a semitone by the tempo")
        }
        if let otherKey = other.effectiveKey {
            lines.append(key.isCompatible(with: otherKey)
                ? "Mixes with deck \(other.side.name) (\(otherKey.camelot))"
                : "Clashes with deck \(other.side.name) (\(otherKey.camelot))")
        }
        return lines.isEmpty ? key.label : lines.joined(separator: "\n")
    }
}

/// The whole track's loudness as mirrored bars, the played part in the deck's colour. Click or
/// drag to seek.
private struct WaveformView: View {
    let deck: Deck
    let accent: Color
    /// Fraction of the track under the pointer while dragging.
    @State private var scrub: Double?

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !deck.isPlaying)) { _ in
                let duration = deck.duration
                let time = scrub.map { $0 * duration } ?? deck.currentTime
                let progress = duration > 0 ? time / duration : 0
                Canvas { context, size in
                    draw(in: &context, size: size, progress: progress, cue: duration > 0 ? deck.cuePoint / duration : 0)
                }
                .overlay(alignment: .bottomLeading) { timeLabel(Format.time(time)) }
                .overlay(alignment: .bottomTrailing) { timeLabel("-" + Format.time(max(0, duration - time))) }
                .opacity(deck.track == nil ? 0 : 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard deck.isReady, geometry.size.width > 0 else { return }
                        scrub = min(max(value.location.x / geometry.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        if let scrub { deck.seek(to: scrub * deck.duration) }
                        scrub = nil
                    }
            )
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            if deck.track == nil {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func timeLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress: Double, cue: Double) {
        let middle = size.height / 2
        let pitch: CGFloat = 3  // bar plus gap
        let count = max(1, Int(size.width / pitch))
        let levels = Self.resample(deck.waveform, to: count)
        let maxHeight = size.height - 16
        var bars = Path()
        for index in 0..<count {
            let level = levels.isEmpty ? 0 : CGFloat(levels[index])
            let height = max(1, level * maxHeight)
            bars.addRoundedRect(in: CGRect(x: CGFloat(index) * pitch, y: middle - height / 2, width: 2, height: height),
                                cornerSize: CGSize(width: 1, height: 1))
        }
        let playedX = size.width * progress
        var played = context
        played.clip(to: Path(CGRect(x: 0, y: 0, width: playedX, height: size.height)))
        played.fill(bars, with: .color(accent))
        var unplayed = context
        unplayed.clip(to: Path(CGRect(x: playedX, y: 0, width: size.width - playedX, height: size.height)))
        unplayed.fill(bars, with: .color(.secondary.opacity(0.45)))

        // Cue point: a small flag on the top edge.
        let cueX = size.width * cue
        var flag = Path()
        flag.move(to: CGPoint(x: cueX - 4, y: 0))
        flag.addLine(to: CGPoint(x: cueX + 4, y: 0))
        flag.addLine(to: CGPoint(x: cueX, y: 5))
        flag.closeSubpath()
        context.fill(flag, with: .color(Palette.ochre))

        context.fill(Path(CGRect(x: playedX - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.primary))
    }

    /// Averages (or repeats) the overview to one value per drawn bar.
    private static func resample(_ levels: [Float], to count: Int) -> [Float] {
        guard !levels.isEmpty else { return [] }
        return (0..<count).map { index in
            let start = index * levels.count / count
            let end = max(start + 1, (index + 1) * levels.count / count)
            let slice = levels[start..<min(end, levels.count)]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }
}

/// Speeds the deck up or slows it down while held, for pulling the beats into line.
private struct NudgeButton: View {
    let deck: Deck
    let direction: Double
    @State private var isPressed = false

    var body: some View {
        Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isPressed ? Palette.warm : .secondary)
            .frame(width: 14, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        deck.setNudge(direction * Deck.nudgeAmount)
                    }
                    .onEnded { _ in
                        isPressed = false
                        deck.setNudge(0)
                    }
            )
            .help(direction < 0 ? "Hold to slow down" : "Hold to speed up")
            .accessibilityLabel(direction < 0 ? "Nudge slower" : "Nudge faster")
    }
}

// MARK: - Mixer section

private struct MixerSection: View {
    @Bindable var mixer: Mixer

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 0) {
                ChannelStrip(deck: mixer.a, accent: Palette.warm, knobsLeading: true)
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    Knob(label: "Master volume", value: $mixer.masterVolume, range: 0...1, defaultValue: 0.8, accent: Palette.warm, size: 28)
                    StripLabel("Master")
                    if let error = mixer.errorMessage {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Palette.error).help(error)
                    }
                }
                .frame(maxHeight: .infinity)
                Spacer(minLength: 0)
                ChannelStrip(deck: mixer.b, accent: Palette.cool, knobsLeading: false)
            }
            HStack(spacing: 8) {
                Text("A").font(.caption.weight(.bold)).foregroundStyle(Palette.warm)
                Crossfader(position: mixer.crossfader) { mixer.moveCrossfader(to: $0) }
                    .onScrollWheel { mixer.moveCrossfader(to: mixer.crossfader + $0 / 300) }
                Text("B").font(.caption.weight(.bold)).foregroundStyle(Palette.cool)
                Menu {
                    Picker("Crossfade Length", selection: $mixer.autoFadeSeconds) {
                        ForEach(Mixer.autoFadeChoices, id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: mixer.isAutoFading ? "stop.fill" : "arrow.left.arrow.right")
                        .foregroundStyle(mixer.isAutoFading ? Palette.warm : .secondary)
                } primaryAction: {
                    mixer.isAutoFading ? mixer.cancelAutoFade() : mixer.autoFade()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(mixer.isAutoFading ? "Stop crossfade" : "Crossfade to the other side over \(Int(mixer.autoFadeSeconds)) s (hold for length)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// EQ knobs beside a channel fader; deck B's mirrors deck A's so the faders sit together.
private struct ChannelStrip: View {
    @Bindable var deck: Deck
    let accent: Color
    let knobsLeading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if knobsLeading { knobs; fader } else { fader; knobs }
        }
    }

    private var knobs: some View {
        VStack(spacing: 1) {
            Knob(label: "Deck \(deck.side.name) high", value: $deck.high, range: -1...1, defaultValue: 0, accent: accent)
            StripLabel("Hi")
            Knob(label: "Deck \(deck.side.name) mid", value: $deck.mid, range: -1...1, defaultValue: 0, accent: accent)
            StripLabel("Mid")
            Knob(label: "Deck \(deck.side.name) low", value: $deck.low, range: -1...1, defaultValue: 0, accent: accent)
            StripLabel("Low")
        }
    }

    /// A rotated system slider, like the Equalizer's bands.
    private var fader: some View {
        Slider(value: $deck.level, in: 0...1)
            .accessibilityLabel("Deck \(deck.side.name) level")
            .controlSize(.small)
            .frame(width: 104)
            .rotationEffect(.degrees(-90))
            .frame(width: 20, height: 104)
            .padding(.top, 4)
            .onTapGesture(count: 2) { deck.level = 1 }
            .onScrollWheel { deck.level = min(max(deck.level + Float($0 / 150), 0), 1) }
            .help("Deck \(deck.side.name) level — double-click to reset")
    }
}

private struct StripLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.secondary)
    }
}

/// A rotary control: drag up or down to turn, double-click to reset. Drawn like a system slider
/// knob, with an arc from the resting position to the value.
private struct Knob: View {
    /// What VoiceOver calls it ("Deck A high").
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    let accent: Color
    var size: CGFloat = 20
    @State private var dragStart: Float?

    private static let sweep = 0.75  // of a full turn

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let fraction = Double((value - range.lowerBound) / span)
        let origin = Double((defaultValue - range.lowerBound) / span)
        ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(.tertiary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: min(fraction, origin) * Self.sweep, to: max(fraction, origin) * Self.sweep)
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(135))
            KnobCap()
                .padding(4.5)
            Capsule()
                .fill(.secondary)
                .frame(width: 1.5, height: size * 0.22)
                .offset(y: -size * 0.17)
                .rotationEffect(.degrees(-135 + fraction * 270))
        }
        .frame(width: size, height: size)
        .padding(2)
        .contentShape(Circle())
        .onScrollWheel { value = min(max(value + Float($0 / 150) * span, range.lowerBound), range.upperBound) }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? value
                    dragStart = start
                    let turned = Float(-drag.translation.height / 140) * span
                    value = min(max(start + turned, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { value = defaultValue })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(String(format: "%.0f%%", fraction * 100))
        .accessibilityAdjustableAction { direction in
            let step = span / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// The round cap of a knob, in the system slider knob's colours.
private struct KnobCap: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // Light mode needs a firmer edge: a white cap on the light bar otherwise disappears.
        Circle()
            .fill(colorScheme == .dark ? Color(white: 0.8) : .white)
            .overlay(Circle().strokeBorder(.black.opacity(colorScheme == .dark ? 0.1 : 0.2), lineWidth: 0.5))
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.3), radius: 1.5, y: 1)
    }
}

/// The crossfader: a system-style slider track with a centre mark and a soft detent there, and
/// no fill (neither side is "more").
private struct Crossfader: View {
    let position: Double
    let set: (Double) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private static let capWidth: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let travel = geometry.size.width - Self.capWidth
            let middle = geometry.size.height / 2
            ZStack {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 4)
                    .position(x: geometry.size.width / 2, y: middle)
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 1, height: 10)
                    .position(x: geometry.size.width / 2, y: middle)
                Capsule()
                    .fill(colorScheme == .dark ? Color(white: 0.8) : .white)
                    .overlay(Capsule().fill(.secondary).frame(width: 1.5, height: 8))
                    .overlay(Capsule().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: Self.capWidth, height: 14)
                    .position(x: Self.capWidth / 2 + travel * position, y: middle)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard travel > 0 else { return }
                        var target = (drag.location.x - Self.capWidth / 2) / travel
                        if abs(target - 0.5) < 0.025 { target = 0.5 }  // detent
                        set(min(max(target, 0), 1))
                    }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Crossfader")
        .accessibilityValue(String(format: "%.0f%% deck B", position * 100))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(min(position + 0.05, 1))
            case .decrement: set(max(position - 0.05, 0))
            @unknown default: break
            }
        }
    }
}
