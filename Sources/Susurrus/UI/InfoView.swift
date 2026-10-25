import SwiftUI

/// Get Info: edit tags for one or many tracks. With several tracks, fields that differ start
/// empty ("Mixed") and only the fields you change are saved; a Mixed field you empty is cleared.
struct InfoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]

    private enum Field: String, CaseIterable {
        case title = "Title", artist = "Artist", album = "Album", albumArtist = "Album Artist"
        case genre = "Genre", composer = "Composer", grouping = "Grouping"
        case year = "Year", trackNumber = "Track", trackCount = "of Tracks"
        case discNumber = "Disc", discCount = "of Discs", bpm = "BPM", key = "Key", comment = "Comment"

        var isNumeric: Bool {
            switch self {
            case .year, .trackNumber, .trackCount, .discNumber, .discCount, .bpm: true
            default: false
            }
        }

        func value(of track: Track) -> String {
            func number(_ n: Int) -> String { n > 0 ? String(n) : "" }
            return switch self {
            case .title: track.title
            case .artist: track.artist
            case .album: track.album
            case .albumArtist: track.albumArtist
            case .genre: track.genre
            case .composer: track.composer
            case .grouping: track.grouping
            case .comment: track.comment
            case .year: number(track.year)
            case .trackNumber: number(track.trackNumber)
            case .trackCount: number(track.totalNumberOfTracks)
            case .discNumber: number(track.discNumber)
            case .discCount: number(track.totalNumberOfDiscs)
            case .bpm: number(track.bpm)
            case .key: track.musicalKey
            }
        }
    }

    @State private var values: [Field: String] = [:]
    @State private var original: [Field: String] = [:]
    @State private var mixed: Set<Field> = []
    @State private var edited: Set<Field> = []
    @State private var compilation: Bool?
    @State private var rating: Double = 0
    /// Only a rating that was clicked is saved: with mixed ratings the stars start empty.
    @State private var isRatingEdited = false
    @State private var isRatingMixed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Scrolls when the window is short, so Save/Cancel stay reachable.
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
            Form {
                ForEach([Field.title, .artist, .album, .albumArtist, .genre, .composer, .grouping], id: \.self) { field in
                    textField(field)
                }
                HStack {
                    textField(.year).frame(width: 140)
                    textField(.bpm).frame(width: 120)
                    textField(.key).frame(width: 110)
                        .help("Standard (Am, F#) or Camelot (8A) notation")
                }
                HStack {
                    textField(.trackNumber).frame(width: 140)
                    textField(.trackCount).frame(width: 140)
                }
                HStack {
                    textField(.discNumber).frame(width: 140)
                    textField(.discCount).frame(width: 140)
                }
                textField(.comment)
                Toggle("Part of a compilation", isOn: Binding(
                    get: { compilation ?? false },
                    set: { compilation = $0 }))
                LabeledContent("Rating") {
                    HStack(spacing: 8) {
                        StarRatingPicker(rating: Binding(get: { rating }, set: { rating = $0; isRatingEdited = true }))
                        if isRatingMixed, !isRatingEdited {
                            Text("Mixed").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.columns)

            if tracks.count == 1 { fileDetails(tracks[0]) }

            Text(model.writesTagsToFiles
                 ? "Changes are saved to the susurrus library and then written into the audio files in the background."
                 : "Changes are saved to the susurrus library; the audio files themselves are not modified (see Settings ▸ Library).")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.trailing, 8)
            }
            .frame(minHeight: 200, idealHeight: 520)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var header: some View {
        HStack(spacing: 14) {
            ArtworkView(request: tracks[0].artworkRequest, pixelSize: 200, cornerRadius: 6)
                .frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 3) {
                Text(tracks.count == 1 ? tracks[0].displayTitle : "\(tracks.count) tracks")
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                if tracks.count == 1 {
                    Text(tracks[0].artistAndAlbum)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func textField(_ field: Field) -> some View {
        TextField(field.rawValue, text: Binding(
            get: { values[field] ?? "" },
            set: {
                // SwiftUI also writes the text back unchanged (when the field loses focus): that's
                // no edit, and counting it would clear a Mixed field on every track.
                guard $0 != (values[field] ?? "") else { return }
                values[field] = $0
                edited.insert(field)
            }),
            prompt: Text(mixed.contains(field) ? "Mixed" : ""))
    }

    private func fileDetails(_ track: Track) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Kind", "\(track.fileType) · \(track.bitRate) kbps · \(track.sampleRate) Hz\(track.bitDepth > 0 ? " · \(track.bitDepth)-bit" : "")")
            row("Length", Format.time(track.length))
            row("Size", ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
            row("Plays", "\(track.playCount)" + (track.lastPlayed.map { ", last \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
            row("Added", track.dateAdded?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            row("File", track.path)
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }

    private func load() {
        for field in Field.allCases {
            let distinct = Set(tracks.map { field.value(of: $0) })
            let value = distinct.count == 1 ? distinct.first! : ""
            if distinct.count > 1 { mixed.insert(field) }
            values[field] = value
            original[field] = value
        }
        let compilations = Set(tracks.map(\.compilation))
        compilation = compilations.count == 1 ? compilations.first : nil
        let ratings = Set(tracks.map(\.rating))
        rating = ratings.count == 1 ? ratings.first! : 0
        isRatingMixed = ratings.count > 1
    }

    private func save() {
        var edit = TrackEdit()
        // A Mixed field starts out empty, so emptying it (to clear it on every track) counts as a change.
        for field in Field.allCases where edited.contains(field) && (values[field] != original[field] || mixed.contains(field)) {
            let text = (values[field] ?? "").trimmingCharacters(in: .whitespaces)
            if field.isNumeric {
                // A BPM may be typed with decimals; anything that isn't a number leaves the field alone.
                let parsed = field == .bpm ? Double(text).map { Int($0.rounded()) } : Int(text)
                guard let number = text.isEmpty ? 0 : parsed else { continue }
                switch field {
                case .year: edit.year = number
                case .trackNumber: edit.trackNumber = number
                case .trackCount: edit.trackCount = number
                case .discNumber: edit.discNumber = number
                case .discCount: edit.discCount = number
                case .bpm: edit.bpm = number
                default: break
                }
            } else {
                switch field {
                case .title: edit.title = text
                case .artist: edit.artist = text
                case .album: edit.album = text
                case .albumArtist: edit.albumArtist = text
                case .genre: edit.genre = text
                case .composer: edit.composer = text
                case .grouping: edit.grouping = text
                case .comment: edit.comment = text
                case .key: edit.musicalKey = MusicalKey(parsing: text)?.name ?? text
                default: break
                }
            }
        }
        let originalCompilations = Set(tracks.map(\.compilation))
        if let compilation, originalCompilations != [compilation] { edit.compilation = compilation }
        if isRatingEdited, Set(tracks.map(\.rating)) != [rating] { edit.rating = rating }
        model.update(edit, for: tracks)
    }
}

/// Five clickable stars; click a star's left half for a half star, click the current value to clear.
struct StarRatingPicker: View {
    @Binding var rating: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                let value = rating - Double(star - 1)
                Image(systemName: value >= 1 ? "star.fill" : value >= 0.5 ? "star.leadinghalf.filled" : "star")
                    .foregroundStyle(rating > 0 ? Palette.warm : .secondary)
                    .overlay {
                        HStack(spacing: 0) {
                            Color.clear.contentShape(Rectangle()).onTapGesture { set(Double(star) - 0.5) }
                            Color.clear.contentShape(Rectangle()).onTapGesture { set(Double(star)) }
                        }
                    }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating.formatted()) stars")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: rating = min(5, rating + 0.5)
            case .decrement: rating = max(0, rating - 0.5)
            @unknown default: break
            }
        }
    }

    private func set(_ value: Double) {
        rating = rating == value ? 0 : value
    }
}
