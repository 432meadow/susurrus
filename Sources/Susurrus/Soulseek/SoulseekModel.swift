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

    var pane: Pane = .search

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
        /// Copied into "Artist/Album (Year)" in the library folder, then deleted from the download
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

    /// Keeps a user's online status current (conversations and info sheets).
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

    /// `chats` nil loads the saved conversations; `shareWalkURL` nil keeps what walks of the
    /// shared folder find in memory only.
    init(chats: SoulseekChats? = nil, shareWalkURL: URL? = SlskShareWalk.defaultURL) {
        self.chats = chats ?? SoulseekChats()
        self.shareWalkURL = shareWalkURL
    }

    /// Goes online (or stays there). Lost connections are retried until `disconnect()`.
    func connect() {
        guard hasCredentials else { return }
        staysConnected = true
        watchForNetworkChanges()
        guard client == nil else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectDate = nil
        openClient()
    }

    func disconnect() {
        staysConnected = false
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
        let client = SoulseekClient(username: username, password: password) { continuation.yield($0) }
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
        let delay = min(300, 5 * pow(2, Double(min(reconnectAttempts, 6))) * Double.random(in: 0.9 ... 1.1))
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
        case .disconnected(let reason, let canReconnect):
            retireEvents(of: generation)
            guard isCurrent else { return }  // replaced, or disconnected on purpose
            client = nil
            wishlistTask?.cancel()
            forgetUserStatuses()
            state = reason.map { .failed($0) } ?? .disconnected
            if canReconnect {
                scheduleReconnect()
            } else {
                staysConnected = false
            }
        case .privateMessage(let message):
            receive(message)
        case .userStatus(let user, let status, let privileged):
            userDetails[user, default: SoulseekUserDetails()].status = status
            userDetails[user, default: SoulseekUserDetails()].privileged = privileged
        case .userStats(let user, let stats):
            userDetails[user, default: SoulseekUserDetails()].stats = stats
        case .wishlistInterval(let seconds):
            if seconds > 0 { wishlistInterval = seconds }
        case .searchResults(let token, let batch):
            pendingResults.append((token, batch))
            scheduleFlush()
        case .downloadState(let id, let newState):
            if case .transferring = newState {
                pendingDownloadProgress[id] = newState
                scheduleFlush()
            } else {
                pendingDownloadProgress[id] = nil
                setDownloadState(id, newState)
            }
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

    private func setDownloadState(_ id: UUID, _ newState: SlskDownloadState) {
        guard let index = downloadIndex[id], index < downloads.count, downloads[index].id == id,
              downloads[index].state != .cancelled else { return }
        let was = downloads[index]
        downloads[index].state = newState
        if case .finished(let url) = newState {
            downloads[index].localURL = url
            scheduleImport(of: url.deletingLastPathComponent())
        }
        let now = downloads[index]
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

    /// Re-requests a finished or failed download; a leftover partial file resumes where it stopped.
    func retry(_ id: SoulseekDownload.ID) {
        guard let index = downloadIndex[id], index < downloads.count, !downloads[index].isActive else { return }
        let item = downloads.remove(at: index)
        downloadsChanged()
        connect()
        enqueue(username: item.username, remotePath: item.remotePath, size: item.size)
    }

    /// Stops active downloads and throws away what arrived so far.
    func cancel(_ ids: [SoulseekDownload.ID]) {
        var changed = false
        for id in ids {
            guard let index = downloadIndex[id], index < downloads.count, downloads[index].isActive else { continue }
            downloads[index].state = .cancelled
            pendingDownloadProgress[id] = nil
            changed = true
            if let client {
                Task { await client.cancelDownload(id) }
            } else {
                SlskTransferFiles.remove(downloads[index].partURL)
            }
        }
        if changed { downloadsChanged() }
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

        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// Rebuilds what's derived from the downloads list: lookup by ID, folders, the active count.
    /// Needed when downloads come, go, end or move — not for progress.
    private func downloadsChanged() {
        downloadIndex = Dictionary(uniqueKeysWithValues: downloads.enumerated().map { ($1.id, $0) })
        let active = downloads.lazy.filter(\.isActive).count
        if active != activeDownloadCount { activeDownloadCount = active }
        let folders = Dictionary(grouping: downloads) { $0.localURL.deletingLastPathComponent() }
            .map { url, items -> DownloadFolder in
                let sorted = items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                var seen = Set<String>()
                return DownloadFolder(
                    url: url,
                    downloadIDs: sorted.map(\.id),
                    users: sorted.map(\.username).filter { seen.insert($0).inserted },
                    activeCount: items.lazy.filter(\.isActive).count,
                    finishedCount: items.lazy.filter(\.isFinished).count)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if folders != downloadFolders { downloadFolders = folders }
    }

    /// Points finished downloads at their files' new places after they were moved (old path → new URL).
    func noteMoved(_ moves: [String: URL]) {
        var changed = false
        for index in downloads.indices {
            guard case .finished(let url) = downloads[index].state, let moved = moves[url.path] else { continue }
            downloads[index].localURL = moved
            downloads[index].state = .finished(moved)
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
        let destination = Self.localDestination(for: remotePath, downloadsFolder: folder)
        let request = SlskDownloadRequest(
            id: UUID(),
            username: username,
            remotePath: remotePath,
            size: size,
            partURL: Self.partialFileURL(username: username, remotePath: remotePath, downloadsFolder: folder),
            destinationURL: destination
        )
        downloads.append(SoulseekDownload(
            id: request.id, username: username, remotePath: remotePath,
            size: size, partURL: request.partURL, localURL: destination))
        downloadsChanged()

        Task {
            await waitForConnection()
            guard download(withID: request.id)?.state != .cancelled else { return }
            guard let client, case .connected = state else {
                setDownloadState(request.id, .failed("Not connected"))
                return
            }
            await client.download(request)
        }
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
    private func scheduleImport(of folder: URL) {
        pendingImportFolders.insert(folder)
        importTask?.cancel()
        importTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, importFolders != nil else { return }
            for _ in 0 ..< 60 {
                let folders = Array(pendingImportFolders)
                guard !folders.isEmpty else { return }
                if importFolders?(folders) == true {
                    pendingImportFolders.subtract(folders)
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
