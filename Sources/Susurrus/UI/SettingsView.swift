import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettings()
                .tabItem { Label("Library", systemImage: "music.note.house") }
            PlaybackSettings()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            SoulseekSettings()
                .tabItem { Label("Soulseek", systemImage: "point.3.connected.trianglepath.dotted") }
        }
        .frame(width: 520)
        .padding(20)
    }
}

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var model
    @Environment(Updater.self) private var updater
    @State private var checksForUpdates = false
    @State private var selectedFolder: String?
    @State private var isConfirmingTagWriting = false

    var body: some View {
        Form {
            Section("Watched Folders") {
                Text("New music in these folders is added automatically at launch, when the share mounts, and every 30 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                List(model.watchedFolders, id: \.self, selection: $selectedFolder) { path in
                    Label(path, systemImage: FileManager.default.fileExists(atPath: path) ? "folder" : "folder.badge.questionmark")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minHeight: 100)
                HStack {
                    Button("Add Folder…") { model.chooseWatchedFolder() }
                    Button("Remove") {
                        model.watchedFolders.removeAll { $0 == selectedFolder }
                        selectedFolder = nil
                    }
                    .disabled(selectedFolder == nil)
                    Spacer()
                    Button("Scan Now") { model.rescanWatchedFolders() }
                        .disabled(model.watchedFolders.isEmpty || model.isScanning)
                }
                scanStatus
            }
            Section("Files") {
                Toggle("Write tags to files", isOn: Binding(
                    get: { model.writesTagsToFiles },
                    set: { on in
                        if on, !model.hasConfirmedTagWriting {
                            isConfirmingTagWriting = true
                        } else {
                            model.writesTagsToFiles = on
                        }
                    }))
                Text("Get Info edits and ratings are also written into MP3 (ID3), FLAC and M4A files, in the background. Each file is rewritten as a verified copy that then replaces the original; files changed by another app meanwhile are skipped. Ratings go into MP3 and FLAC files only. Play counts stay in susurrus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TagWriteStatus(queue: model.tagWriter)
            }
            if updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $checksForUpdates)
                        .onAppear { checksForUpdates = updater.checksAutomatically }
                        .onChange(of: checksForUpdates) { _, on in updater.checksAutomatically = on }
                    HStack {
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Write tags into your music files?", isPresented: $isConfirmingTagWriting) {
            Button("Write Tags to Files") {
                model.hasConfirmedTagWriting = true
                model.writesTagsToFiles = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From now on, tag edits and ratings change the audio files themselves, not just susurrus's library, and other apps will see the changes. susurrus checks every rewritten file before it replaces the original, but make sure you have a backup of your music first.")
        }
    }

    @ViewBuilder private var scanStatus: some View {
        switch model.scanState {
        case .idle:
            EmptyView()
        case .running(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(total == 0 ? "Looking for new files…" : "Reading \(done.formatted()) of \(total.formatted()) new files…")
                    .font(.caption)
            }
        case .finished(let added, let updated):
            Text(Self.scanSummary(added: added, updated: updated))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func scanSummary(added: Int, updated: Int) -> String {
        switch (added, updated) {
        case (0, 0): "No new or changed files found."
        case (_, 0): "Added \(added.formatted()) \(added == 1 ? "track" : "tracks")."
        case (0, _): "Updated \(updated.formatted()) changed \(updated == 1 ? "file" : "files")."
        default: "Added \(added.formatted()) \(added == 1 ? "track" : "tracks"), updated \(updated.formatted()) changed \(updated == 1 ? "file" : "files")."
        }
    }
}

private struct SoulseekSettings: View {
    @Environment(AppModel.self) private var model
    /// The account fields are edited here and saved together (Return or Save), so typing doesn't
    /// reconnect on every keystroke.
    @State private var usernameDraft = ""
    @State private var passwordDraft = ""
    @State private var isConfirmingReconnect = false

    var body: some View {
        @Bindable var soulseek = model.soulseek
        Form {
            Section("Account") {
                TextField("Username", text: $usernameDraft)
                    .autocorrectionDisabled()
                    .onSubmit(saveAccount)
                SecureField("Password", text: $passwordDraft)
                    .onSubmit(saveAccount)
                HStack(alignment: .firstTextBaseline) {
                    Text(accountChanged
                        ? "Press Return or Save to use the new details."
                        : "The password is kept in your keychain. A username nobody has used before is registered on the Soulseek network the first time it connects — pick a throwaway password either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save", action: saveAccount)
                        .disabled(!accountChanged)
                }
            }
            Section("Messages and User Info") {
                LabeledContent("Description") {
                    TextEditor(text: $soulseek.userDescription)
                        .font(.body)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.08)))
                }
                Text("Other users see this when they look you up, along with your upload slots and queue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Notify when someone sends you a message", isOn: $soulseek.postsMessageNotifications)
                Text("Conversations are kept on this Mac. Messages from blocked users are dropped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Connection") {
                LabeledContent("Status") {
                    Text(soulseek.statusText)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Connect") { soulseek.connect() }
                        .disabled(!soulseek.hasCredentials || soulseek.state == .connecting)
                    Button("Disconnect") { soulseek.disconnect() }
                        .disabled(soulseek.state == .disconnected)
                }
                Toggle("Connect when susurrus starts", isOn: $soulseek.connectsAtLaunch)
                Text("Searching connects automatically. Staying connected keeps your share available and lets saved searches (the wishlist) run in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sharing") {
                LabeledContent("Shared Folder") {
                    HStack {
                        Text(soulseek.sharedFolderPath.isEmpty ? "None" : soulseek.sharedFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { soulseek.chooseSharedFolder() }
                        if !soulseek.sharedFolderPath.isEmpty {
                            Button("Stop Sharing") { soulseek.stopSharing() }
                        }
                    }
                }
                HStack {
                    if soulseek.shareState == .scanning || soulseek.isWalkingShare { ProgressView().controlSize(.small) }
                    Text(soulseek.shareStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Rescan") { soulseek.rescanShares(walk: true) }
                        .controlSize(.small)
                        .disabled(soulseek.sharedFolderPath.isEmpty || soulseek.shareState == .scanning || soulseek.isWalkingShare)
                }
                Text("Other users can search this folder and download from it. Sharing back is what keeps Soulseek alive — many users only upload to people who share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Limit upload speed", isOn: $soulseek.limitsUploadSpeed)
                if soulseek.limitsUploadSpeed {
                    LabeledContent("Upload Limit") {
                        HStack(spacing: 4) {
                            TextField("KB/s", value: $soulseek.uploadLimitKBps, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Text("KB/s, for all uploads together")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Blocked Users") {
                if soulseek.blockedUsers.isEmpty {
                    Text("Nobody. Right-click a search result or an upload ▸ Block to add someone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(soulseek.blockedUsers, id: \.self) { user in
                        HStack {
                            Text(user)
                            Spacer()
                            Button("Unblock") { soulseek.unblock(user) }
                                .controlSize(.small)
                        }
                    }
                    Text("Blocked users' search results are hidden, and they can't search, browse or download your share.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Downloads") {
                LabeledContent("Download Folder") {
                    HStack {
                        Text(soulseek.downloadFolderPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseDownloadFolder() }
                    }
                }
                Text("Finished downloads keep their remote folder name (so albums stay together) and are added to the library automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Notify when a download folder finishes or a saved search finds something new", isOn: $soulseek.postsNotifications)
                Toggle("Tag finished albums from MusicBrainz", isOn: $soulseek.tagsDownloads)
                Picker("Matched Albums", selection: $soulseek.matchedAlbums) {
                    Text("Move to the library folder").tag(SoulseekModel.MatchedAlbums.moveToLibrary)
                    Text("Sort into Artist/Album (Year) here").tag(SoulseekModel.MatchedAlbums.sort)
                    Text("Leave as they are").tag(SoulseekModel.MatchedAlbums.leave)
                }
                .disabled(!soulseek.tagsDownloads)
                .onChange(of: soulseek.matchedAlbums) { model.matchedAlbumsChanged() }
                if soulseek.matchedAlbums == .moveToLibrary {
                    LabeledContent("Library Folder") {
                        HStack {
                            Text(model.albumLibraryFolder?.path ?? "None: choose one, or add a watched folder")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") { chooseAlbumFolder() }
                        }
                    }
                    .disabled(!soulseek.tagsDownloads)
                }
                Text(matchedAlbumsNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            usernameDraft = soulseek.username
            passwordDraft = soulseek.password
        }
        .alert("Reconnect as \(usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines))?", isPresented: $isConfirmingReconnect) {
            Button("Reconnect") { commitAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = soulseek.activeTransferCount
            Text("Changing the account reconnects to Soulseek, which stops \(count == 1 ? "the transfer" : "\(count.formatted()) transfers") in progress.")
        }
    }

    private var accountChanged: Bool {
        usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines) != model.soulseek.username
            || passwordDraft != model.soulseek.password
    }

    /// Saves the account fields, asking first when that would cut off transfers.
    private func saveAccount() {
        guard accountChanged else { return }
        if model.soulseek.isOnline, model.soulseek.activeTransferCount > 0 {
            isConfirmingReconnect = true
        } else {
            commitAccount()
        }
    }

    private func commitAccount() {
        model.soulseek.setCredentials(username: usernameDraft, password: passwordDraft)
        usernameDraft = model.soulseek.username
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "Soulseek downloads will be saved in this folder."
        panel.directoryURL = URL(fileURLWithPath: model.soulseek.downloadFolderPath)
        // Not modal: the rest of the app (the mixer, say) keeps working while it's open.
        panel.begin { [soulseek = model.soulseek] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { soulseek.downloadFolderPath = url.path }
        }
    }

    private func chooseAlbumFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "Matched Soulseek albums will be moved into this folder, as Artist/Album (Year)."
        panel.directoryURL = model.albumLibraryFolder
        panel.begin { [model] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                // The library's own folder is kept as the default, so it follows that folder.
                model.soulseek.albumFolderPath = url.path == model.watchedFolders.first ? "" : url.path
                model.moveDownloadedAlbums()
            }
        }
    }

    private var matchedAlbumsNote: String {
        var note = "Only when every file matches a release's track list and the lengths agree; the tags and cover are written into the downloaded files. Anything less certain is left as it is: right-click it in Downloads ▸ Look Up Album… to pick the release."
        if model.soulseek.matchedAlbums == .moveToLibrary {
            note += " Then the album is copied into Artist/Album (Year) in the library folder, each file is checked, the library follows it there, and the download is deleted. While the library folder's disk isn't connected, albums wait for it."
        }
        return note
    }
}

/// Progress and problems for the background tag writes.
private struct TagWriteStatus: View {
    let queue: TagWriteQueue

    var body: some View {
        if queue.isRunning {
            ProgressView(value: Double(queue.done), total: Double(max(queue.total, 1))) {
                Text(label).font(.caption).lineLimit(1).truncationMode(.middle)
            }
        } else if queue.total > 0 {
            Text("Wrote tags to \(queue.written.formatted()) of \(queue.total.formatted()) files.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !queue.failures.isEmpty {
            DisclosureGroup("\(queue.failures.count) files couldn't be written") {
                ForEach(queue.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text((failure.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(failure.message).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .help(failure.path)
                }
                Button("Clear") { queue.clearFailures() }
            }
            .font(.caption)
        }
    }

    private var label: String {
        if let path = queue.waitingForPath {
            return "Waiting for “\((path as NSString).lastPathComponent)” to stop playing…"
        }
        let name = queue.currentPath.map { " — " + ($0 as NSString).lastPathComponent } ?? ""
        return "Writing tags: \(queue.done.formatted()) of \(queue.total.formatted()) files\(name)"
    }
}

private struct PlaybackSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var player = model.player
        Form {
            Picker("Repeat", selection: $player.repeatMode) {
                Text("Off").tag(Player.RepeatMode.off)
                Text("All").tag(Player.RepeatMode.all)
                Text("One").tag(Player.RepeatMode.one)
            }
            Toggle("Shuffle", isOn: Binding(get: { player.shuffle }, set: { player.setShuffle($0) }))
            Picker("Output", selection: Binding(get: { player.outputDeviceUID }, set: { player.setOutputDevice($0) })) {
                Text("System Output").tag(String?.none)
                ForEach(player.outputs.devices) { device in
                    Text(device.name).tag(String?.some(device.uid))
                }
            }
            LabeledContent("Equalizer") {
                Button("Show Equalizer…") { openWindow(id: "equalizer") }
            }
            Text("Tracks on a network share play straight from it, except FLAC, which is copied to a small local cache first (it has to be read end to end). The next track is copied ahead while the current one plays, for gapless transitions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
