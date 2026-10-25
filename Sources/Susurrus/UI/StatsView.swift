import Charts
import SwiftUI

/// Listening stats: totals, top artists/albums/tracks, when you listen, a year of days, and the
/// tracks you skip most.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("stats.range") private var range: ListeningStats.Range = .month
    @State private var stats: ListeningStats?

    private struct LoadKey: Equatable {
        var range: ListeningStats.Range
        var revision: Int
    }

    var body: some View {
        Group {
            if let stats {
                if stats.isEmpty {
                    ContentUnavailableView("Nothing Played", systemImage: "chart.bar",
                                           description: Text("Nothing was played in this period."))
                } else {
                    content(stats)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Picker("Period", selection: $range) {
                    ForEach(ListeningStats.Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Which period the stats cover (the calendar always shows the last year)")
            }
        }
        .task(id: LoadKey(range: range, revision: model.statsRevision)) {
            let computed = await model.listeningStats(for: range)
            if !Task.isCancelled { stats = computed }
        }
    }

    private func content(_ stats: ListeningStats) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                totals(stats)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 24, alignment: .top)], alignment: .leading, spacing: 24) {
                    TopList(title: "Top Artists", entries: stats.topArtists, kind: .artist)
                    TopList(title: "Top Albums", entries: stats.topAlbums, kind: .album)
                    TopList(title: "Top Tracks", entries: stats.topTracks, kind: .track)
                }

                HStack(alignment: .top, spacing: 24) {
                    section("Time of Day") { HourChart(hourly: stats.hourly) }
                    section("Day of Week") { WeekdayChart(averages: stats.weekdayAverages) }
                }

                section("Last 12 Months") {
                    ListeningCalendar(days: stats.days, start: stats.calendarStart)
                }

                if !stats.mostSkipped.isEmpty {
                    TopList(title: "Most Skipped", entries: stats.mostSkipped, kind: .skipped)
                        .frame(maxWidth: 420, alignment: .leading)
                }

                if let estimatedBefore = stats.estimatedBefore {
                    Text("Listening time before \(estimatedBefore.formatted(date: .abbreviated, time: .omitted)) is estimated from track lengths: susurrus only kept a play count until then. Imported plays only include each track's last play.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private func totals(_ stats: ListeningStats) -> some View {
        HStack(spacing: 12) {
            Tile(value: StatsFormat.duration(stats.totalSeconds), label: "Listening time")
            Tile(value: stats.plays.formatted(), label: stats.plays == 1 ? "Play" : "Plays")
            Tile(value: stats.distinctTracks.formatted(), label: "Different tracks")
            Tile(value: stats.skips.formatted(), label: stats.skips == 1 ? "Skip" : "Skips")
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum StatsFormat {
    /// "3 h 20 min", "45 min", "12 s".
    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return "\(Int(seconds)) s" }
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 86_400 * 2 ? [.days, .hours] : [.hours, .minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated, maximumUnitCount: 2))
    }
}

private struct Tile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 130, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Top lists

private struct TopList: View {
    enum Kind { case artist, album, track, skipped }

    @Environment(AppModel.self) private var model
    let title: String
    let entries: [ListeningStats.Entry]
    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            let longest = entries.map { kind == .skipped ? Double($0.skips) : $0.seconds }.max() ?? 1
            ForEach(Array(entries.enumerated()), id: \.element.id) { rank, entry in
                row(rank: rank + 1, entry: entry, fraction: (kind == .skipped ? Double(entry.skips) : entry.seconds) / max(longest, 1))
            }
        }
    }

    private func row(rank: Int, entry: ListeningStats.Entry, fraction: Double) -> some View {
        let track = model.tracksByID[entry.trackID]
        return HStack(spacing: 10) {
            Text("\(rank)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            if kind != .artist {
                ArtworkView(request: track?.artworkRequest, pixelSize: 80, cornerRadius: 3)
                    .frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title).lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                GeometryReader { geometry in
                    Capsule()
                        .fill(kind == .skipped ? Palette.ochre : Palette.warm)
                        .frame(width: max(3, geometry.size.width * fraction), height: 3)
                }
                .frame(height: 3)
            }
            Spacer(minLength: 4)
            Text(detail(entry))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { play(entry) }
        .simultaneousGesture(TapGesture().onEnded { if kind == .artist { model.showArtist(entry.title) } })
        .contextMenu {
            switch kind {
            case .artist:
                Button("Play Artist") { play(entry) }
                if let track { Button("Go to Artist") { model.showArtist(artistName(entry, track)) } }
            case .album:
                if let track, let album = model.albums(of: [track]).first {
                    MenuEntries(entries: TrackMenu.entries(for: album, model: model, leading: [
                        .action("Show in Library") { model.reveal(track) }, .separator,
                    ]))
                } else {
                    Button("Play Album") { play(entry) }
                }
            default:
                if let track {
                    MenuEntries(entries: [.action("Show in Library") { model.reveal(track) }, .separator]
                        + TrackMenu.entries(for: [track], model: model) { play(entry) })
                }
            }
        }
        .help(kind == .artist ? "Click to open the artist's page, double-click to play" : "Double-click to play")
    }

    /// The artist's own name: an album's artist unless it's a compilation, else the track's.
    private func artistName(_ entry: ListeningStats.Entry, _ track: Track) -> String {
        switch kind {
        case .artist: entry.title
        case .album where !track.compilation && !track.albumGroupArtist.isEmpty: track.albumGroupArtist
        default: track.displayArtist
        }
    }

    private func detail(_ entry: ListeningStats.Entry) -> String {
        if kind == .skipped {
            return entry.skips == 1 ? "1 skip" : "\(entry.skips) skips"
        }
        let plays = entry.plays == 1 ? "1 play" : "\(entry.plays) plays"
        return "\(StatsFormat.duration(entry.seconds))\n\(plays)"
    }

    private func play(_ entry: ListeningStats.Entry) {
        guard let track = model.tracksByID[entry.trackID] else { return }
        switch kind {
        case .artist:
            if let artist = model.artists.artist(named: entry.title) { model.playArtist(artist) }
        case .album:
            let tracks = model.albumTracks(albumOf: track)
            model.player.play(tracks, startingAt: 0)
        case .track, .skipped:
            model.player.play([track], startingAt: 0)
        }
    }
}

// MARK: - Charts

private struct HourChart: View {
    let hourly: [Double]

    var body: some View {
        Chart(Array(hourly.enumerated()), id: \.offset) { hour, seconds in
            BarMark(x: .value("Hour", hour), y: .value("Minutes", seconds / 60))
                .foregroundStyle(Palette.cool)
                .cornerRadius(2)
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 3, 6, 9, 12, 15, 18, 21]) { value in
                AxisGridLine()
                AxisValueLabel { if let hour = value.as(Int.self) { Text(hourLabel(hour)) } }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let minutes = value.as(Double.self) { Text(StatsFormat.duration(minutes * 60)) } }
            }
        }
        .frame(height: 170)
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

private struct WeekdayChart: View {
    let averages: [Double]

    private var ordered: [(name: String, seconds: Double)] {
        let calendar = Calendar.current
        let symbols = calendar.shortWeekdaySymbols
        return (0..<7).map { offset in
            let index = (calendar.firstWeekday - 1 + offset) % 7
            return (symbols[index], averages[index])
        }
    }

    var body: some View {
        Chart(ordered, id: \.name) { day in
            BarMark(x: .value("Day", day.name), y: .value("Minutes", day.seconds / 60))
                .foregroundStyle(Palette.warm)
                .cornerRadius(2)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let minutes = value.as(Double.self) { Text(StatsFormat.duration(minutes * 60)) } }
            }
        }
        .frame(height: 170)
        .help("Average listening time per day")
    }
}

// MARK: - Calendar

/// A year of days, one square each, darker for more listening (like GitHub's contribution graph).
private struct ListeningCalendar: View {
    let days: [Date: Double]
    let start: Date

    private let cell: CGFloat = 11
    private let gap: CGFloat = 3

    private var weeks: [[Date]] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [[Date]] = []
        var day = start
        while day <= today {
            if result.isEmpty || result[result.count - 1].count == 7 { result.append([]) }
            result[result.count - 1].append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }

    /// Thresholds splitting the days with any listening into four equal-sized groups.
    private var levels: [Double] {
        let values = days.values.filter { $0 > 0 }.sorted()
        guard !values.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { values[min(values.count - 1, Int(Double(values.count) * $0))] }
    }

    var body: some View {
        let weeks = weeks
        let levels = levels
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { index, week in
                    Text(monthLabel(week, isFirst: index == 0))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .frame(width: cell, alignment: .leading)
                }
            }
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(week, id: \.self) { day in
                            let seconds = days[day] ?? 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(color(seconds, levels: levels))
                                .frame(width: cell, height: cell)
                                .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(seconds > 0 ? StatsFormat.duration(seconds) : "nothing")")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach(0..<5) { level in
                    RoundedRectangle(cornerRadius: 2).fill(color(forLevel: level)).frame(width: cell, height: cell)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    /// The month's short name over the first week that starts in it.
    private func monthLabel(_ week: [Date], isFirst: Bool) -> String {
        guard let first = week.first else { return "" }
        let calendar = Calendar.current
        let day = calendar.component(.day, from: first)
        guard day <= 7, !isFirst || day == 1 else { return "" }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    private func color(_ seconds: Double, levels: [Double]) -> Color {
        guard seconds > 0 else { return color(forLevel: 0) }
        return color(forLevel: 1 + levels.filter { seconds > $0 }.count)
    }

    private func color(forLevel level: Int) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : Palette.warm.opacity([0.3, 0.5, 0.75, 1][level - 1])
    }
}
