import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// One row in the downloads list.
struct SoulseekDownload: Identifiable, Equatable {
    let id: UUID
    let username: String
    let remotePath: String
    let size: UInt64
    let partURL: URL
    /// Where the file lands; updated to the actual URL when the transfer finishes.
    var localURL: URL
    var state: SlskDownloadState = .connecting
    /// Tries in a row that ended without getting any further, for backing off and giving up.
    var tries = 0
    /// The most bytes any try has got to.
    var furthest: UInt64 = 0
    /// When an interrupted download is tried again; nil: when its uploader comes back, or the
    /// next session starts.
    var retryDate: Date?
    /// The client that has it, whose reports count for it.
    var session: Int?
    /// When it was queued; nil for one from before this was noted.
    var added: Date?
    /// When it finished, failed or was cancelled.
    var ended: Date?
    /// Where a finished download's file is, as last looked (`refreshWhereabouts`).
    var whereabouts: Whereabouts?
    /// How much of an unfinished download sits in its part file, as last looked.
    var onDisk: UInt64 = 0

    /// Where a finished download's file is now.
    enum Whereabouts: Hashable, Sendable {
        /// Still in the download folder, on this Mac.
        case downloads
        /// Moved to the library folder: on the volume named, or on this Mac.
        case library(volume: String?)
        /// Not where it was left.
        case missing
        /// Moved to the library folder on a volume that isn't mounted.
        case offline(volume: String)
    }

    var fileName: String { localURL.lastPathComponent }
    var isActive: Bool {
        switch state {
        case .finished, .failed, .cancelled: false
        default: true
        }
    }

    var isFinished: Bool {
        if case .finished = state { true } else { false }
    }
}

/// The downloads list as saved: what's still wanted carries on after a quit, and what's over
/// stays as history (up to `SoulseekModel.keptDownloadsLimit`), along with the finished folders
/// not yet imported.
struct SoulseekSavedQueue: Codable, Equatable {
    struct Download: Codable, Equatable {
        enum Outcome: String, Codable {
            case finished, failed, cancelled
        }

        var id: UUID
        var username: String
        var remotePath: String
        var size: UInt64
        var partPath: String
        /// Where the file lands, or landed; it follows the file when an album moves to the library.
        var destinationPath: String
        /// Why it failed; nil otherwise.
        var failure: String?
        /// How it ended; nil while it's still wanted. (Files from before this was saved have
        /// `failure` alone for a failed one.)
        var outcome: Outcome?
        var added: Date?
        var ended: Date?
    }

    var downloads: [Download] = []
    var imports: [String] = []

    var isEmpty: Bool { downloads.isEmpty && imports.isEmpty }
}

/// The queue's file, written off the main thread, the latest version only.
final class SoulseekQueueFile: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "susurrus.soulseek.queue-file", qos: .utility)
    private let lock = NSLock()
    private var latest: SoulseekSavedQueue?

    init(url: URL) {
        self.url = url
    }

    func load() -> SoulseekSavedQueue {
        guard let data = try? Data(contentsOf: url) else { return SoulseekSavedQueue() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SoulseekSavedQueue.self, from: data)) ?? SoulseekSavedQueue()
    }

    func save(_ saved: SoulseekSavedQueue) {
        let isFirst = lock.withLock {
            defer { latest = saved }
            return latest == nil
        }
        if isFirst { queue.async { self.writeLatest() } }
    }

    /// Waits until everything saved so far is on disk.
    func finishSaving() {
        queue.sync { writeLatest() }
    }

    private func writeLatest() {
        let saved: SoulseekSavedQueue? = lock.withLock {
            defer { latest = nil }
            return latest
        }
        guard let saved else { return }
        do {
            if saved.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(saved).write(to: url, options: .atomic)
            }
        } catch {
            EventLog.shared.log("Couldn't save the Soulseek downloads: \(error.localizedDescription)")
        }
    }
}

/// One row in the uploads list (files other users fetch from our shared folder).
struct SoulseekUpload: Identifiable, Equatable {
    let id: UUID
    let username: String
    let remotePath: String
    let size: UInt64
    var state: SlskUploadState = .waiting

    var fileName: String { String(remotePath.split(separator: "\\").last ?? "") }
    var isActive: Bool {
        switch state {
        case .finished, .failed: false
        default: true
        }
    }
}

/// What susurrus knows about another user: server status and stats, and what they told us.
struct SoulseekUserDetails {
    enum InfoState {
        case notRequested
        case loading
        case loaded(SlskUserInfo)
        case failed(String)
    }

    var status: SlskUserStatus?
    var privileged = false
    var stats: SlskUserStats?
    var info: InfoState = .notRequested
}

/// The user an info sheet is showing.
struct SoulseekUserSheet: Identifiable {
    let user: String
    var id: String { user }
}

/// Downloads that stop only once the user confirms.
struct SoulseekCancelRequest: Identifiable {
    let id = UUID()
    let title: String
    let downloadIDs: [UUID]
}

/// UI-facing Soulseek state: credentials, connection status, and the current search.
@MainActor
@Observable
final class SoulseekModel {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(user: String)
        case failed(String)
    }

    /// The Soulseek view's tabs; kept here so right-click menus anywhere can switch tabs.
    enum Pane: Hashable {
        case search, wishlist, browse, messages, downloads
    }

    var pane: Pane = .search {
        didSet { if pane == .downloads { refreshWhereabouts() } }
    }

    // MARK: Account

    /// Changed only through `setCredentials`, so typing in Settings doesn't reconnect (or write
    /// the keychain) on every keystroke.
    private(set) var username: String = UserDefaults.standard.string(forKey: "soulseek.username") ?? ""
    private(set) var password: String = Keychain.string(service: SoulseekModel.keychainService, account: SoulseekModel.keychainAccount) ?? ""

    /// Saves new account details (the password in the keychain) and, when online or trying to
    /// be (a login that just failed), connects again with them.
    func setCredentials(username newUsername: String, password newPassword: String) {
        let newUsername = newUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newUsername != username || newPassword != password else { return }
        if newUsername != username {
            username = newUsername
            UserDefaults.standard.set(newUsername, forKey: "soulseek.username")
        }
        if newPassword != password {
            password = newPassword
            if newPassword.isEmpty {
                Keychain.delete(service: Self.keychainService, account: Self.keychainAccount)
            } else {
                Keychain.set(newPassword, service: Self.keychainService, account: Self.keychainAccount)
            }
        }
        let hasFailed = if case .failed = state { true } else { false }
        guard staysConnected || client != nil || hasFailed else { return }
        disconnect()
        connect()
    }

    /// The user went offline on purpose (or the account is in use somewhere else), so the next
    /// launch doesn't go online just to carry on with downloads.
    private var choseOffline: Bool {
        get { UserDefaults.standard.bool(forKey: "soulseek.choseOffline") }
        set { UserDefaults.standard.set(newValue, forKey: "soulseek.choseOffline") }
    }

    /// Downloads left over from the last run carry on at launch, unless the user had gone offline.
    var resumesDownloadsAtLaunch: Bool { activeDownloadCount > 0 && !choseOffline }

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            if case .failed(let reason) = state, state != oldValue { EventLog.shared.log("Soulseek: \(reason)") }
            if state != .connecting { resumeConnectionWaiters() }
        }
    }

    /// When the next automatic reconnect is due, while waiting for it.
    private(set) var reconnectDate: Date?

    /// Connected or connecting (credential changes then mean a reconnect).
    var isOnline: Bool { client != nil }

    private(set) var results: [SlskSearchResult] = []
    /// `results` as table rows, formatted once as they arrive.
    private(set) var resultRows: [ResultRow] = []
    /// Changes whenever `resultRows` does, so a table filters and sorts again only then.
    private(set) var resultsVersion = 0
    private(set) var resultUserCount = 0
    /// The query the current results belong to; nil before the first search.
    private(set) var activeQuery: String?
    /// The current search has gone 45 seconds without a single result.
    private(set) var searchFoundNothing = false
    var query = ""

    private(set) var downloads: [SoulseekDownload] = []
    /// `downloads` by local folder, kept up to date as downloads come, go, finish and move —
    /// progress alone doesn't regroup anything.
    private(set) var downloadFolders: [DownloadFolder] = []
    private(set) var activeDownloadCount = 0
    private(set) var uploads: [SoulseekUpload] = []
    /// Set to ask "Stop these downloads?"; the Downloads tab shows the question.
    var cancelRequest: SoulseekCancelRequest?
    /// Called (on the main actor) with completed download folders; returns false while the
    /// library can't take them (it isn't open), and the import is retried.
    @ObservationIgnored var importFolders: (([URL]) -> Bool)?
    /// Every library track's path, size and audio details. Called on the main actor when the
    /// share is rebuilt: the share is then built from the library's tracks in the shared folder
    /// without walking it (only files outside the library need a walk, done in the background
    /// now and then). When nil, the whole folder is walked.
    @ObservationIgnored var libraryFiles: (() -> [SlskLibraryFile])?

    // MARK: Sharing state

    enum ShareState: Equatable {
        case notSharing
        case scanning
        case ready(files: Int, folders: Int)
        case failed(String)
    }

    private(set) var shareState: ShareState = .notSharing
    /// The shared folder is being walked for files the library doesn't have (the share is
    /// already up meanwhile).
    private(set) var isWalkingShare = false

    /// The folder other users can search and fetch from; empty = sharing off.
    var sharedFolderPath: String = UserDefaults.standard.string(forKey: "soulseek.sharedFolder") ?? "" {
        didSet {
            guard sharedFolderPath != oldValue else { return }
            UserDefaults.standard.set(sharedFolderPath, forKey: "soulseek.sharedFolder")
            rescanShares(walk: true)
        }
    }

    private var shareSnapshot = SlskShareSnapshot.empty
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var walkID: UUID?
    /// Where the last walk's findings are kept; nil keeps them in memory only.
    private let shareWalkURL: URL?

    var downloadFolderPath: String = UserDefaults.standard.string(forKey: "soulseek.downloadFolder")
        ?? SoulseekModel.defaultDownloadFolder {
        didSet { UserDefaults.standard.set(downloadFolderPath, forKey: "soulseek.downloadFolder") }
    }

    /// Finished album folders are matched to a MusicBrainz release; when every file fits, the
    /// tags are fixed and the cover fetched (see `AppModel.cleanUpDownloads`).
    var tagsDownloads: Bool = UserDefaults.standard.object(forKey: "soulseek.tagDownloads") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tagsDownloads, forKey: "soulseek.tagDownloads") }
    }

    /// What happens to a finished album once it's matched and tagged.
    enum MatchedAlbums: String {
        /// Copied into "Artist/Album" in the library folder, then deleted from the download
        /// folder (see `AppModel.moveDownloadedAlbums`).
        case moveToLibrary
        /// Moved into "Artist/Album (Year)" folders in the download folder.
        case sort
        /// Left where it downloaded.
        case leave
    }

    var matchedAlbums: MatchedAlbums = SoulseekModel.matchedAlbums(
        stored: UserDefaults.standard.string(forKey: "soulseek.matchedAlbums"),
        sorted: UserDefaults.standard.object(forKey: "soulseek.organizeDownloads") as? Bool) {
        didSet { UserDefaults.standard.set(matchedAlbums.rawValue, forKey: "soulseek.matchedAlbums") }
    }

    /// Where matched albums go with `.moveToLibrary`; empty for the library's first watched folder.
    var albumFolderPath: String = UserDefaults.standard.string(forKey: "soulseek.albumFolder") ?? "" {
        didSet { UserDefaults.standard.set(albumFolderPath, forKey: "soulseek.albumFolder") }
    }

    /// The saved choice. Before there was one, "Move them into Artist/Album (Year) folders" said
    /// whether to sort them (if it was ever switched); moving to the library is the default.
    nonisolated static func matchedAlbums(stored: String?, sorted: Bool?) -> MatchedAlbums {
        if let stored, let choice = MatchedAlbums(rawValue: stored) { return choice }
        if let sorted { return sorted ? .sort : .leave }
        return .moveToLibrary
    }

    static var defaultDownloadFolder: String {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Soulseek").path
            ?? NSString("~/Music/Soulseek").expandingTildeInPath
    }

    var hasCredentials: Bool { !username.isEmpty && !password.isEmpty }

    /// A build pointed at a scratch folder (`SUSURRUS_SUPPORT_DIR`) keeps a password of its own, so
    /// trying a build never reads or changes the real account's.
    nonisolated static let keychainService = LibraryStore.isUsingSupportOverride ? "susurrus.soulseek.scratch" : "susurrus.soulseek"
    nonisolated static let keychainAccount = "password"
    private static let maxResults = 2500

    // MARK: Result filters

    /// Narrows the results shown (search, wishlist and browse alike).
    enum FormatFilter: String, CaseIterable, Identifiable {
        case any, lossless, kbps320, kbps256, kbps192

        var id: Self { self }

        var title: String {
            switch self {
            case .any: "Any Format"
            case .lossless: "Lossless"
            case .kbps320: "320 kbps or Better"
            case .kbps256: "256 kbps or Better"
            case .kbps192: "192 kbps or Better"
            }
        }

        func matches(_ result: SlskSearchResult) -> Bool {
            let minimum: Int
            switch self {
            case .any: return true
            case .lossless: return result.isLossless
            case .kbps320: minimum = 320
            case .kbps256: minimum = 256
            case .kbps192: minimum = 192
            }
            // VBR files report their average, so a V0 (≈245) passes 192 and 256 only if it's high enough.
            return result.isLossless || (result.bitrate ?? 0) >= minimum
        }
    }

    var filterText = ""
    var formatFilter: FormatFilter = FormatFilter(rawValue: UserDefaults.standard.string(forKey: "soulseek.formatFilter") ?? "") ?? .any {
        didSet { UserDefaults.standard.set(formatFilter.rawValue, forKey: "soulseek.formatFilter") }
    }
    var freeSlotsOnly: Bool = UserDefaults.standard.bool(forKey: "soulseek.freeSlotsOnly") {
        didSet { UserDefaults.standard.set(freeSlotsOnly, forKey: "soulseek.freeSlotsOnly") }
    }
    var groupByFolder: Bool = UserDefaults.standard.bool(forKey: "soulseek.groupByFolder") {
        didSet { UserDefaults.standard.set(groupByFolder, forKey: "soulseek.groupByFolder") }
    }

    var hasActiveFilters: Bool {
        !filterText.trimmingCharacters(in: .whitespaces).isEmpty || formatFilter != .any || freeSlotsOnly
    }

    /// The filter bar's settings, in a form that's quick to apply to many results.
    struct ResultFilter: Equatable {
        var include: [String] = []
        var exclude: [String] = []
        var format: FormatFilter = .any
        var freeSlotsOnly = false
        var blocked: Set<String> = []

        /// `path` is the result's path, lowercased.
        func matches(_ result: SlskSearchResult, lowercasedPath path: String) -> Bool {
            guard !blocked.contains(result.username), format.matches(result) else { return false }
            if freeSlotsOnly, !result.slotFree { return false }
            return include.allSatisfy(path.contains) && !exclude.contains(where: path.contains)
        }
    }

    var resultFilter: ResultFilter {
        var filter = ResultFilter(format: formatFilter, freeSlotsOnly: freeSlotsOnly, blocked: Set(blockedUsers))
        for word in filterText.lowercased().split(separator: " ") {
            if word.hasPrefix("-"), word.count > 1 {
                filter.exclude.append(String(word.dropFirst()))
            } else {
                filter.include.append(String(word))
            }
        }
        return filter
    }

    /// `results` minus blocked users and whatever the filters exclude.
    func filtered(_ results: [SlskSearchResult]) -> [SlskSearchResult] {
        let filter = resultFilter
        return results.filter { filter.matches($0, lowercasedPath: $0.path.lowercased()) }
    }

    // MARK: Blocked users

    var blockedUsers: [String] = UserDefaults.standard.stringArray(forKey: "soulseek.blockedUsers") ?? [] {
        didSet {
            UserDefaults.standard.set(blockedUsers, forKey: "soulseek.blockedUsers")
            let users = Set(blockedUsers)
            Task { await client?.updateBlockedUsers(users) }
        }
    }

    func block(_ user: String) {
        guard !blockedUsers.contains(user) else { return }
        blockedUsers.append(user)
        blockedUsers.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func unblock(_ user: String) {
        blockedUsers.removeAll { $0 == user }
    }

    // MARK: Upload speed limit

    var limitsUploadSpeed: Bool = UserDefaults.standard.bool(forKey: "soulseek.limitUploads") {
        didSet {
            UserDefaults.standard.set(limitsUploadSpeed, forKey: "soulseek.limitUploads")
            pushUploadLimit()
        }
    }
    /// KB/s, for all uploads together.
    var uploadLimitKBps: Int = UserDefaults.standard.object(forKey: "soulseek.uploadLimitKBps") as? Int ?? 500 {
        didSet {
            UserDefaults.standard.set(uploadLimitKBps, forKey: "soulseek.uploadLimitKBps")
            pushUploadLimit()
        }
    }

    private func pushUploadLimit() {
        let limit = limitsUploadSpeed ? max(1, uploadLimitKBps) * 1024 : nil
        Task { await client?.setUploadLimit(limit) }
    }

    // MARK: Connection and notifications

    var connectsAtLaunch: Bool = UserDefaults.standard.bool(forKey: "soulseek.connectAtLaunch") {
        didSet { UserDefaults.standard.set(connectsAtLaunch, forKey: "soulseek.connectAtLaunch") }
    }
    var postsNotifications: Bool = UserDefaults.standard.object(forKey: "soulseek.notifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(postsNotifications, forKey: "soulseek.notifications") }
    }
    var postsMessageNotifications: Bool = UserDefaults.standard.object(forKey: "soulseek.messageNotifications") as? Bool ?? true {
        didSet { UserDefaults.standard.set(postsMessageNotifications, forKey: "soulseek.messageNotifications") }
    }

    // MARK: Private messages

    let chats: SoulseekChats
    /// The conversation picked in the Messages tab.
    var selectedConversation: String? {
        didSet { markSelectedConversationRead() }
    }
    /// True while the Messages tab is on screen; messages to the selected conversation then
    /// arrive already read.
    var isShowingMessages = false {
        didSet { markSelectedConversationRead() }
    }
    /// Unsent replies, by user, so switching conversations keeps each one's draft to itself.
    @ObservationIgnored var messageDrafts: [String: String] = [:]
    @ObservationIgnored private var messageNotifyTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingNotifications: [String: [SlskPrivateMessage]] = [:]

    private var isReadingSelectedConversation: Bool {
        isShowingMessages && NSApp?.isActive != false
    }

    private func markSelectedConversationRead() {
        if isReadingSelectedConversation, let user = selectedConversation { chats.markRead(user) }
    }

    /// Opens (or starts) the conversation with `user` in the Messages tab.
    func message(_ user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return }
        chats.open(user)
        selectedConversation = user
        pane = .messages
        watch(user)
    }

    func send(_ text: String, to user: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, hasCredentials else { return }
        let id = chats.addOutgoing(text, to: user)
        connect()
        Task {
            await waitForConnection()
            guard let client, case .connected = state else {
                chats.markFailed(id, in: user)
                return
            }
            do {
                try await client.sendMessage(to: user, text: text)
            } catch {
                chats.markFailed(id, in: user)
            }
        }
    }

    func removeConversation(_ user: String) {
        chats.remove(user)
        messageDrafts[user] = nil
        if selectedConversation == user { selectedConversation = nil }
    }

    private func receive(_ message: SlskPrivateMessage) {
        guard !blockedUsers.contains(message.username) else { return }
        let reading = isReadingSelectedConversation && selectedConversation == message.username
        chats.receive(message, unread: !reading)
        if userDetails[message.username]?.status == nil { watch(message.username) }
        guard postsMessageNotifications, !reading else { return }
        // Offline messages arrive in a burst at login: one notification per sender.
        pendingNotifications[message.username, default: []].append(message)
        guard messageNotifyTasks[message.username] == nil else { return }
        let user = message.username
        messageNotifyTasks[user] = Task {
            try? await Task.sleep(for: .seconds(1.5))
            messageNotifyTasks[user] = nil
            let messages = pendingNotifications.removeValue(forKey: user) ?? []
            guard let last = messages.last else { return }
            let offline = messages.contains { !$0.isNew }
            if messages.count == 1 {
                Notifier.post(title: offline ? "\(user) (while you were away)" : user, body: last.message)
            } else {
                Notifier.post(title: user, body: "\(messages.count) new messages\(offline ? " while you were away" : "") — latest: \(last.message)")
            }
        }
    }

    // MARK: User info

    /// Shown to other users who look us up (Settings ▸ Soulseek).
    var userDescription: String = UserDefaults.standard.string(forKey: "soulseek.userDescription") ?? "" {
        didSet {
            guard userDescription != oldValue else { return }
            UserDefaults.standard.set(userDescription, forKey: "soulseek.userDescription")
            let description = userDescription
            Task { await client?.setOwnInfo(description: description, picture: nil) }
        }
    }

    private(set) var userDetails: [String: SoulseekUserDetails] = [:]
    var userSheet: SoulseekUserSheet?
    @ObservationIgnored private var watchedUsers = Set<String>()

    /// Opens the info sheet for `user` and asks the server and the user for fresh details.
    func showUserInfo(_ user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty else { return }
        userSheet = SoulseekUserSheet(user: user)
        requestUserInfo(user)
    }

    func requestUserInfo(_ user: String) {
        guard hasCredentials else { return }
        userDetails[user, default: SoulseekUserDetails()].info = .loading
        connect()
        Task {
            await waitForConnection()
            guard let client, case .connected = state else {
                userDetails[user, default: SoulseekUserDetails()].info = .failed("Not connected")
                return
            }
            watch(user)
            await client.requestStatusAndStats(of: user)
            do {
                let info = try await client.userInfo(of: user)
                userDetails[user, default: SoulseekUserDetails()].info = .loaded(info)
            } catch {
                userDetails[user, default: SoulseekUserDetails()].info = .failed(error.localizedDescription)
            }
        }
    }

    /// Keeps a user's online status current (conversations, info sheets, and uploaders).
    private func watch(_ user: String) {
        guard let client, case .connected = state, watchedUsers.insert(user).inserted else { return }
        Task { await client.watch(user: user) }
    }

    // MARK: Browsing a user

    enum BrowseState {
        case idle
        case loading(user: String)
        case loaded(SlskSharedFileList)
        case failed(user: String, reason: String)
    }

    private(set) var browseState: BrowseState = .idle
    /// Changes with every share list loaded, so views can cache what they derive from it.
    private(set) var browseVersion = 0
    var browseUser = ""
    @ObservationIgnored private var browseTask: Task<Void, Never>?

    /// Fetches a user's whole share for the Browse tab.
    func browse(user: String) {
        let user = user.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, hasCredentials else { return }
        browseUser = user
        pane = .browse
        browseState = .loading(user: user)
        browseTask?.cancel()
        connect()
        browseTask = Task {
            await waitForConnection()
            guard let client, case .connected = state else {
                browseState = .failed(user: user, reason: "Not connected")
                return
            }
            do {
                let list = try await client.browse(user: user)
                guard !Task.isCancelled else { return }
                browseVersion += 1
                browseState = .loaded(list)
            } catch {
                guard !Task.isCancelled else { return }
                browseState = .failed(user: user, reason: error.localizedDescription)
            }
        }
    }

    // MARK: Wishlist

    /// Saved searches, repeated in the background while connected.
    var wishlist: [String] = UserDefaults.standard.stringArray(forKey: "soulseek.wishlist") ?? [] {
        didSet { UserDefaults.standard.set(wishlist, forKey: "soulseek.wishlist") }
    }
    /// Everything each saved search has found this session.
    private(set) var wishlistResults: [String: [SlskSearchResult]] = [:]
    /// `wishlistResults` as table rows.
    private(set) var wishlistRows: [String: [ResultRow]] = [:]
    /// Changes whenever any saved search's rows do.
    private(set) var wishlistVersion = 0
    /// Results found since the item was last looked at.
    private(set) var wishlistNewCounts: [String: Int] = [:]
    private(set) var wishlistLastSearched: [String: Date] = [:]
    /// The server says how often (code 104); 12 minutes until it does.
    private(set) var wishlistInterval = 720
    @ObservationIgnored private var wishlistTokens: [UInt32: String] = [:]
    @ObservationIgnored private var wishlistSeen: [String: Set<String>] = [:]
    @ObservationIgnored private var wishlistTask: Task<Void, Never>?
    @ObservationIgnored private var wishlistCursor = 0
    @ObservationIgnored private var wishlistNotifyTasks: [String: Task<Void, Never>] = [:]
    private static let maxWishlistResults = 1000

    func addToWishlist(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !wishlist.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) else { return }
        wishlist.append(query)
        searchWishlistItem(query)
    }

    func removeFromWishlist(_ query: String) {
        wishlist.removeAll { $0 == query }
        wishlistResults[query] = nil
        wishlistRows[query] = nil
        wishlistVersion += 1
        wishlistNewCounts[query] = nil
        wishlistSeen[query] = nil
        wishlistLastSearched[query] = nil
    }

    func markWishlistSeen(_ query: String) {
        if wishlistNewCounts[query] != nil { wishlistNewCounts[query] = nil }
    }

    var wishlistNewTotal: Int { wishlistNewCounts.values.reduce(0, +) }

    /// Runs one saved search now (if connected).
    func searchWishlistItem(_ query: String) {
        guard let client, case .connected = state else { return }
        let token = UInt32.random(in: 1 ..< UInt32.max)
        wishlistTokens[token] = query
        wishlistLastSearched[query] = Date()
        Task { try? await client.wishlistSearch(token: token, query: query) }
    }

    /// One saved search per interval, round-robin, while connected.
    private func startWishlistLoop() {
        wishlistTask?.cancel()
        wishlistTask = Task {
            try? await Task.sleep(for: .seconds(20))  // let login settle
            while !Task.isCancelled {
                if !wishlist.isEmpty {
                    wishlistCursor %= wishlist.count
                    searchWishlistItem(wishlist[wishlistCursor])
                    wishlistCursor += 1
                }
                try? await Task.sleep(for: .seconds(max(60, wishlistInterval)))
            }
        }
    }

    private func receiveWishlistResults(_ batch: [SlskSearchResult], for query: String) {
        var existing = wishlistResults[query] ?? []
        var seen = wishlistSeen[query] ?? []
        var added: [SlskSearchResult] = []
        for var result in batch where existing.count < Self.maxWishlistResults {
            guard seen.insert(result.username + "\u{1}" + result.path).inserted else { continue }
            result.id = existing.count
            existing.append(result)
            added.append(result)
        }
        guard !added.isEmpty else { return }
        wishlistResults[query] = existing
        wishlistRows[query, default: []] += added.map(ResultRow.init(file:))
        wishlistVersion += 1
        wishlistSeen[query] = seen
        wishlistNewCounts[query, default: 0] += added.count
        // Results trickle in for a while; one notification per round.
        guard postsNotifications, wishlistNotifyTasks[query] == nil else { return }
        wishlistNotifyTasks[query] = Task {
            try? await Task.sleep(for: .seconds(20))
            wishlistNotifyTasks[query] = nil
            if let count = wishlistNewCounts[query], count > 0 {
                Notifier.post(title: "Wishlist: “\(query)”", body: "\(count.formatted()) new \(count == 1 ? "result" : "results") on Soulseek.")
            }
        }
    }

    // MARK: Connection

    private var client: SoulseekClient?
    /// Bumped for every new client, so a late event from one that was replaced can't touch
    /// the current session.
    @ObservationIgnored private var clientGeneration = 0
    @ObservationIgnored private var clientEvents: [Int: AsyncStream<SlskEvent>.Continuation] = [:]
    /// The user wants to be online: set by `connect()`, cleared by `disconnect()`, a rejected
    /// login, or the account logging in elsewhere. Lost connections are retried while it holds.
    @ObservationIgnored private var staysConnected = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var connectionWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var hasSeenNetworkPath = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var networkCheckTask: Task<Void, Never>?
    @ObservationIgnored private var currentToken: UInt32 = 0
    @ObservationIgnored private var resultUsers = Set<String>()
    @ObservationIgnored private var searchWatchdog: Task<Void, Never>?
    @ObservationIgnored private var pendingImportFolders = Set<URL>()
    @ObservationIgnored private var importTask: Task<Void, Never>?

    // Updates from the client are applied in batches, at most every 250 ms.
    @ObservationIgnored private var pendingResults: [(token: UInt32, results: [SlskSearchResult])] = []
    @ObservationIgnored private var pendingDownloadProgress: [UUID: SlskDownloadState] = [:]
    @ObservationIgnored private var pendingUploadProgress: [UUID: SlskUploadState] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var downloadIndex: [UUID: Int] = [:]

    // Keeping downloads going.
    /// Where the queue is saved; nil keeps it in memory only.
    @ObservationIgnored private var queueFile: SoulseekQueueFile?
    /// The next interrupted download's retry.
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Asks uploaders again, now and then, for files they haven't started sending.
    @ObservationIgnored private var requeueTask: Task<Void, Never>?

    /// How the model reaches the network; tests point it at a mock, with an account of their own
    /// (nothing is read from or written to the keychain then) and shorter delays.
    struct Network {
        var server = SoulseekClient.defaultServer
        var account: (username: String, password: String)?
        /// The first automatic reconnect's delay; later ones double.
        var reconnectDelay: TimeInterval = 5
        /// How long to wait after each try at a download that was interrupted, in order; once
        /// they run out, it has failed. About 3 hours in all.
        var retryDelays: [TimeInterval] = [30, 120, 300, 900, 1800, 1800, 1800, 3600]
        /// How often uploaders are asked again for what they haven't started sending.
        var requeueInterval: TimeInterval = 15 * 60
    }

    @ObservationIgnored private let network: Network

    /// `chats` nil loads the saved conversations; `shareWalkURL` nil keeps what walks of the
    /// shared folder find in memory only.
    init(chats: SoulseekChats? = nil, shareWalkURL: URL? = SlskShareWalk.defaultURL, network: Network = Network()) {
        self.chats = chats ?? SoulseekChats()
        self.shareWalkURL = shareWalkURL
        self.network = network
        if let account = network.account {
            username = account.username
            password = account.password
        }
    }

    /// Goes online (or stays there). Lost connections are retried until `disconnect()`.
    func connect() {
        guard hasCredentials else { return }
        staysConnected = true
        choseOffline = false
        watchForNetworkChanges()
        guard client == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDate = nil
        openClient()
    }

    func disconnect() {
        staysConnected = false
        choseOffline = true
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDate = nil
        reconnectAttempts = 0
        closeClient()
        state = .disconnected
    }

    /// Starts a client; its events are handled in order, tagged with its generation.
    private func openClient() {
        clientGeneration += 1
        let generation = clientGeneration
        let (events, continuation) = AsyncStream.makeStream(of: SlskEvent.self)
        clientEvents[generation] = continuation
        let client = SoulseekClient(username: username, password: password, server: network.server) { continuation.yield($0) }
        self.client = client
        state = .connecting
        Task { [weak self] in
            for await event in events { self?.handle(event, from: generation) }
        }
        if !sharedFolderPath.isEmpty, shareSnapshot.isEmpty, shareState != .scanning {
            rescanShares()  // pushes to the client when the share is ready
        }
        let shares = shareSnapshot
        let blocked = Set(blockedUsers)
        let uploadLimit = limitsUploadSpeed ? max(1, uploadLimitKBps) * 1024 : nil
        let description = userDescription
        Task {
            do {
                await client.updateShares(shares)
                await client.updateBlockedUsers(blocked)
                await client.setUploadLimit(uploadLimit)
                await client.setOwnInfo(description: description, picture: nil)
                try await client.connect()
            } catch {
                await client.disconnect()
                retireEvents(of: generation)
                guard self.client === client else { return }
                self.client = nil
                state = .failed(error.localizedDescription)
                if error is SlskSessionRefused {
                    staysConnected = false  // trying again would be turned down (or kick the other session)
                } else {
                    scheduleReconnect()
                }
            }
        }
    }

    /// Lets go of the current client. Its session ends; events it still sends only update
    /// transfers.
    private func closeClient() {
        guard let client else { return }
        self.client = nil
        let generation = clientGeneration
        wishlistTask?.cancel()
        stopRetryingDownloads()
        forgetUserStatuses()
        Task {
            await client.disconnect()
            retireEvents(of: generation)
        }
    }

    /// Ends a finished client's event stream, after a moment for anything it still reports
    /// (a file being moved into place as the session ended).
    private func retireEvents(of generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.clientEvents.removeValue(forKey: generation)?.finish()
        }
    }

    /// The current client couldn't use its connection: drop it and try again shortly.
    private func connectionLost(_ client: SoulseekClient, reason: String) {
        guard self.client === client else { return }
        closeClient()
        state = .failed(reason)
        scheduleReconnect()
    }

    /// Tries again after a lost connection: after about 5 s, then 10, 20, … at most 5 minutes apart.
    private func scheduleReconnect() {
        guard staysConnected, hasCredentials else { return }
        let delay = min(300, network.reconnectDelay * pow(2, Double(min(reconnectAttempts, 6))) * Double.random(in: 0.9 ... 1.1))
        reconnectAttempts += 1
        reconnectDate = Date().addingTimeInterval(delay)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconnectNow()
        }
    }

    private func reconnectNow() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDate = nil
        guard staysConnected, client == nil, hasCredentials else { return }
        openClient()
    }

    /// Reconnects (or checks the connection) when the Mac wakes and when the network changes.
    private func watchForNetworkChanges() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isUp: isUp) }
        }
        monitor.start(queue: DispatchQueue(label: "susurrus.soulseek.network"))
        pathMonitor = monitor
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.networkMayHaveChanged() }
        }
    }

    private func networkChanged(isUp: Bool) {
        // The first report is just how things are.
        guard hasSeenNetworkPath else {
            hasSeenNetworkPath = true
            return
        }
        if isUp { networkMayHaveChanged() }
    }

    /// After a wake or a network change: reconnect now when waiting to, or make sure the
    /// connection still works. A burst of changes is handled once.
    private func networkMayHaveChanged() {
        guard staysConnected else { return }
        networkCheckTask?.cancel()
        networkCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, self.staysConnected else { return }
            if let client = self.client {
                if case .connected = self.state { await client.verifyConnection() }
            } else {
                self.reconnectAttempts = 0
                self.reconnectNow()
            }
        }
    }

    /// Returns once the connection attempt in progress (if any) has succeeded or failed.
    private func waitForConnection() async {
        guard state == .connecting else { return }
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    private func resumeConnectionWaiters() {
        let waiters = connectionWaiters
        connectionWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func handle(_ event: SlskEvent, from generation: Int) {
        let isCurrent = generation == clientGeneration && client != nil
        switch event {
        case .connected(let user, _):
            guard isCurrent else { return }
            state = .connected(user: user)
            reconnectAttempts = 0
            startWishlistLoop()
            for conversation in chats.conversations { watch(conversation.user) }
            resumeDownloads()
        case .disconnected(let reason, let canReconnect):
            retireEvents(of: generation)
            guard isCurrent else { return }  // replaced, or disconnected on purpose
            client = nil
            wishlistTask?.cancel()
            stopRetryingDownloads()
            forgetUserStatuses()
            state = reason.map { .failed($0) } ?? .disconnected
            if canReconnect {
                scheduleReconnect()
            } else {
                staysConnected = false
                choseOffline = true
            }
        case .privateMessage(let message):
            receive(message)
        case .userStatus(let user, let status, let privileged):
            let previous = userDetails[user]?.status
            userDetails[user, default: SoulseekUserDetails()].status = status
            userDetails[user, default: SoulseekUserDetails()].privileged = privileged
            uploaderStatusChanged(user, from: previous, to: status)
        case .userStats(let user, let stats):
            userDetails[user, default: SoulseekUserDetails()].stats = stats
        case .wishlistInterval(let seconds):
            if seconds > 0 { wishlistInterval = seconds }
        case .searchResults(let token, let batch):
            pendingResults.append((token, batch))
            scheduleFlush()
        case .downloadState(let id, let newState):
            applyDownloadState(id, newState, from: generation)
        case .uploadStarted(let id, let username, let path, let size):
            uploads.append(SoulseekUpload(id: id, username: username, remotePath: path, size: size))
            // Keep the history bounded; drop the oldest finished rows first.
            while uploads.count > 200, let oldest = uploads.firstIndex(where: { !$0.isActive }) {
                uploads.remove(at: oldest)
            }
        case .uploadState(let id, let newState):
            if case .transferring = newState {
                pendingUploadProgress[id] = newState
                scheduleFlush()
            } else {
                pendingUploadProgress[id] = nil
                setUploadState(id, newState)
            }
        }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flushPendingUpdates()
        }
    }

    /// Applies the results and progress that arrived since the last flush in one go.
    private func flushPendingUpdates() {
        flushTask = nil
        let batches = pendingResults
        pendingResults = []
        var accepted: [SlskSearchResult] = []
        for (token, batch) in batches {
            if let query = wishlistTokens[token] {
                receiveWishlistResults(batch, for: query)
                continue
            }
            let room = Self.maxResults - results.count - accepted.count
            guard token == currentToken, room > 0, !batch.isEmpty else { continue }
            accepted += batch.prefix(room)
            if let user = batch.first?.username { resultUsers.insert(user) }
        }
        if !accepted.isEmpty {
            for index in accepted.indices { accepted[index].id = results.count + index }
            results += accepted
            resultRows += accepted.map(ResultRow.init(file:))
            resultsVersion += 1
            resultUserCount = resultUsers.count
            searchFoundNothing = false
        }
        let downloadProgress = pendingDownloadProgress
        pendingDownloadProgress = [:]
        for (id, state) in downloadProgress { setDownloadState(id, state) }
        let uploadProgress = pendingUploadProgress
        pendingUploadProgress = [:]
        for (id, state) in uploadProgress { setUploadState(id, state) }
    }

    /// A report from client `generation` on one of its downloads.
    func applyDownloadState(_ id: UUID, _ newState: SlskDownloadState, from generation: Int) {
        // A client that was replaced has no say over a download that's moved on to the next one,
        // except that a file it finished is finished.
        if let session = download(withID: id)?.session, session != generation {
            guard case .finished = newState else { return }
        }
        if case .transferring = newState {
            pendingDownloadProgress[id] = newState
            scheduleFlush()
            return
        }
        pendingDownloadProgress[id] = nil
        setDownloadState(id, newState)
        // The session it was with had already been replaced: the new one wouldn't know.
        if newState == .waitingForConnection, generation != clientGeneration, case .connected = state {
            start(id)
        }
    }

    private func setDownloadState(_ id: UUID, _ newState: SlskDownloadState) {
        guard let index = downloadIndex[id], index < downloads.count, downloads[index].id == id else { return }
        // A try that's over can't change its download with a late report. Only a finished file
        // does: it's there, whatever was decided about it meanwhile.
        switch downloads[index].state {
        case .waitingForConnection, .interrupted, .failed, .cancelled, .finished:
            guard case .finished = newState else { return }
        default:
            break
        }
        let was = downloads[index]
        switch newState {
        case .interrupted(let reason):
            noteInterruption(at: index, reason)
        case .transferring(let received, _):
            downloads[index].state = newState
            // Getting further doesn't count against it, so a flaky peer can still finish.
            if received > downloads[index].furthest {
                downloads[index].furthest = received
                downloads[index].tries = 0
            }
        default:
            downloads[index].state = newState
        }
        if case .finished(let url) = newState {
            downloads[index].localURL = url
            downloads[index].retryDate = nil
            downloads[index].whereabouts = .downloads  // it was just moved into place there
            scheduleImport(of: url.deletingLastPathComponent())
        }
        let now = downloads[index]
        if was.isActive, !now.isActive {
            downloads[index].ended = Date()
            downloads[index].onDisk = 0
        }
        if now.isActive != was.isActive || now.isFinished != was.isFinished || now.localURL != was.localURL {
            downloadsChanged()
        }
    }

    private func setUploadState(_ id: UUID, _ newState: SlskUploadState) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[index].state = newState
    }

    /// Statuses go stale offline; the server resends them for watched users at the next login.
    private func forgetUserStatuses() {
        watchedUsers = []
        for user in userDetails.keys { userDetails[user]?.status = nil }
    }

    // MARK: Sharing

    func chooseSharedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Share"
        panel.message = "Other Soulseek users can search this folder and download from it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sharedFolderPath = url.path  // didSet rescans
    }

    func stopSharing() {
        sharedFolderPath = ""
    }

    /// Rebuilds the share and hands it to the client. With `libraryFiles` it's immediate: the
    /// library's tracks in the shared folder, plus what the last walk found outside the library.
    /// The folder itself is walked (in the background, the share already up) only the first
    /// time, once a day, or when `walk` asks for it. Without `libraryFiles` the whole folder is
    /// walked first, as before.
    func rescanShares(walk forcesWalk: Bool = false) {
        scanTask?.cancel()
        walkID = nil
        isWalkingShare = false
        guard !sharedFolderPath.isEmpty else {
            shareSnapshot = .empty
            shareState = .notSharing
            Task { await client?.updateShares(.empty) }
            return
        }
        let folder = URL(fileURLWithPath: sharedFolderPath, isDirectory: true).standardizedFileURL
        let library = libraryFiles?()
        let walkURL = shareWalkURL
        if shareSnapshot.isEmpty { shareState = .scanning }
        scanTask = Task {
            // The folder may sit on a network share: look at it off the main thread.
            let exists = await Task.detached(priority: .utility) { () -> Bool in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }.value
            guard !Task.isCancelled else { return }
            guard exists else {
                shareState = .failed("The shared folder can't be found")
                return
            }
            guard let library else {
                let snapshot = await Task.detached(priority: .utility) {
                    SlskShareScanner.scan(folder: folder) { _ in nil }
                }.value
                guard !Task.isCancelled else { return }
                applyShare(snapshot)
                return
            }

            let (snapshot, lastWalk) = await Task.detached(priority: .utility) { () -> (SlskShareSnapshot, SlskShareWalk?) in
                let saved = walkURL.flatMap(SlskShareWalk.load).flatMap { $0.folder == folder.path ? $0 : nil }
                return (SlskShareScanner.snapshot(folder: folder, library: library, extra: saved?.files ?? []), saved)
            }.value
            guard !Task.isCancelled else { return }
            applyShare(snapshot)
            if !forcesWalk, let lastWalk, Date().timeIntervalSince(lastWalk.date) < SlskShareWalk.maxAge { return }

            let id = UUID()
            walkID = id
            isWalkingShare = true
            let stop = SlskStopFlag()
            let walked = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { () -> SlskShareSnapshot? in
                    let found = SlskShareScanner.walk(folder, skipping: SlskShareScanner.knownPaths(library), isCancelled: stop.isSet)
                    guard !stop.isSet() else { return nil }
                    if let walkURL { SlskShareWalk(folder: folder.path, date: Date(), files: found).save(to: walkURL) }
                    return SlskShareScanner.snapshot(folder: folder, library: library, extra: found)
                }.value
            } onCancel: {
                stop.set()
            }
            guard walkID == id else { return }
            walkID = nil
            isWalkingShare = false
            if let walked, !Task.isCancelled { applyShare(walked) }
        }
    }

    private func applyShare(_ snapshot: SlskShareSnapshot) {
        shareSnapshot = snapshot
        shareState = .ready(files: snapshot.files.count, folders: snapshot.folderCount)
        let client = client
        Task { await client?.updateShares(snapshot) }
    }

    func clearInactiveUploads() {
        uploads.removeAll { !$0.isActive }
    }

    var hasInactiveUploads: Bool { uploads.contains { !$0.isActive } }
    /// Transfers a reconnect would stop, both ways.
    var activeTransferCount: Int { activeDownloadCount + uploads.lazy.filter(\.isActive).count }

    var shareStatusText: String {
        switch shareState {
        case .notSharing: "Not sharing — other users see an empty share"
        case .scanning: "Scanning the shared folder…"
        case .ready(let files, let folders):
            "Sharing \(files.formatted()) files in \(folders.formatted()) folders"
                + (isWalkingShare ? " — looking for files the library doesn't have…" : "")
        case .failed(let reason): reason
        }
    }

    // MARK: Search

    func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, hasCredentials else { return }
        startSearch(text)
    }

    /// Runs the current search again (after it found nothing).
    func searchAgain() {
        guard let text = activeQuery, hasCredentials else { return }
        query = text
        startSearch(text)
    }

    private func startSearch(_ text: String) {
        results = []
        resultRows = []
        resultsVersion += 1
        resultUsers = []
        resultUserCount = 0
        activeQuery = text
        searchFoundNothing = false
        searchWatchdog?.cancel()
        currentToken = UInt32.random(in: 1 ..< UInt32.max)
        let token = currentToken

        connect()
        Task {
            await waitForConnection()  // connect() may still be logging in
            guard let client, case .connected = state, currentToken == token else { return }
            do {
                try await client.search(token: token, query: text)
            } catch {
                connectionLost(client, reason: error.localizedDescription)
                return
            }
            searchWatchdog = Task { [weak self] in
                try? await Task.sleep(for: .seconds(45))
                guard let self, !Task.isCancelled, self.currentToken == token, self.results.isEmpty else { return }
                self.searchFoundNothing = true
            }
        }
    }

    // MARK: Downloads

    func download(_ selectedResults: [SlskSearchResult]) {
        guard !selectedResults.isEmpty else { return }
        connect()
        for result in selectedResults {
            enqueue(username: result.username, remotePath: result.path, size: result.size)
        }
    }

    /// Re-requests a failed or cancelled download; a leftover partial file resumes where it stopped.
    func retry(_ id: SoulseekDownload.ID) {
        guard let index = downloadIndex[id], index < downloads.count, !downloads[index].isActive else { return }
        let item = downloads.remove(at: index)
        let isUnderWay = downloads.contains { $0.username == item.username && $0.remotePath == item.remotePath && $0.isActive }
        // A new ID: the client remembers cancels of IDs it hasn't seen.
        let id = UUID()
        if !isUnderWay {
            var row = SoulseekDownload(id: id, username: item.username, remotePath: item.remotePath, size: item.size,
                                       partURL: item.partURL, localURL: item.localURL)
            row.added = item.added ?? Date()
            downloads.append(row)
        }
        downloadsChanged()
        connect()
        if !isUnderWay { start(id) }
    }

    /// Tries an interrupted download now rather than when its turn comes.
    func tryNow(_ id: SoulseekDownload.ID) {
        guard let download = download(withID: id), case .interrupted = download.state else { return }
        connect()
        start(id)
        scheduleRetries()
    }

    /// Stops active downloads and throws away what arrived so far.
    func cancel(_ ids: [SoulseekDownload.ID]) {
        var changed = false
        for id in ids {
            guard let index = downloadIndex[id], index < downloads.count, downloads[index].isActive else { continue }
            let partURL = downloads[index].partURL
            let isWithClient: Bool
            switch downloads[index].state {
            case .waitingForConnection, .interrupted: isWithClient = false
            default: isWithClient = downloads[index].session == clientGeneration
            }
            downloads[index].state = .cancelled
            downloads[index].retryDate = nil
            downloads[index].ended = Date()
            downloads[index].onDisk = 0
            pendingDownloadProgress[id] = nil
            changed = true
            if isWithClient, let client {
                Task { await client.cancelDownload(id, partURL: partURL) }
            } else {
                SlskTransferFiles.remove(partURL)
            }
        }
        if changed {
            downloadsChanged()
            scheduleRetries()
        }
    }

    /// Asks before stopping every active download.
    func confirmCancelAll() {
        let ids = downloads.filter(\.isActive).map(\.id)
        guard !ids.isEmpty else { return }
        let title = ids.count == 1 ? "Stop the active download?" : "Stop all \(ids.count.formatted()) active downloads?"
        cancelRequest = SoulseekCancelRequest(title: title, downloadIDs: ids)
    }

    /// Asks before stopping the active downloads that land in `folder`.
    func confirmCancelFolder(_ folder: URL) {
        let ids = downloads.filter { $0.isActive && $0.localURL.deletingLastPathComponent() == folder }.map(\.id)
        guard !ids.isEmpty else { return }
        let count = ids.count == 1 ? "the download" : "\(ids.count.formatted()) downloads"
        cancelRequest = SoulseekCancelRequest(title: "Stop \(count) in “\(folder.lastPathComponent)”?", downloadIDs: ids)
    }

    func remove(_ id: SoulseekDownload.ID) {
        downloads.removeAll { $0.id == id && !$0.isActive }
        downloadsChanged()
    }

    /// The current state of one download.
    func download(withID id: UUID) -> SoulseekDownload? {
        guard let index = downloadIndex[id], index < downloads.count, downloads[index].id == id else { return nil }
        return downloads[index]
    }

    enum DownloadSort: String, CaseIterable, Identifiable {
        case newestFirst, folder

        var id: Self { self }

        var title: String {
            switch self {
            case .newestFirst: "Newest First"
            case .folder: "By Folder"
            }
        }
    }

    var downloadSort: DownloadSort = DownloadSort(rawValue: UserDefaults.standard.string(forKey: "soulseek.downloadSort") ?? "") ?? .newestFirst {
        didSet { UserDefaults.standard.set(downloadSort.rawValue, forKey: "soulseek.downloadSort") }
    }

    /// Downloads that land in one local folder (usually one album).
    struct DownloadFolder: Identifiable, Equatable {
        let url: URL
        /// In file-name order.
        var downloadIDs: [UUID]
        var users: [String]
        var activeCount: Int
        var finishedCount: Int
        /// Where the finished files are, when they're all in one place.
        var whereabouts: SoulseekDownload.Whereabouts?

        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// How many finished, failed and cancelled downloads are kept as history; the oldest go first.
    static let keptDownloadsLimit = 1000

    /// Rebuilds what's derived from the downloads list: lookup by ID, folders, the active count.
    /// Needed when downloads come, go, end or move — not for progress.
    private func downloadsChanged() {
        var over = downloads.lazy.filter { !$0.isActive }.count - Self.keptDownloadsLimit
        if over > 0 {
            downloads.removeAll { row in
                guard over > 0, !row.isActive else { return false }
                over -= 1
                return true
            }
        }
        downloadIndex = Dictionary(uniqueKeysWithValues: downloads.enumerated().map { ($1.id, $0) })
        let active = downloads.lazy.filter(\.isActive).count
        if active != activeDownloadCount { activeDownloadCount = active }
        let folders = Dictionary(grouping: downloads) { $0.localURL.deletingLastPathComponent() }
            .map { url, items -> DownloadFolder in
                let sorted = items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                var seen = Set<String>()
                let places = Set(items.compactMap { $0.isFinished ? $0.whereabouts : nil })
                return DownloadFolder(
                    url: url,
                    downloadIDs: sorted.map(\.id),
                    users: sorted.map(\.username).filter { seen.insert($0).inserted },
                    activeCount: items.lazy.filter(\.isActive).count,
                    finishedCount: items.lazy.filter(\.isFinished).count,
                    whereabouts: places.count == 1 ? places.first : nil)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if folders != downloadFolders { downloadFolders = folders }
        saveQueue()
    }

    // MARK: Keeping downloads going

    /// Picks up what the last run saved, from the queue at `url`, which is kept there from now
    /// on. Unfinished downloads wait to be asked for once connected; finished ones are history,
    /// and where their files are now is looked up in the background.
    func restoreDownloads(from url: URL) {
        let file = SoulseekQueueFile(url: url)
        queueFile = file
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            file.finishSaving()
        }
        let saved = file.load()
        downloads = saved.downloads.map { saved in
            let state: SlskDownloadState
            switch saved.outcome {
            case .finished?: state = .finished(URL(fileURLWithPath: saved.destinationPath))
            case .cancelled?: state = .cancelled
            case .failed?: state = .failed(saved.failure ?? "Failed")
            case nil: state = saved.failure.map { .failed($0) } ?? .waitingForConnection
            }
            var row = SoulseekDownload(
                id: saved.id, username: saved.username, remotePath: saved.remotePath, size: saved.size,
                partURL: URL(fileURLWithPath: saved.partPath), localURL: URL(fileURLWithPath: saved.destinationPath),
                state: state)
            row.added = saved.added
            row.ended = saved.ended
            return row
        }
        pendingImportFolders = Set(saved.imports.map { URL(fileURLWithPath: $0, isDirectory: true) })
        downloadsChanged()
        if !pendingImportFolders.isEmpty { scheduleImport() }
        // The library folder is usually a share: what's there changes as it comes and goes.
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWhereabouts(force: true) }
            }
        }
        refreshWhereabouts(force: true)
    }

    // MARK: Where the files are

    @ObservationIgnored private var whereaboutsTask: Task<Void, Never>?
    @ObservationIgnored private var whereaboutsLookedAt: Date?
    @ObservationIgnored private var whereaboutsAgain = false

    /// Looks, in the background, where each finished download's file is now and how much of each
    /// unfinished one is on disk. Each folder is listed once, since the library folder is usually
    /// on a share. Not more than every 30 s unless `force`.
    func refreshWhereabouts(force: Bool = false) {
        guard !downloads.isEmpty else { return }
        if whereaboutsTask != nil {
            whereaboutsAgain = whereaboutsAgain || force
            return
        }
        if !force, let last = whereaboutsLookedAt, Date().timeIntervalSince(last) < 30 { return }
        whereaboutsLookedAt = Date()
        let rows = downloads.map {
            WhereaboutsQuery(id: $0.id, path: $0.localURL.path, partPath: $0.partURL.path, isFinished: $0.isFinished, isActive: $0.isActive)
        }
        let downloadFolder = downloadFolderPath
        whereaboutsTask = Task { [weak self] in
            let found = await Self.lookUpWhereabouts(rows, downloadFolder: downloadFolder)
            guard let self else { return }
            self.whereaboutsTask = nil
            var changed = false
            for (id, place) in found.places {
                guard let index = self.downloadIndex[id], index < self.downloads.count, self.downloads[index].id == id,
                      self.downloads[index].isFinished, self.downloads[index].whereabouts != place else { continue }
                self.downloads[index].whereabouts = place
                changed = true
            }
            for (id, bytes) in found.onDisk {
                guard let index = self.downloadIndex[id], index < self.downloads.count, self.downloads[index].id == id,
                      self.downloads[index].isActive, self.downloads[index].onDisk != bytes else { continue }
                self.downloads[index].onDisk = bytes
            }
            if changed { self.downloadsChanged() }  // the folders' summaries follow
            if self.whereaboutsAgain {
                self.whereaboutsAgain = false
                self.refreshWhereabouts(force: true)
            }
        }
    }

    private struct WhereaboutsQuery: Sendable {
        let id: UUID
        let path: String
        let partPath: String
        let isFinished: Bool
        let isActive: Bool
    }

    /// Where a finished download's file is, going by its path: in the download folder, or moved
    /// to the library (on the volume named, if it's under /Volumes).
    nonisolated static func place(of path: String, downloadFolder: String) -> SoulseekDownload.Whereabouts {
        let root = URL(fileURLWithPath: downloadFolder, isDirectory: true).standardizedFileURL.path + "/"
        if URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root) { return .downloads }
        return .library(volume: MissingFiles.volumeRoot(of: path).map { ($0 as NSString).lastPathComponent })
    }

    /// The file work, on a utility thread: one listing per folder for the finished files (a
    /// share answers for a folder in one round trip), and each part file's size.
    nonisolated private static func lookUpWhereabouts(
        _ rows: [WhereaboutsQuery], downloadFolder: String
    ) async -> (places: [UUID: SoulseekDownload.Whereabouts], onDisk: [UUID: UInt64]) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var places: [UUID: SoulseekDownload.Whereabouts] = [:]
                let finished = rows.filter(\.isFinished)
                let statuses = MissingFiles.check(finished.enumerated().map { (id: Int64($0.offset), path: $0.element.path) })
                for (offset, row) in finished.enumerated() {
                    switch statuses[Int64(offset)] {
                    case .missing?:
                        places[row.id] = .missing
                    case .offline?:
                        places[row.id] = .offline(volume: MissingFiles.volumeRoot(of: row.path).map { ($0 as NSString).lastPathComponent } ?? "")
                    case nil:
                        places[row.id] = place(of: row.path, downloadFolder: downloadFolder)
                    }
                }
                var onDisk: [UUID: UInt64] = [:]
                for row in rows where row.isActive {
                    onDisk[row.id] = (try? FileManager.default.attributesOfItem(atPath: row.partPath)[.size] as? NSNumber)?.uint64Value ?? 0
                }
                continuation.resume(returning: (places, onDisk))
            }
        }
    }

    /// Waits until the queue as it stands is on disk (for tests; quitting does this too).
    func finishSavingQueue() {
        queueFile?.finishSaving()
    }

    private func saveQueue() {
        guard let queueFile else { return }
        var saved = SoulseekSavedQueue(imports: pendingImportFolders.map(\.path).sorted())
        for download in downloads {
            var row = SoulseekSavedQueue.Download(
                id: download.id, username: download.username, remotePath: download.remotePath, size: download.size,
                partPath: download.partURL.path, destinationPath: download.localURL.path,
                added: download.added, ended: download.ended)
            switch download.state {
            case .finished: row.outcome = .finished
            case .cancelled: row.outcome = .cancelled
            case .failed(let reason):
                row.outcome = .failed
                row.failure = reason
            default: break
            }
            saved.downloads.append(row)
        }
        queueFile.save(saved)
    }

    /// Hands a download to the client, once there is one.
    private func start(_ id: SoulseekDownload.ID) {
        guard let index = downloadIndex[id], index < downloads.count, downloads[index].id == id else { return }
        downloads[index].state = .connecting
        downloads[index].retryDate = nil
        downloads[index].session = nil
        let row = downloads[index]
        let request = SlskDownloadRequest(
            id: id, username: row.username, remotePath: row.remotePath, size: row.size,
            partURL: row.partURL, destinationURL: row.localURL)
        Task {
            await waitForConnection()
            guard download(withID: id)?.state == .connecting else { return }  // cancelled meanwhile
            guard let client, case .connected = state, let index = downloadIndex[id] else {
                setDownloadState(id, .waitingForConnection)
                return
            }
            downloads[index].session = clientGeneration
            watch(request.username)
            await client.download(request)
        }
    }

    /// Back online: what was waiting for the connection is asked for.
    private func resumeDownloads() {
        for download in downloads where download.state == .waitingForConnection { start(download.id) }
        scheduleRetries()
        startRequeueLoop()
    }

    /// The session ended: what was waiting for its next try now waits for the next session.
    private func stopRetryingDownloads() {
        retryTask?.cancel()
        retryTask = nil
        requeueTask?.cancel()
        requeueTask = nil
        for index in downloads.indices {
            guard case .interrupted = downloads[index].state else { continue }
            downloads[index].state = .waitingForConnection
            downloads[index].retryDate = nil
        }
    }

    /// Another try later, or the end of it once there have been enough. An uploader known to be
    /// offline isn't held against the download: it just waits for them.
    private func noteInterruption(at index: Int, _ reason: String) {
        let user = downloads[index].username
        if userDetails[user]?.status == .offline {
            downloads[index].state = .interrupted("Offline")
            downloads[index].retryDate = nil
        } else if downloads[index].tries < network.retryDelays.count {
            downloads[index].state = .interrupted(reason)
            downloads[index].retryDate = Date().addingTimeInterval(network.retryDelays[downloads[index].tries])
            downloads[index].tries += 1
        } else {
            downloads[index].state = .failed(reason)
            downloads[index].retryDate = nil
        }
        scheduleRetries()
    }

    /// Arms the timer for the next interrupted download due, while connected.
    private func scheduleRetries() {
        retryTask?.cancel()
        retryTask = nil
        guard case .connected = state else { return }
        let due = downloads.lazy.filter { if case .interrupted = $0.state { true } else { false } }.compactMap(\.retryDate).min()
        guard let due else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, due.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.retryDueDownloads()
        }
    }

    private func retryDueDownloads() {
        let now = Date()
        for download in downloads {
            if case .interrupted = download.state, let date = download.retryDate, date <= now { start(download.id) }
        }
        scheduleRetries()
    }

    /// An uploader's status: one who went offline is waited for, and one who came back gets asked
    /// again at once for everything, since their queue may not have survived.
    private func uploaderStatusChanged(_ user: String, from previous: SlskUserStatus?, to status: SlskUserStatus) {
        let rows = downloads.filter { $0.username == user && $0.isActive }
        guard !rows.isEmpty else { return }
        if status == .offline {
            for row in rows {
                guard case .interrupted = row.state, let index = downloadIndex[row.id] else { continue }
                downloads[index].state = .interrupted("Offline")
                downloads[index].retryDate = nil
            }
            scheduleRetries()
        } else if previous == .offline {
            for row in rows {
                if case .interrupted = row.state { start(row.id) }
            }
            scheduleRetries()
            askAgain(rows)
        }
    }

    /// Now and then, uploaders are asked again for what they haven't started sending.
    private func startRequeueLoop() {
        requeueTask?.cancel()
        requeueTask = Task { [weak self, interval = network.requeueInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                self.askAgain(self.downloads)
            }
        }
    }

    private func askAgain(_ rows: [SoulseekDownload]) {
        guard let client else { return }
        let waiting = rows.filter {
            switch $0.state {
            case .requested, .queued: true
            default: false
            }
        }
        for (user, files) in Dictionary(grouping: waiting, by: \.username) {
            let ids = files.map(\.id)
            Task { await client.requeue(ids, from: user) }
        }
    }

    /// Points finished downloads at their files' new places after they were moved (old path → new URL).
    func noteMoved(_ moves: [String: URL]) {
        var changed = false
        for index in downloads.indices {
            guard case .finished(let url) = downloads[index].state, let moved = moves[url.path] else { continue }
            downloads[index].localURL = moved
            downloads[index].state = .finished(moved)
            downloads[index].whereabouts = Self.place(of: moved.path, downloadFolder: downloadFolderPath)
            changed = true
        }
        if changed { downloadsChanged() }
    }

    func clearInactiveDownloads() {
        downloads.removeAll { !$0.isActive }
        downloadsChanged()
    }

    var hasInactiveDownloads: Bool { downloads.contains { !$0.isActive } }

    private func enqueue(username: String, remotePath: String, size: UInt64) {
        guard !downloads.contains(where: {
            $0.username == username && $0.remotePath == remotePath && $0.isActive
        }) else { return }

        let folder = URL(fileURLWithPath: downloadFolderPath, isDirectory: true)
        let id = UUID()
        var row = SoulseekDownload(
            id: id, username: username, remotePath: remotePath, size: size,
            partURL: Self.partialFileURL(username: username, remotePath: remotePath, downloadsFolder: folder),
            localURL: Self.localDestination(for: remotePath, downloadsFolder: folder))
        row.added = Date()
        downloads.append(row)
        downloadsChanged()
        start(id)
    }

    /// Local destination for a remote file: the download folder, plus the file's remote parent
    /// folder (so albums stay together) — two levels when that folder is a disc ("CD1",
    /// "Disc 2"), so the discs of an album land in one album folder — plus the file name.
    /// (Saying what's a folder keeps Foundation from asking the disk, maybe a slow share.)
    nonisolated static func localDestination(for remotePath: String, downloadsFolder: URL) -> URL {
        let components = remotePath.split(separator: "\\").map(String.init)
        var folders = components.dropLast().suffix(1)
        if let last = folders.last, isDiscFolder(last), components.count >= 3 {
            folders = components.dropLast().suffix(2)
        }
        var folder = downloadsFolder
        for name in folders { folder.appendPathComponent(sanitize(name), isDirectory: true) }
        return folder.appendingPathComponent(sanitize(components.last ?? "download"), isDirectory: false)
    }

    /// "CD1", "cd 2", "Disc 3", "disk4": a folder holding one disc of an album.
    nonisolated static func isDiscFolder(_ name: String) -> Bool {
        name.range(of: #"^(cd|disc|disk)\s*\d+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Where a download's bytes collect until it's complete: a hidden folder in the download
    /// folder, one file per user and remote path — so two sources of the same file never share,
    /// resume or delete each other's bytes.
    nonisolated static func partialFileURL(username: String, remotePath: String, downloadsFolder: URL) -> URL {
        let digest = SHA256.hash(data: Data((username + "\u{1}" + remotePath).utf8))
        let hash = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let name = String(remotePath.split(separator: "\\").last ?? "download")
        return downloadsFolder
            .appendingPathComponent(".incomplete", isDirectory: true)
            .appendingPathComponent("\(hash) \(sanitize(name, maxBytes: 200)).part", isDirectory: false)
    }

    /// Remote names come from other people's file systems; keep them safe as macOS file names:
    /// no path separators or colons, no control or text-direction characters (which can disguise
    /// a name), no leading dots (hidden files), and at most `maxBytes` of UTF-8, which leaves
    /// room for the " 2" (…) a taken name gets within the file system's 255.
    nonisolated static func sanitize(_ name: String, maxBytes: Int = 240) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", ":":
                scalars.append("-")
            case "\u{061C}", "\u{200E}", "\u{200F}", "\u{202A}" ... "\u{202E}", "\u{2066}" ... "\u{2069}":
                continue
            case _ where scalar.properties.generalCategory == .control:
                continue
            default:
                scalars.append(scalar)
            }
        }
        var cleaned = truncated(String(scalars).trimmingCharacters(in: .whitespaces), toUTF8Bytes: maxBytes)
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// `name` cut to `maxBytes` of UTF-8 between characters, keeping a short extension. Sizes are
    /// counted decomposed, the form file names take on disk ("ü" is then 3 bytes, not 2).
    nonisolated static func truncated(_ name: String, toUTF8Bytes maxBytes: Int) -> String {
        func size<S: StringProtocol>(_ text: S) -> Int { text.decomposedStringWithCanonicalMapping.utf8.count }
        guard size(name) > maxBytes else { return name }
        let ext = (name as NSString).pathExtension
        let suffix = !ext.isEmpty && size(ext) <= 16 ? "." + ext : ""
        let budget = maxBytes - size(suffix)
        var kept = ""
        var bytes = 0
        for character in name.dropLast(suffix.count) {
            let length = size(String(character))
            guard bytes + length <= budget else { break }
            kept.append(character)
            bytes += length
        }
        return kept.trimmingCharacters(in: .whitespaces) + suffix
    }

    /// Imports finished downloads' folders after a short settle, so an album lands as one scan.
    /// Retries while the library is busy with another scan.
    private func scheduleImport(of folder: URL? = nil) {
        if let folder {
            pendingImportFolders.insert(folder)
            saveQueue()
        }
        importTask?.cancel()
        importTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, importFolders != nil else { return }
            for _ in 0 ..< 60 {
                let folders = Array(pendingImportFolders)
                guard !folders.isEmpty else { return }
                if importFolders?(folders) == true {
                    pendingImportFolders.subtract(folders)
                    saveQueue()
                    notifyFinishedFolders(folders)
                    return
                }
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
        }
    }

    /// One notification per downloaded folder once nothing in it is still transferring.
    private func notifyFinishedFolders(_ folders: [URL]) {
        guard postsNotifications else { return }
        for folder in folders {
            let inFolder = downloads.filter { $0.localURL.deletingLastPathComponent() == folder }
            guard !inFolder.contains(where: \.isActive) else { continue }
            let done = inFolder.filter(\.isFinished).count
            guard done > 0 else { continue }
            Notifier.post(
                title: "Downloaded “\(folder.lastPathComponent)”",
                body: "\(done) \(done == 1 ? "file" : "files") added to the library.")
        }
    }

    var statusText: String {
        switch state {
        case .disconnected: "Not connected"
        case .connecting: "Connecting…"
        case .connected(let user): "Connected as \(user)"
        case .failed(let reason):
            reconnectDate.map { "\(reason) — reconnecting at \($0.formatted(date: .omitted, time: .shortened))" } ?? reason
        }
    }
}

/// A cancellation signal a blocking walk can poll from any thread.
final class SlskStopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func set() {
        lock.withLock { stopped = true }
    }

    func isSet() -> Bool {
        lock.withLock { stopped }
    }
}

// MARK: Keychain

/// Minimal generic-password storage so the Soulseek password never sits in plain text.
enum Keychain {
    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func string(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, service: String, account: String) {
        let query = baseQuery(service: service, account: account)
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
