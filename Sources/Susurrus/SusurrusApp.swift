import AppKit
import SwiftUI

@main
struct SusurrusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var updater: Updater

    init() {
        // Before the model or Sparkle touch any folder or setting: take over casting's.
        LegacyMigration.runAtLaunch()
        _model = State(initialValue: AppModel())
        _updater = State(initialValue: Updater())
    }

    var body: some Scene {
        WindowGroup("susurrus", id: "main") {
            ContentView()
                .environment(model)
                .tint(Palette.warm)
                .frame(minWidth: 900, minHeight: 500)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                if updater.isAvailable {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            CommandGroup(replacing: .newItem) {
                let selected = model.selectedTracks
                Button("New Playlist") { model.newPlaylist() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Playlist from Selection") { model.newPlaylist(with: selected) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(selected.isEmpty)
                Button("New Smart Playlist…") { model.smartPlaylistDraft = .new() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("New Playlist Folder") { model.newFolder() }
                Divider()
                Button("Add to Library…") { model.chooseFilesToAdd() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Import Playlist…") { model.chooseM3UToImport() }
                Button("Export Playlist…") { if let id = model.selectedPlaylistID { model.exportPlaylistAsM3U(id) } }
                    .disabled(model.selectedPlaylistID == nil)
                Button("Import from Apple Music…") { model.chooseLibraryXMLToImport() }
                    .disabled(model.exchange.status != nil)
                Button("Export Rekordbox XML…") { model.showRekordboxExport(choosing: model.selectedPlaylistID.map { [$0] } ?? [], wholeLibrary: true) }
                    .disabled(model.exchange.status != nil)
                Divider()
                Button(model.isCheckingForMissingFiles ? "Checking for Missing Files…" : "Check for Missing Files") {
                    model.checkForMissingFiles()
                }
                .disabled(model.isCheckingForMissingFiles)
                Button("Remove Missing Tracks from Library…") { model.confirmRemoveFromLibrary(model.missingTracks) }
                    .disabled(model.missingTrackCount == 0)
                Divider()
                if model.coverSearch == nil {
                    Button("Find Missing Covers for All Albums…") {
                        model.requestMissingCovers(for: Album.group(model.tracks, sortedBy: .artist))
                    }
                } else {
                    Button("Stop Finding Covers") { model.stopFindingCovers() }
                }
            }
            TrackCommands(model: model)
            ControlsCommands(model: model)
            MixerCommands(model: model)
            HelpCommands()
        }

        Window("Report a Bug", id: "bug-report") {
            BugReportView()
                .environment(model)
                .tint(Palette.warm)
        }
        .windowResizability(.contentSize)

        Window("Equalizer", id: "equalizer") {
            EqualizerView()
                .environment(model)
                .tint(Palette.warm)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
                .tint(Palette.warm)
        }

        MenuBarExtra("susurrus", systemImage: model.player.isPlaying ? "music.note" : "music.note.list") {
            MenuBarPlayer()
                .environment(model)
                .tint(Palette.warm)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct TrackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Track") {
            let selected = model.selectedTracks
            Button("Get Info") { model.showInfo(for: selected) }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(selected.isEmpty)
            Menu("Rating") {
                ForEach(0...5, id: \.self) { stars in
                    Button(stars == 0 ? "None" : String(repeating: "★", count: stars)) {
                        model.setRating(Double(stars), for: selected)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(stars))), modifiers: .command)
                }
            }
            .disabled(selected.isEmpty)
            Button(TrackMenu.detectBPMTitle(for: selected)) { model.detectBPM(for: selected) }
                .disabled(selected.isEmpty)
            if model.bpmAnalyzer.isRunning {
                Button("Stop Detecting BPM") { model.bpmAnalyzer.cancel() }
            }
            Button(TrackMenu.detectKeyTitle(for: selected)) { model.detectKey(for: selected) }
                .disabled(selected.isEmpty)
            if model.keyAnalyzer.isRunning {
                Button("Stop Detecting Keys") { model.keyAnalyzer.cancel() }
            }
            Button("Look Up Album on MusicBrainz…") { model.lookUpAlbum(for: selected) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(selected.isEmpty)
            Button("Find Missing Covers") { model.requestMissingCovers(for: model.albums(of: selected)) }
                .disabled(selected.isEmpty || model.coverSearch != nil)
            Divider()
            Button("Play Next") { model.playNext(selected) }
                .keyboardShortcut(.return, modifiers: .option)
                .disabled(selected.isEmpty)
            Button("Add to Queue") { model.addToQueue(selected) }
                .keyboardShortcut(.return, modifiers: [.option, .shift])
                .disabled(selected.isEmpty)
            Button("Load on Deck A") { if let track = selected.first { model.load(track, on: .a) } }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(selected.isEmpty)
            Button("Load on Deck B") { if let track = selected.first { model.load(track, on: .b) } }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(selected.isEmpty)
            Divider()
            Button("Remove from Playlist") { model.removeFromCurrentPlaylist(selected) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected.isEmpty || model.editablePlaylistID == nil)
            Button("Remove from Library…") { model.confirmRemoveFromLibrary(selected) }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(selected.isEmpty)
            Button("Locate File…") { if let track = selected.first { model.locate(track) } }
                .disabled(selected.count != 1 || model.unavailableTracks[selected[0].id] == nil)
            Button("Show in Finder") {
                NSWorkspace.shared.reveal(selected)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(selected.isEmpty)
        }
    }
}

private struct ControlsCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Controls") {
            let player = model.player
            Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: .command)
            Button("Next") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Stop") { player.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button("Go to Current Track") { model.goToCurrentTrack() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(player.currentTrack == nil)
            Divider()
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) }))
                .keyboardShortcut("s", modifiers: [.command, .option])
            Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.repeatMode = $0 })) {
                Text("Off").tag(Player.RepeatMode.off)
                Text("All").tag(Player.RepeatMode.all)
                Text("One").tag(Player.RepeatMode.one)
            }
            Button("Cycle Repeat") { player.cycleRepeatMode() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Volume Up") { player.volume = min(1, player.volume + 0.1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Volume Down") { player.volume = max(0, player.volume - 0.1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Divider()
            Button(model.isShowingUpNext ? "Hide Up Next" : "Show Up Next") { model.isShowingUpNext.toggle() }
                .keyboardShortcut("u", modifiers: [.command, .option])
            Button("Equalizer") { openWindow(id: "equalizer") }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}

/// Replaces the stock "susurrus Help" item, which only says there's no help book.
private struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Report a Bug…") { openWindow(id: "bug-report") }
            Button("susurrus on GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(BugReport.repository)")!)
            }
        }
    }
}

/// The two-deck mixer. Deck shortcuts use ⌃⌘ so they work while typing in the search field
/// without taking letters from it.
private struct MixerCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Mixer") {
            let mixer = model.mixer
            Button(model.isShowingMixer ? "Hide Mixer" : "Show Mixer") { model.isShowingMixer.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Continue in Mixer") { model.continueInMixer() }
                .disabled(model.player.currentTrack == nil)
            Toggle("Show Beats", isOn: Binding(get: { model.isShowingBeatView }, set: { model.isShowingBeatView = $0 }))
                .keyboardShortcut("b", modifiers: [.command, .control])
            Divider()
            ForEach(Mixer.Side.allCases) { side in
                let deck = mixer.deck(side)
                Button(deck.isPlaying ? "Pause Deck \(side.name)" : "Play Deck \(side.name)") { deck.togglePlay() }
                    .keyboardShortcut(side == .a ? "1" : "2", modifiers: [.command, .control])
                    .disabled(!deck.isReady)
                Button("Cue Deck \(side.name)") { deck.cue() }
                    .keyboardShortcut(side == .a ? "1" : "2", modifiers: [.command, .control, .option])
                    .disabled(!deck.isReady)
            }
            Divider()
            Button(mixer.isAutoFading ? "Stop Crossfade" : "Crossfade") {
                mixer.isAutoFading ? mixer.cancelAutoFade() : mixer.autoFade()
            }
            .keyboardShortcut("x", modifiers: [.command, .shift])
            .disabled(!model.isShowingMixer)
            Button("Crossfader Toward A") { mixer.moveCrossfader(to: mixer.crossfader - 0.1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
                .disabled(!model.isShowingMixer)
            Button("Crossfader Toward B") { mixer.moveCrossfader(to: mixer.crossfader + 0.1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
                .disabled(!model.isShowingMixer)
            Button("Center Crossfader") { mixer.moveCrossfader(to: 0.5) }
                .disabled(!model.isShowingMixer)
        }
    }
}

/// Lets the app run as a normal foreground app straight from `swift run`, without a bundle.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep running with the window closed so the menu bar player keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
