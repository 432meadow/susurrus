import SwiftUI

/// Look Up Album: pick the MusicBrainz release a set of tracks is, see what would change, and
/// apply tags and the cover.
struct ReleaseLookupView: View {
    @Environment(AppModel.self) private var model
    @Bindable var lookup: ReleaseLookup
    private enum SearchField { case artist, album }
    /// While the artist or album is being typed, Return searches again instead of applying.
    @FocusState private var searchField: SearchField?
    private var isEditingSearch: Bool { searchField != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchBar
            HSplitView {
                releaseList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                details
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
            .frame(minHeight: 220)
            options
            HStack {
                Text(writeNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel") {
                    lookup.cancel()
                    model.releaseLookup = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Apply") { model.applyLookup(lookup) }
                    .keyboardShortcut(isEditingSearch ? nil : .defaultAction)
                    .disabled(lookup.selected == nil || (lookup.fields.isEmpty && !coverWillApply && !lookup.organizes))
            }
        }
        .padding(16)
        // Fits a small main window (sheets can't be taller than it); grows when there's room.
        .frame(minWidth: 760, idealWidth: 860, minHeight: 420, idealHeight: 620)
    }

    // MARK: Search

    private var searchBar: some View {
        HStack {
            TextField("Artist", text: $lookup.artist)
                .frame(maxWidth: 200)
                .focused($searchField, equals: .artist)
            TextField("Album", text: $lookup.album)
                .focused($searchField, equals: .album)
            Button("Search", action: searchAgain)
                .keyboardShortcut(isEditingSearch ? .defaultAction : nil)
                .disabled(lookup.album.trimmingCharacters(in: .whitespaces).isEmpty)
            Divider().frame(height: 18)
            TextField("MusicBrainz release link", text: $lookup.releaseLink)
                .frame(maxWidth: 220)
                .onSubmit { lookup.useLink() }
            Button("Use") { lookup.useLink() }
                .disabled(lookup.releaseLink.isEmpty)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func searchAgain() {
        guard !lookup.album.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        lookup.search()
    }

    private var releaseList: some View {
        Group {
            switch lookup.phase {
            case .searching where lookup.matches.isEmpty:
                ProgressView("Asking MusicBrainz…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where lookup.matches.isEmpty:
                ContentUnavailableView("No Match", systemImage: "questionmark.circle", description: Text(message))
            default:
                List(lookup.matches, selection: $lookup.selectedID) { match in
                    ReleaseRow(match: match).tag(match.id)
                }
                .overlay(alignment: .bottom) {
                    if case .failed(let message) = lookup.phase {
                        Text(message).font(.caption).foregroundStyle(Palette.error).padding(6)
                    } else if lookup.phase == .searching {
                        ProgressView().controlSize(.small).padding(6)
                    }
                }
            }
        }
    }

    // MARK: Details

    @ViewBuilder private var details: some View {
        if let match = lookup.selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    cover
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.release.title).font(.title3.weight(.semibold))
                        Text(match.release.artist).foregroundStyle(.secondary)
                        Text(match.release.summary).font(.caption).foregroundStyle(.secondary)
                        Link("Open on MusicBrainz", destination: match.release.url).font(.caption)
                        Text(matchSummary(match))
                            .font(.caption)
                            .foregroundStyle(match.isConfident ? Palette.success : Palette.ochre)
                    }
                    Spacer(minLength: 0)
                }
                trackTable(match)
            }
            .padding(.leading, 12)
        } else {
            Color.clear
        }
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let data = lookup.cover, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if lookup.isLoadingCover {
                ProgressView().controlSize(.small)
            } else {
                Text("No cover").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private struct Row: Identifiable {
        let id: Int64
        let current: String
        let proposed: String
        let number: String
        /// Disc and position, for sorting.
        let order: [Int]
        let lengthNote: String
        let isGood: Bool
    }

    private func rows(_ match: ReleaseMatcher.Match) -> [Row] {
        lookup.inputs.map { input in
            let pair = match.pairs[input.id]
            let current = input.title.isEmpty ? input.fileName : input.title
            guard let pair else {
                return Row(id: input.id, current: current, proposed: "Not on this release", number: "–", order: [Int.max],
                           lengthNote: "", isGood: false)
            }
            let slot = pair.slot
            let number = slot.discCount > 1 ? "\(slot.disc)-\(slot.position)" : "\(slot.position)"
            let note = pair.lengthDifference.map { $0 < 1 ? "✓" : String(format: "%+.0f s", (slot.length ?? 0) - input.length) } ?? "?"
            return Row(id: input.id, current: current, proposed: slot.title, number: number, order: [slot.disc, slot.position],
                       lengthNote: note, isGood: (pair.lengthDifference ?? 99) <= 5)
        }
        // Disc, then position, as numbers ("1-10" after "1-9", "2-1" after both); unmatched files last.
        .sorted { $0.order.lexicographicallyPrecedes($1.order) }
    }

    private func trackTable(_ match: ReleaseMatcher.Match) -> some View {
        Table(rows(match)) {
            TableColumn("#") { Text($0.number).monospacedDigit() }
                .width(36)
            TableColumn("File") { Text($0.current).foregroundStyle(.secondary) }
            TableColumn("On the Release") { row in
                Text(row.proposed).foregroundStyle(row.number == "–" ? Palette.ochre : .primary)
            }
            TableColumn("Length") { row in
                Text(row.lengthNote).monospacedDigit().foregroundStyle(row.isGood ? Color.secondary : Palette.ochre)
            }
            .width(56)
        }
    }

    private func matchSummary(_ match: ReleaseMatcher.Match) -> String {
        let unmatched = match.inputCount - match.pairs.count
        var parts = ["\(match.pairs.count) of \(match.inputCount) files matched"]
        if match.slotCount > match.pairs.count { parts.append("\(match.slotCount - match.pairs.count) release tracks missing") }
        if unmatched == 0, match.isConfident { parts.append("lengths agree") }
        return parts.joined(separator: " · ")
    }

    // MARK: Options

    private var options: some View {
        HStack(spacing: 16) {
            Text("Apply:").foregroundStyle(.secondary)
            field("Titles", .titles)
            field("Artists", .artists)
            field("Album & Year", .album)
            field("Track & Disc Numbers", .numbers)
            Toggle("Cover", isOn: $lookup.includesCover)
                .disabled(lookup.cover == nil)
            if lookup.organizeRoot != nil {
                Toggle("Move into Artist/Album (Year)", isOn: $lookup.organizes)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func field(_ title: String, _ field: ReleaseMatcher.Fields) -> some View {
        Toggle(title, isOn: Binding(
            get: { lookup.fields.contains(field) },
            set: { if $0 { lookup.fields.insert(field) } else { lookup.fields.remove(field) } }
        ))
    }

    private var coverWillApply: Bool { lookup.includesCover && lookup.cover != nil }

    private var writeNote: String {
        if lookup.organizeRoot != nil {
            return "Downloaded files get the new tags and cover written into them."
        }
        return model.writesTagsToFiles
            ? "Tags and cover are saved in susurrus and written into the files."
            : "Tags and cover are saved in susurrus only (Settings ▸ Library ▸ Write tags to files is off)."
    }
}

private struct ReleaseRow: View {
    let match: ReleaseMatcher.Match

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(match.release.title).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                if match.isConfident {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Palette.success).help("Every file matches a track, lengths agree")
                } else {
                    Text("\(Int((match.score * 100).rounded()))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(match.release.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(match.release.summary).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}
