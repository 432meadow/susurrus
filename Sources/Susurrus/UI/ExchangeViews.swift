import SwiftUI
import UniformTypeIdentifiers

/// The Rekordbox export and Library.xml import sheets, and dropping playlists, library exports and
/// music on the window.
struct ExchangeSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var exchange = model.exchange
        content
            .sheet(item: $exchange.rekordboxDraft) { draft in
                RekordboxExportSheet(draft: draft)
            }
            .sheet(item: $exchange.libraryImport) { pending in
                LibraryImportSheet(pending: pending)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                model.handleWindowDrop(providers)
            }
    }
}

/// Whole library, or a choice of playlists (ticking a folder takes everything in it).
struct RekordboxExportSheet: View {
    @Environment(AppModel.self) private var model
    @State var draft: RekordboxExportDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export for Rekordbox").font(.headline)
            Picker("Export", selection: $draft.wholeLibrary) {
                Text("Whole library (\(model.tracks.count.formatted()) tracks and every playlist)").tag(true)
                Text("Chosen playlists and the tracks in them").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            List {
                OutlineGroup(model.playlists, children: \.children) { playlist in
                    Toggle(isOn: chosen(playlist.id)) {
                        Label(playlist.name, systemImage: playlist.systemImage)
                    }
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(minHeight: 220)
            .disabled(draft.wholeLibrary)
            .opacity(draft.wholeLibrary ? 0.5 : 1)

            Text("Tags, BPM, key, rating, play count and date added come from the library. Beat grids are included for the \(model.exchange.beatGrids.all.count.formatted()) tracks the mixer has analysed. Smart playlists are exported with their current tracks.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { model.exchange.rekordboxDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let chosen = draft.wholeLibrary ? nil : draft.chosen
                    model.exchange.rekordboxDraft = nil
                    // After the sheet has gone, so the save panel isn't stacked on it.
                    DispatchQueue.main.async { model.exportRekordboxXML(choosing: chosen) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.wholeLibrary && draft.chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chosen(_ id: Int64) -> Binding<Bool> {
        Binding(get: { draft.chosen.contains(id) },
                set: { if $0 { draft.chosen.insert(id) } else { draft.chosen.remove(id) } })
    }
}

/// What importing a Library.xml would change, before anything does.
struct LibraryImportSheet: View {
    @Environment(AppModel.self) private var model
    let pending: PendingLibraryImport
    @State private var addsFiles = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import “\(pending.fileName)”?").font(.headline)
            Text(AppModel.importSummary(of: pending.plan).joined(separator: "\n"))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !pending.plan.addablePaths.isEmpty {
                Toggle("Add the \(AppModel.count(pending.plan.addablePaths.count, "file", "files")) that aren't in the library (reads their tags)",
                       isOn: $addsFiles)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.exchange.libraryImport = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { model.confirmLibraryImport(addFiles: addsFiles) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
