import AppKit

/// What one scan changed in the library.
struct ScanResult: Sendable {
    var added: [Int64] = []
    var updated: [Int64] = []
}

/// An audio file a scan found, with its date and size on disk.
struct FoundFile: Sendable {
    let url: URL
    let stamp: FileStamp
}

/// Adding music: Add to Library, drag and drop, and watched folders.
extension AppModel {
    /// A scan is running or waiting for one that is.
    var isScanning: Bool {
        if case .running = scanState { return true }
        return queuedScans > 0
    }

    /// Opens a panel to pick files or folders to add.
    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose music files or folders to add to the library."
        // Not modal: the rest of the app (the mixer, say) keeps working while it's open.
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { _ = self?.addToLibrary(urls) }
        }
    }

    func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Watch"
        panel.message = "New music in this folder will be added automatically."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if !self.watchedFolders.contains(url.path) { self.watchedFolders.append(url.path) }
                self.addToLibrary([url])
            }
        }
    }

    /// Rescans the watched folders, unless a rescan is already waiting or running.
    func rescanWatchedFolders() {
        guard !watchedFolders.isEmpty, !isRescanQueued else { return }
        isRescanQueued = true
        let scan = addToLibrary(watchedFolders.map { URL(fileURLWithPath: $0) })
        Task { [weak self] in
            _ = await scan.value
            self?.isRescanQueued = false
        }
    }

    /// Adds the audio files at or under `urls` to the library in the background, and takes the
    /// tags of files already in it that another app changed since they were read. A scan asked for
    /// while another runs waits its turn; the task finishes once this one is done.
    @discardableResult
    func addToLibrary(_ urls: [URL]) -> Task<ScanResult, Never> {
        let previous = lastScan
        let generation = scanGeneration
        queuedScans += 1
        let scan = Task { [weak self] () -> ScanResult in
            _ = await previous?.value
            guard let self else { return ScanResult() }
            self.queuedScans -= 1
            guard generation == self.scanGeneration, !urls.isEmpty, self.store != nil else { return ScanResult() }
            return await self.scan(urls, generation: generation)
        }
        lastScan = scan
        return scan
    }

    /// Stops the scan that's running (what it found so far stays) and drops the waiting ones.
    func stopScanning() {
        scanGeneration += 1
    }

    private func scan(_ urls: [URL], generation: Int) async -> ScanResult {
        scanState = .running(done: 0, total: 0)
        // What the library knows about its files, and every audio file under `urls`, listed a
        // folder at a time (the listing brings each file's date and size along).
        let known = performQuietly("Couldn't read the library's files") { try $0.fileStamps() } ?? [:]
        let unreadable = performQuietly("Couldn't read the library's files") { try $0.unreadableFiles() } ?? [:]
        let found = await BlockingIO.library.run { Self.audioFiles(in: urls) }

        var toRead: [FoundFile] = []
        var changed: [String: Int64] = [:]
        var unchanged: [(id: Int64, stamp: FileStamp)] = []
        for file in found {
            let path = file.url.path
            if let entry = known[path] {
                if entry.stamp.modified == nil {
                    // First look since dates were kept, or a file susurrus just wrote: take it as it is.
                    unchanged.append((entry.id, file.stamp))
                } else if entry.stamp != file.stamp {
                    toRead.append(file)
                    changed[path] = entry.id
                }
            } else if unreadable[path] != file.stamp {
                toRead.append(file)
            }
        }
        performQuietly("Couldn't note the files' dates") { try $0.setFileStamps(unchanged) }

        var result = ScanResult()
        var scanned: [ScannedTrack] = []
        var failed: [FoundFile] = []
        func save() {
            let added = scanned.filter { changed[$0.path] == nil }
            let updated = scanned.filter { changed[$0.path] != nil }
            if !added.isEmpty, let ids = perform("Couldn't add files to the library", { try $0.insert(added) }) {
                result.added += ids
                let readable = added.map(\.path).filter { unreadable[$0] != nil }
                if !readable.isEmpty { performQuietly("Couldn't update the unreadable files") { try $0.forgetUnreadable(readable) } }
            }
            if !updated.isEmpty, let ids = perform("Couldn't update changed files", { try $0.updateTags(from: updated) }) {
                result.updated += ids
            }
            if !failed.isEmpty {
                // Files that won't read aren't opened again until they change.
                let newFiles = failed.filter { changed[$0.url.path] == nil }.map { (path: $0.url.path, stamp: $0.stamp) }
                let knownFiles = failed.compactMap { file in changed[file.url.path].map { (id: $0, stamp: file.stamp) } }
                performQuietly("Couldn't note unreadable files") { store in
                    try store.noteUnreadable(newFiles)
                    try store.setFileStamps(knownFiles)
                }
            }
            scanned.removeAll()
            failed.removeAll()
        }

        if generation == scanGeneration {
            scanState = .running(done: 0, total: toRead.count)
            // Reading tags means opening each file (over the network share, usually), so do a
            // few at a time and save in batches as we go.
            await withTaskGroup(of: (FoundFile, ScannedTrack?).self) { group in
                var iterator = toRead.makeIterator()
                for _ in 0 ..< 6 {
                    guard let file = iterator.next() else { break }
                    group.addTask { (file, await TagReader.read(file.url)) }
                }
                var done = 0
                for await (file, track) in group {
                    done += 1
                    if let track { scanned.append(track) } else { failed.append(file) }
                    if generation == scanGeneration, let next = iterator.next() {
                        group.addTask { (next, await TagReader.read(next.url)) }
                    }
                    if scanned.count + failed.count >= 200 { save() }
                    if done % 20 == 0 { scanState = .running(done: done, total: toRead.count) }
                }
            }
            save()
        }

        refreshTracks(result.added + result.updated)
        scanState = .finished(added: result.added.count, updated: result.updated.count)
        // The Soulseek share is built from the library, so new and changed tracks go into it now.
        if !(result.added.isEmpty && result.updated.isEmpty), !soulseek.sharedFolderPath.isEmpty {
            soulseek.rescanShares()
        }
        return result
    }

    /// Audio files at or under `urls`, skipping hidden files and packages, with each one's date
    /// and size (they come with the folder listing, so they cost nothing extra on a share).
    nonisolated static func audioFiles(in urls: [URL]) -> [FoundFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        func found(_ url: URL) -> FoundFile? {
            guard TagReader.isAudioFile(url) else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FoundFile(url: url, stamp: FileStamp(modified: values?.contentModificationDate, size: Int64(values?.fileSize ?? 0)))
        }
        var result: [FoundFile] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if !isDirectory.boolValue {
                if let file = found(url) { result.append(file) }
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                if let file = found(file) { result.append(file) }
            }
        }
        return result
    }

    /// Starts the periodic watched-folder rescans.
    func startWatchingFolders() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescanWatchedFolders() }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))  // let launch settle first
            while !Task.isCancelled {
                self?.rescanWatchedFolders()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }
}
