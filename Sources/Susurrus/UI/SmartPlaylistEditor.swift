import AppKit
import SwiftUI

/// A smart playlist being created (`playlistID == nil`) or edited.
struct SmartPlaylistDraft: Identifiable {
    var playlistID: Int64?
    var name: String
    var predicate: NSPredicate
    var id: String { playlistID.map(String.init) ?? "new" }

    static func new() -> SmartPlaylistDraft {
        SmartPlaylistDraft(
            name: "Untitled Smart Playlist",
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "genre CONTAINS[cd] %@", ""),
            ]))
    }
}

struct SmartPlaylistEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: SmartPlaylistDraft
    @State private var matchCount: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.playlistID == nil ? "New Smart Playlist" : "Edit Smart Playlist").font(.headline)
            TextField("Name", text: $draft.name)
            PredicateEditor(predicate: $draft.predicate)
                .frame(minHeight: 180)
            HStack {
                if let error {
                    Text(error).foregroundStyle(Palette.error).font(.caption)
                } else if let matchCount {
                    Text("\(matchCount.formatted()) matching tracks").foregroundStyle(.secondary).font(.caption)
                } else {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.playlistID == nil ? "Create" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || error != nil)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task(id: draft.predicate.predicateFormat) { await countMatches() }
    }

    private func countMatches() async {
        matchCount = nil
        error = nil
        try? await Task.sleep(for: .milliseconds(250))  // debounce while editing
        guard !Task.isCancelled else { return }
        let predicate = draft.predicate
        let tracks = model.detachedTracks()
        let result = await Task.detached(priority: .userInitiated) {
            Result { try SmartPredicate.evaluate(predicate, on: tracks).count }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let count): matchCount = count
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        if let id = draft.playlistID {
            model.updateSmartPlaylist(id, name: name, predicate: draft.predicate)
        } else {
            model.createSmartPlaylist(named: name, predicate: draft.predicate)
        }
    }
}

/// NSPredicateEditor with rows for the Track properties smart playlists use.
private struct PredicateEditor: NSViewRepresentable {
    @Binding var predicate: NSPredicate

    static let textKeys: [(String, String)] = [
        ("title", "Title"), ("artist", "Artist"), ("album", "Album"), ("albumArtist", "Album Artist"),
        ("genre", "Genre"), ("composer", "Composer"), ("grouping", "Grouping"), ("comment", "Comment"),
        ("fileType", "Kind"), ("path", "Location"),
    ]
    static let numberKeys: [(String, String)] = [
        ("rating", "Rating"), ("playCount", "Plays"), ("year", "Year"), ("bpm", "BPM"),
        ("bitRate", "Bit Rate"), ("sampleRate", "Sample Rate"), ("length", "Time (seconds)"),
        ("trackNumber", "Track Number"), ("discNumber", "Disc Number"),
    ]
    static let dateKeys: [(String, String)] = [
        ("dateAdded", "Date Added"), ("lastPlayed", "Last Played"), ("dateModified", "Date Modified"),
    ]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = NSPredicateEditor()
        editor.rowTemplates = Self.templates()
        editor.canRemoveAllRows = false
        editor.target = context.coordinator
        editor.action = #selector(Coordinator.changed(_:))
        editor.objectValue = Self.normalized(predicate)
        if editor.numberOfRows == 0 {
            editor.objectValue = SmartPlaylistDraft.new().predicate
        }

        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.autoresizingMask = [.width]
        editor.frame.size.width = scroll.contentSize.width
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
    }

    /// The editor only shows compound predicates at the top level.
    private static func normalized(_ predicate: NSPredicate) -> NSPredicate {
        predicate is NSCompoundPredicate ? predicate : NSCompoundPredicate(andPredicateWithSubpredicates: [predicate])
    }

    private static func templates() -> [NSPredicateEditorRowTemplate] {
        func expressions(_ keys: [(String, String)]) -> [NSExpression] { keys.map { NSExpression(forKeyPath: $0.0) } }
        func ops(_ operators: [NSComparisonPredicate.Operator]) -> [NSNumber] { operators.map { NSNumber(value: $0.rawValue) } }

        let text = NSPredicateEditorRowTemplate(
            leftExpressions: expressions(textKeys),
            rightExpressionAttributeType: .stringAttributeType,
            modifier: .direct,
            operators: ops([.contains, .beginsWith, .endsWith, .equalTo, .notEqualTo, .like]),
            options: Int(NSComparisonPredicate.Options.caseInsensitive.rawValue | NSComparisonPredicate.Options.diacriticInsensitive.rawValue))
        let number = NSPredicateEditorRowTemplate(
            leftExpressions: expressions(numberKeys),
            rightExpressionAttributeType: .doubleAttributeType,
            modifier: .direct,
            operators: ops([.equalTo, .notEqualTo, .greaterThan, .greaterThanOrEqualTo, .lessThan, .lessThanOrEqualTo]),
            options: 0)
        let date = NSPredicateEditorRowTemplate(
            leftExpressions: expressions(dateKeys),
            rightExpressionAttributeType: .dateAttributeType,
            modifier: .direct,
            operators: ops([.greaterThan, .lessThan]),
            options: 0)
        let flag = NSPredicateEditorRowTemplate(
            leftExpressions: [NSExpression(forKeyPath: "compilation")],
            rightExpressions: [NSExpression(forConstantValue: true), NSExpression(forConstantValue: false)],
            modifier: .direct,
            operators: [NSNumber(value: NSComparisonPredicate.Operator.equalTo.rawValue)],
            options: 0)
        let compound = NSPredicateEditorRowTemplate(compoundTypes: [
            NSNumber(value: NSCompoundPredicate.LogicalType.and.rawValue),
            NSNumber(value: NSCompoundPredicate.LogicalType.or.rawValue),
            NSNumber(value: NSCompoundPredicate.LogicalType.not.rawValue),
        ])

        // Show friendly names instead of key paths in the first popup of each row.
        let names = Dictionary(uniqueKeysWithValues: textKeys + numberKeys + dateKeys + [("compilation", "Compilation")])
        for template in [text, number, date, flag] {
            if let popup = template.templateViews.first as? NSPopUpButton {
                for item in popup.itemArray { item.title = names[item.title] ?? item.title }
            }
        }
        if let popup = flag.templateViews.last as? NSPopUpButton {
            for item in popup.itemArray { item.title = item.title == "1" ? "is on" : item.title == "0" ? "is off" : item.title }
        }
        return [compound, text, number, date, flag]
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PredicateEditor
        init(_ parent: PredicateEditor) { self.parent = parent }

        @objc func changed(_ sender: NSPredicateEditor) {
            if let predicate = sender.objectValue as? NSPredicate {
                parent.predicate = predicate
            }
        }
    }
}
