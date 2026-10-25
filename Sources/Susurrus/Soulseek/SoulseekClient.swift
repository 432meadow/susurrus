import Foundation
import Network

/// Events a `SoulseekClient` reports back to the UI layer, in order, from the client's actor.
enum SlskEvent: Sendable {
    case connected(username: String, greeting: String)
    /// The session ended. `canReconnect` is false when trying again is pointless (the account
    /// logged in somewhere else).
    case disconnected(reason: String?, canReconnect: Bool)
    case searchResults(token: UInt32, results: [SlskSearchResult])
    case downloadState(id: UUID, state: SlskDownloadState)
    case uploadStarted(id: UUID, username: String, virtualPath: String, size: UInt64)
    case uploadState(id: UUID, state: SlskUploadState)
    /// How often the server wants wishlist searches repeated.
    case wishlistInterval(seconds: Int)
    /// A private message from another user (already acknowledged to the server).
    case privateMessage(SlskPrivateMessage)
    /// A user went online, away or offline (watched users, or a status query).
    case userStatus(username: String, status: SlskUserStatus, privileged: Bool)
    case userStats(username: String, stats: SlskUserStats)
}

enum SlskUploadState: Equatable, Sendable {
    case waiting
    case transferring(sent: UInt64, total: UInt64)
    case finished
    case failed(String)
}

/// One file to fetch from a peer. The client writes into `partURL` (resuming from its current
/// size when that can be this file) and moves it to `destinationURL` — uniquified if taken —
/// when the transfer completes.
struct SlskDownloadRequest: Sendable {
    let id: UUID
    let username: String
    /// Full remote path, backslash-separated, exactly as it appeared in the search result.
    let remotePath: String
    let size: UInt64
    let partURL: URL
    let destinationURL: URL
}

enum SlskDownloadState: Equatable, Sendable {
    case connecting
    case requested
    case queued(place: UInt32?)
    case transferring(received: UInt64, total: UInt64)
    case finished(URL)
    case failed(String)
    case cancelled
}

/// The server refused the session for good — it turned the login down (wrong password, a taken
/// name…), or the account logged in somewhere else: trying again won't help.
struct SlskSessionRefused: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A connection to a peer, however it came about. `leftover` holds bytes already read past the
/// greeting; `pierced` is true when the peer connected to our listener.
struct SlskPeerConnection: Sendable {
    let stream: any SlskStream
    var leftover = Data()
    var pierced = false
}

/// A Soulseek client covering connect/login/search/download.
///
/// One TCP connection to the central server carries login and search requests. Search *results*
/// arrive out-of-band from peers: either they connect to our listener directly, or — when they
/// can't reach us — the server relays a `ConnectToPeer` and we dial out and answer with
/// `PierceFireWall`. Both paths end in the same peer-message loop. When we need a peer, we do
/// both at once: dial them, and ask the server to have them pierce our listener; whichever
/// connection arrives first is used.
///
/// Downloads ride the same machinery: a `QueueUpload` goes to the peer over a message (`P`)
/// connection, the peer answers with a `TransferRequest` (on any P connection, possibly much
/// later), we allow it, and the file arrives on a separate `F` connection as raw bytes after a
/// token/offset exchange.
///
/// Private messages and user status ride the server connection; user info (description,
/// picture, slots) is asked of the peer directly, like a browse.
actor SoulseekClient {
    static let defaultServer = (host: "server.slsknet.org", port: UInt16(2242))

    /// How long the client waits for each kind of answer. Tests shorten them.
    struct Timeouts: Sendable {
        /// Connecting to the server, and then the login reply.
        var login: TimeInterval = 20
        /// An incoming connection must say who it is (PeerInit or PierceFireWall) within this.
        var handshake: TimeInterval = 10
        /// A message connection with nothing to say is closed after this.
        var peerIdle: TimeInterval = 45
        /// A transfer that stops moving fails after this.
        var transferIdle: TimeInterval = 60
        /// Dialing a peer directly.
        var dial: TimeInterval = 8
        var peerAddress: TimeInterval = 8
        /// Waiting for a peer to pierce our listener after an indirect connection request.
        var pierce: TimeInterval = 20
        var browse: TimeInterval = 300
        var userInfo: TimeInterval = 60
        var transferResponse: TimeInterval = 60
        /// A new distributed parent must speak within this; an adopted one may go quiet for longer.
        var parentGreeting: TimeInterval = 20
        var parentIdle: TimeInterval = 600
        /// The server's answer to a liveness check (after sleep or a network change).
        var statusCheck: TimeInterval = 15
    }

    /// Background tasks have budgets by kind, so a flood of incoming connections can't starve
    /// transfers or the distributed parent.
    private enum TaskKind {
        case peer, transfer, parent

        var budget: Int {
            switch self {
            case .peer: 96
            case .transfer: 40
            case .parent: 1
            }
        }
    }

    private let username: String
    private let password: String
    private let serverAddress: (host: String, port: UInt16)
    private let timeouts: Timeouts
    private let onEvent: @Sendable (SlskEvent) -> Void

    private var server: TCPConnection?
    private var listener: SlskListener?
    /// The server loop and the ping loop.
    private var sessionTasks: [Task<Void, Never>] = []
    private var backgroundTasks: [UUID: (kind: TaskKind, task: Task<Void, Never>)] = [:]
    private var runningTasks: [TaskKind: Int] = [:]
    private(set) var isLoggedIn = false
    /// Why the session ended, for a login that was still waiting.
    private var endReason: String?
    /// The server said the account logged in elsewhere; never worth reconnecting after.
    private var wasRelogged = false
    private static let reloggedMessage = "Logged out: this account was logged in somewhere else"

    // MARK: Answers being waited for

    private let loginReplies = SlskWaiters<ObjectIdentifier, SlskLoginReply>()
    private let peerAddresses = SlskWaiters<String, SlskPeerAddressReply>()
    private let pierces = SlskWaiters<UInt32, SlskPeerConnection>()
    private let transferResponses = SlskWaiters<UInt32, SlskTransferResponse>()
    private let fileLists = SlskWaiters<String, Result<SlskSharedFileList, SlskError>>()
    private let userInfos = SlskWaiters<String, SlskUserInfo>()
    private let statusChecks = SlskWaiters<String, SlskUserStatus>()

    /// Our `ConnectToPeer` requests by token: who should pierce our listener, and for what. Kept
    /// past the wait, so a pierce that loses the race to a direct dial is recognized.
    private struct PierceRequest {
        let user: String
        let type: String
        let expires: ContinuousClock.Instant
    }

    private var pierceRequests: [UInt32: PierceRequest] = [:]

    // MARK: Search state

    /// Results are only parsed for the current search and recent wishlist searches.
    private var searchToken: UInt32?
    private var wishlistTokens: [UInt32: ContinuousClock.Instant] = [:]
    private static let wishlistResultWindow: Duration = .seconds(15 * 60)

    // MARK: Download state

    private struct ActiveDownload {
        let request: SlskDownloadRequest
        var expectedSize: UInt64
        /// Token from the peer's `TransferRequest`; identifies the coming `F` connection.
        var transferToken: UInt32?
        /// The `F` connection while bytes are flowing, so a cancel can close it.
        var fileStream: (any SlskStream)?
        /// Being moved into place; nothing can stop it now.
        var isCompleting = false
    }

    private var downloads: [UUID: ActiveDownload] = [:]
    /// Cancels that arrived before their `download` call did.
    private var cancelledDownloadIDs: Set<UUID> = []
    /// Open message connections by peer username, for sending requests.
    private var peerChannels: [String: any SlskStream] = [:]
    /// In-flight channel establishment, so parallel downloads to one user share a connection.
    private var channelTasks: [String: Task<(any SlskStream)?, Never>] = [:]
    /// Message connections per user (ours and theirs) still being read; when the last one
    /// closes, requests still waiting on that user fail.
    private var messageConnections: [String: Int] = [:]

    // MARK: Sharing state

    private var shares: SlskShareSnapshot = .empty
    private var hasParent = false
    private var adoptingParent = false

    private struct UploadJob {
        let id = UUID()
        let username: String
        let file: SlskSharedFile
        var started = false
    }

    private static let maxUploadSlots = 2
    private var uploadQueue: [UploadJob] = []
    private var activeUploadCount = 0
    /// Total upload rate cap in bytes/s (nil = unlimited), and when the next chunk may go out.
    private var uploadLimit: Int?
    private var uploadPacer = ContinuousClock.now
    /// Users who get nothing from us: no search results, no browsing, no uploads.
    private var blockedUsers: Set<String> = []

    // MARK: User info state

    /// What we tell peers who ask about us (peer code 16).
    private var ownDescription = ""
    private var ownPicture: Data?

    init(
        username: String,
        password: String,
        server: (host: String, port: UInt16) = SoulseekClient.defaultServer,
        timeouts: Timeouts = Timeouts(),
        onEvent: @escaping @Sendable (SlskEvent) -> Void
    ) {
        self.username = username
        self.password = password
        serverAddress = server
        self.timeouts = timeouts
        self.onEvent = onEvent
    }

    // MARK: Connect / disconnect

    /// Connects, logs in, and leaves the client listening for peers. Throws `SlskSessionRefused`
    /// with the server's reason ("INVALIDPASS", …) when the login is turned down.
    func connect() async throws {
        guard server == nil else { return }

        let listenPort = startListener()
        let server = TCPConnection(host: serverAddress.host, port: serverAddress.port, keepAlive: true)
        self.server = server
        endReason = nil
        do {
            try await server.start(timeout: timeouts.login)
            let login = loginReplies.register(ObjectIdentifier(server), timeout: timeouts.login)
            sessionTasks.append(Task { await self.runServerLoop(server) })
            try await server.send(SlskServerMessage.login(username: username, password: password))
            guard let reply = await loginReplies.wait(login) else {
                throw SlskError(message: self.server === server ? "The server didn't answer the login" : endReason ?? "Disconnected")
            }
            guard reply.success else { throw SlskSessionRefused(message: "Login failed: \(reply.greeting)") }

            try await server.send(SlskServerMessage.setWaitPort(listenPort))
            try await server.send(SlskServerMessage.setStatus(online: true))
            try await server.send(SlskServerMessage.sharedFoldersFiles(
                folders: UInt32(shares.folderCount), files: UInt32(shares.files.count)))

            // Join the distributed network as a leaf: ask for a parent, take no children.
            try await server.send(SlskServerMessage.branchRoot(username))
            try await server.send(SlskServerMessage.branchLevel(0))
            try await server.send(SlskServerMessage.acceptChildren(false))
            try await server.send(SlskServerMessage.haveNoParent(true))

            isLoggedIn = true
            onEvent(.connected(username: username, greeting: reply.greeting))
            sessionTasks.append(Task { await self.runPingLoop(server) })
        } catch {
            shutDown(reason: nil)
            throw wasRelogged ? SlskSessionRefused(message: Self.reloggedMessage) : error
        }
    }

    func disconnect() async {
        shutDown(reason: nil)
    }

    /// After a sleep or a network change: asks the server about ourselves and drops the session
    /// when it doesn't answer, so a dead connection is noticed in seconds rather than minutes.
    func verifyConnection() async {
        guard isLoggedIn, let server else { return }
        let check = statusChecks.register(username, timeout: timeouts.statusCheck)
        do {
            try await server.send(SlskServerMessage.getUserStatus(username))
        } catch {
            statusChecks.cancel(check)
            if self.server === server { shutDown(reason: "Connection lost") }
            return
        }
        if await statusChecks.wait(check) == nil, self.server === server {
            shutDown(reason: "Connection lost")
        }
    }

    /// Ends the session: every wait fails, transfers stop, and every connection — idle ones
    /// included — is closed. Safe to call more than once.
    private func shutDown(reason: String?, canReconnect: Bool = true) {
        let wasLoggedIn = isLoggedIn
        isLoggedIn = false
        if endReason == nil { endReason = reason }
        loginReplies.failAll()
        peerAddresses.failAll()
        pierces.failAll()
        transferResponses.failAll()
        fileLists.failAll()
        userInfos.failAll()
        statusChecks.failAll()
        pierceRequests = [:]
        for job in uploadQueue { onEvent(.uploadState(id: job.id, state: .failed(reason ?? "Disconnected"))) }
        uploadQueue = []
        activeUploadCount = 0
        hasParent = false
        adoptingParent = false
        // Files being moved into place still finish (and report it).
        for (id, download) in downloads where !download.isCompleting {
            download.fileStream?.cancel()
            onEvent(.downloadState(id: id, state: .failed(reason ?? "Disconnected")))
        }
        downloads = [:]
        for channel in peerChannels.values { channel.cancel() }
        peerChannels = [:]
        for task in channelTasks.values { task.cancel() }
        channelTasks = [:]
        messageConnections = [:]
        for task in sessionTasks { task.cancel() }
        sessionTasks = []
        for entry in backgroundTasks.values { entry.task.cancel() }
        backgroundTasks = [:]
        runningTasks = [:]
        server?.cancel()
        server = nil
        listener?.cancel()
        listener = nil
        if wasLoggedIn { onEvent(.disconnected(reason: reason, canReconnect: canReconnect)) }
    }

    // MARK: Search

    /// Starts a search; results for the previous one are no longer wanted.
    func search(token: UInt32, query: String) async throws {
        guard isLoggedIn, let server else { throw SlskError(message: "Not connected") }
        searchToken = token
        try await server.send(SlskServerMessage.fileSearch(token: token, query: query))
    }

    /// A saved search; results arrive like any other search's, under `token`, for a while.
    func wishlistSearch(token: UInt32, query: String) async throws {
        guard isLoggedIn, let server else { throw SlskError(message: "Not connected") }
        let now = ContinuousClock.now
        wishlistTokens = wishlistTokens.filter { $0.value > now }
        wishlistTokens[token] = now + Self.wishlistResultWindow
        try await server.send(SlskServerMessage.wishlistSearch(token: token, query: query))
    }

    private func wantsResults(for token: UInt32) -> Bool {
        token == searchToken || wishlistTokens[token].map { $0 > .now } == true
    }

    // MARK: Browse

    /// Asks `user` for their whole share. Big shares can take a while to arrive.
    func browse(user: String) async throws -> SlskSharedFileList {
        guard isLoggedIn else { throw SlskError(message: "Not connected") }
        guard let channel = await channel(to: user) else { throw SlskError(message: "Couldn't connect to \(user)") }
        let answer = fileLists.register(user, timeout: timeouts.browse)
        do {
            try await channel.send(SlskPeerMessage.sharedFileListRequest())
        } catch {
            fileLists.cancel(answer)
            throw SlskError(message: "Couldn't ask \(user) for their files")
        }
        switch await fileLists.wait(answer) {
        case .success(let list)?: return list
        case .failure(let error)?: throw error
        case nil: throw SlskError(message: "\(user) didn't send their file list")
        }
    }

    // MARK: Private messages

    /// Sends a private message. The server stores it if `user` is offline and hands it over
    /// when they next log in.
    func sendMessage(to user: String, text: String) async throws {
        guard isLoggedIn, let server else { throw SlskError(message: "Not connected") }
        try await server.send(SlskServerMessage.messageUser(username: user, message: text))
    }

    /// Every message is acknowledged, or the server sends it again at the next login — even
    /// a blocked user's, which is then dropped.
    private func receivedPrivateMessage(_ message: SlskPrivateMessage) async {
        try? await server?.send(SlskServerMessage.messageAcked(id: message.id))
        guard !blockedUsers.contains(message.username) else { return }
        onEvent(.privateMessage(message))
    }

    // MARK: User status and info

    /// Asks the server to keep us posted on `user`'s status; the first answer also brings
    /// their stats.
    func watch(user: String) async {
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.watchUser(user))
    }

    func unwatch(user: String) async {
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.unwatchUser(user))
    }

    /// Fresh status and stats for `user`; answers arrive as `.userStatus` / `.userStats`.
    func requestStatusAndStats(of user: String) async {
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.getUserStatus(user))
        try? await server.send(SlskServerMessage.getUserStats(user))
    }

    /// What we answer when someone asks about us.
    func setOwnInfo(description: String, picture: Data?) {
        ownDescription = description
        ownPicture = picture
    }

    /// Asks `user` directly for their description, picture and upload slots.
    func userInfo(of user: String) async throws -> SlskUserInfo {
        guard isLoggedIn else { throw SlskError(message: "Not connected") }
        guard let channel = await channel(to: user) else { throw SlskError(message: "Couldn't connect to \(user)") }
        let answer = userInfos.register(user, timeout: timeouts.userInfo)
        do {
            try await channel.send(SlskPeerMessage.userInfoRequest())
        } catch {
            userInfos.cancel(answer)
            throw SlskError(message: "Couldn't ask \(user) about themselves")
        }
        guard let info = await userInfos.wait(answer) else { throw SlskError(message: "\(user) didn't answer") }
        return info
    }

    // MARK: Limits

    /// Caps the total upload rate (bytes/s); nil or 0 lifts the cap.
    func setUploadLimit(_ bytesPerSecond: Int?) {
        uploadLimit = bytesPerSecond.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Waits until `bytes` more may be sent under the cap. Shared by all uploads, so the cap is
    /// for the total, not per transfer.
    private func paceUpload(_ bytes: Int) async {
        guard let limit = uploadLimit else { return }
        let now = ContinuousClock.now
        let start = max(now, uploadPacer)
        uploadPacer = start + .seconds(Double(bytes) / Double(limit))
        if start > now { try? await Task.sleep(until: start, clock: .continuous) }
    }

    /// Replaces the block list; queued uploads to newly blocked users are dropped.
    func updateBlockedUsers(_ users: Set<String>) {
        blockedUsers = users
        for job in uploadQueue where !job.started && users.contains(job.username) {
            onEvent(.uploadState(id: job.id, state: .failed("Blocked")))
        }
        uploadQueue.removeAll { !$0.started && users.contains($0.username) }
    }

    // MARK: Sharing

    /// Swaps in a fresh share scan; the server's counts are updated when logged in.
    func updateShares(_ snapshot: SlskShareSnapshot) async {
        shares = snapshot
        guard isLoggedIn, let server else { return }
        try? await server.send(SlskServerMessage.sharedFoldersFiles(
            folders: UInt32(snapshot.folderCount), files: UInt32(snapshot.files.count)))
    }

    /// A search reached us (via our distributed parent or straight from the server):
    /// answer the searcher directly over a `P` connection when we have matches.
    private func handleSearchRequest(searcher: String, token: UInt32, query: String) {
        guard searcher != username, !shares.isEmpty, !blockedUsers.contains(searcher) else { return }
        let matches = shares.matches(query: query, limit: 100)
        guard !matches.isEmpty,
              let message = try? SlskPeerMessage.fileSearchResponse(
                  username: username, token: token, files: matches,
                  slotFree: activeUploadCount < Self.maxUploadSlots,
                  averageSpeed: 0,
                  queueLength: UInt32(uploadQueue.count))
        else { return }
        spawn(.peer) {
            guard let channel = await self.channel(to: searcher) else { return }
            try? await channel.send(message)
        }
    }

    // MARK: Server loop

    private func runServerLoop(_ server: TCPConnection) async {
        var frames = SlskFrameBuffer()
        do {
            while let chunk = try await server.receive() {
                frames.append(chunk)
                while let frame = try frames.nextFrame() {
                    try await handleServerFrame(frame)
                }
            }
            if self.server === server { shutDown(reason: "The server closed the connection") }
        } catch is CancellationError {
        } catch {
            if self.server === server { shutDown(reason: error.localizedDescription) }
        }
    }

    private func handleServerFrame(_ frame: Data) async throws {
        var reader = SlskReader(frame)
        let code = try reader.u32()
        let payload = frame.dropFirst(4)

        switch SlskServerCode(rawValue: code) {
        case .login:
            if let server, let reply = try? SlskLoginReply(parsing: payload) {
                loginReplies.resolve(ObjectIdentifier(server), with: reply)
            }
        case .relogged:
            wasRelogged = true
            shutDown(reason: Self.reloggedMessage, canReconnect: false)
        case .getPeerAddress:
            if let reply = try? SlskPeerAddressReply(parsing: payload) {
                peerAddresses.resolve(reply.username, with: reply)
            }
        case .connectToPeer:
            guard let request = try? SlskConnectToPeer(parsing: payload) else { return }
            let kind: TaskKind
            switch request.connectionType {
            case "P": kind = .peer
            case "F": kind = .transfer
            default: return  // "D": we take no distributed children
            }
            guard spawn(kind, { await self.runOutgoingPeer(request) }) else {
                try? await server?.send(SlskServerMessage.cantConnectToPeer(token: request.token, username: request.username))
                return
            }
        case .cantConnectToPeer:
            // The peer couldn't pierce our listener: the direct dial is all that's left.
            var reader = SlskReader(payload)
            if let token = try? reader.u32() {
                pierceRequests[token] = nil
                pierces.fail(token)
            }
        case .fileSearch:
            // The server delivers some searches directly (user/room searches, root duty).
            if let request = try? SlskServerSearchRequest(parsing: payload) {
                handleSearchRequest(searcher: request.username, token: request.token, query: request.query)
            }
        case .embeddedMessage:
            if let embedded = try? SlskEmbeddedMessage(parsing: payload),
               embedded.distributedCode == SlskDistribMessage.searchCode,
               case .search(let searcher, let token, let query)? = try? SlskDistribMessage.parseSearch(embedded.payload) {
                handleSearchRequest(searcher: searcher, token: token, query: query)
            }
        case .wishlistInterval:
            var reader = SlskReader(payload)
            if let seconds = try? reader.u32() { onEvent(.wishlistInterval(seconds: Int(seconds))) }
        case .messageUser:
            if let message = try? SlskPrivateMessage(parsing: payload) {
                await receivedPrivateMessage(message)
            }
        case .watchUser:
            if let reply = try? SlskWatchUserReply(parsing: payload) {
                onEvent(.userStatus(username: reply.username, status: reply.status, privileged: false))
                if let stats = reply.stats { onEvent(.userStats(username: reply.username, stats: stats)) }
            }
        case .getUserStatus:
            if let reply = try? SlskUserStatusReply(parsing: payload) {
                statusChecks.resolve(reply.username, with: reply.status)
                onEvent(.userStatus(username: reply.username, status: reply.status, privileged: reply.privileged))
            }
        case .getUserStats:
            if let reply = try? SlskUserStatsReply(parsing: payload) {
                onEvent(.userStats(username: reply.username, stats: reply.stats))
            }
        case .possibleParents:
            guard !hasParent, !adoptingParent,
                  let candidates = try? SlskPossibleParents(parsing: payload),
                  !candidates.parents.isEmpty else { return }
            let parents = candidates.parents
            adoptingParent = spawn(.parent) { await self.adoptParent(from: parents) }
        default:
            break  // Room lists, parent speeds, … — not needed.
        }
    }

    // MARK: Distributed network

    /// Connects to the first workable parent candidate and consumes its search stream until
    /// the connection drops, then asks the server for new candidates.
    private func adoptParent(from candidates: [(username: String, host: String, port: UInt16)]) async {
        defer { adoptingParent = false }
        for candidate in candidates where isLoggedIn && !hasParent && candidate.port > 0 {
            // Parents may go quiet for long; keepalive notices one that vanished without closing.
            let connection = TCPConnection(host: candidate.host, port: candidate.port, keepAlive: true)
            do {
                try await connection.start(timeout: timeouts.dial)
                try await connection.send(SlskPeerInit.peerInit(username: username, connectionType: "D"))
                try await runDistributedLoop(connection, parent: candidate.username)
            } catch {
                // Try the next candidate.
            }
            connection.cancel()
            if Task.isCancelled { return }
            if hasParent {
                // We had adopted this parent and lost it: start over with fresh candidates.
                hasParent = false
                if isLoggedIn, let server {
                    try? await server.send(SlskServerMessage.branchRoot(username))
                    try? await server.send(SlskServerMessage.branchLevel(0))
                    try? await server.send(SlskServerMessage.haveNoParent(true))
                }
                return
            }
        }
    }

    private func runDistributedLoop(_ connection: TCPConnection, parent: String) async throws {
        var frames = SlskFrameBuffer()
        while true {
            // Parents are quiet on a slow night; only the first message is held to a short deadline.
            let timeout = hasParent ? timeouts.parentIdle : timeouts.parentGreeting
            guard let frame = try await nextFrame(&frames, on: connection, timeout: timeout) else { return }
            switch try? SlskDistribMessage.parse(frame) {
            case .branchLevel(let level):
                if !hasParent {
                    hasParent = true
                    try? await server?.send(SlskServerMessage.haveNoParent(false))
                }
                try? await server?.send(SlskServerMessage.branchLevel(UInt32(max(0, level) + 1)))
                if level == 0 {
                    // A level-0 parent is the branch root and won't send a BranchRoot message.
                    try? await server?.send(SlskServerMessage.branchRoot(parent))
                }
            case .branchRoot(let root):
                try? await server?.send(SlskServerMessage.branchRoot(root))
            case .search(let searcher, let token, let query):
                handleSearchRequest(searcher: searcher, token: token, query: query)
            case .embedded(let code, let payload):
                if code == SlskDistribMessage.searchCode,
                   case .search(let searcher, let token, let query)? = try? SlskDistribMessage.parseSearch(payload) {
                    handleSearchRequest(searcher: searcher, token: token, query: query)
                }
            default:
                break
            }
        }
    }

    private func runPingLoop(_ server: TCPConnection) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(55))
            guard !Task.isCancelled else { return }
            do {
                try await server.send(SlskServerMessage.ping())
            } catch {
                if self.server === server { shutDown(reason: "Connection lost") }
                return
            }
        }
    }

    // MARK: Background tasks

    /// Runs `body` as a background task of `kind`; false (and nothing runs) when that kind's
    /// budget is spent.
    @discardableResult
    private func spawn(_ kind: TaskKind, _ body: @escaping @Sendable () async -> Void) -> Bool {
        guard runningTasks[kind, default: 0] < kind.budget else { return false }
        runningTasks[kind, default: 0] += 1
        let id = UUID()
        backgroundTasks[id] = (kind, Task {
            await body()
            self.taskFinished(id)
        })
        return true
    }

    private func taskFinished(_ id: UUID) {
        guard let entry = backgroundTasks.removeValue(forKey: id) else { return }
        runningTasks[entry.kind, default: 1] -= 1
        // A transfer slot opened up: an upload that couldn't start may now.
        if entry.kind == .transfer { pumpUploads() }
    }

    // MARK: Peer connections

    /// Starts listening for incoming peer connections; returns the bound port (0 when
    /// listening failed — searches then rely purely on server-relayed connections).
    private func startListener() -> UInt16 {
        guard let listener = SlskListener(preferredPort: 2234) else { return 0 }
        listener.start { [weak self] connection in
            guard let self else { return connection.cancel() }
            Task { await self.acceptIncomingPeer(connection) }
        }
        self.listener = listener
        return listener.port
    }

    private func acceptIncomingPeer(_ connection: SocketConnection) {
        // A connection accepted just before the session ended has nobody to talk to.
        guard listener != nil, spawn(.peer, { await self.runIncomingPeer(connection) }) else { return connection.cancel() }
    }

    /// A peer connected to our listener: expect a greeting (PeerInit or PierceFireWall) within
    /// the handshake deadline, then peer messages — or, for an `F` connection, raw file bytes.
    private func runIncomingPeer(_ connection: SocketConnection) async {
        var ownsConnection = true
        defer { if ownsConnection { connection.cancel() } }
        var frames = SlskFrameBuffer()
        guard let first = try? await nextFrame(&frames, on: connection, timeout: timeouts.handshake),
              let greeting = try? SlskPeerInit.parse(first) else { return }
        switch greeting {
        case .peerInit(let user, "P"):
            if peerChannels[user] == nil { peerChannels[user] = connection }
            defer { channelClosed(user, connection: connection) }
            await runPeerMessageLoop(connection, frames: &frames, username: user)
        case .peerInit(let user, "F"):
            let buffered = frames.drainRemaining()
            ownsConnection = !spawn(.transfer) {
                await self.runFileConnection(connection, buffered: buffered, from: user)
                connection.cancel()
            }
        case .pierceFirewall(let token):
            guard let request = pierceRequests[token], request.expires > .now else { return }
            if request.type == "F" {
                // An upload task takes the connection from here, unless it already gave up.
                let pierced = SlskPeerConnection(stream: connection, leftover: frames.drainRemaining(), pierced: true)
                ownsConnection = !pierces.resolve(token, with: pierced)
                return
            }
            if !pierces.resolve(token, with: SlskPeerConnection(stream: connection, pierced: true)) {
                // Late: the request was settled another way. With no channel to that user
                // after all, this connection becomes it; otherwise it lost the race.
                guard peerChannels[request.user] == nil else { return }
                peerChannels[request.user] = connection
            }
            defer { channelClosed(request.user, connection: connection) }
            await runPeerMessageLoop(connection, frames: &frames, username: request.user)
        default:
            return  // "D" connections from others: we accept no distributed children.
        }
    }

    /// The server relayed a connection request: dial the peer and pierce their firewall.
    /// For `F` requests the peer then starts a file transfer on this connection. When the dial
    /// fails, the peer is told (CantConnectToPeer) so it stops waiting.
    private func runOutgoingPeer(_ request: SlskConnectToPeer) async {
        let connection = TCPConnection(host: request.host, port: request.port)
        defer { connection.cancel() }
        do {
            try await connection.start(timeout: timeouts.dial)
            try await connection.send(SlskPeerInit.pierceFirewall(token: request.token))
        } catch {
            try? await server?.send(SlskServerMessage.cantConnectToPeer(token: request.token, username: request.username))
            return
        }
        if request.connectionType == "F" {
            await runFileConnection(connection, buffered: Data(), from: request.username)
        } else {
            if peerChannels[request.username] == nil { peerChannels[request.username] = connection }
            defer { channelClosed(request.username, connection: connection) }
            var frames = SlskFrameBuffer()
            await runPeerMessageLoop(connection, frames: &frames, username: request.username)
        }
    }

    /// Reads and handles peer messages until the connection closes or goes quiet.
    private func runPeerMessageLoop(_ connection: any SlskStream, frames: inout SlskFrameBuffer, username: String) async {
        messageConnections[username, default: 0] += 1
        defer { messageConnectionEnded(username) }
        frames.largeFrameCode = SlskPeerCode.sharedFileListResponse.rawValue
        while !Task.isCancelled {
            // Someone we asked for their share list may take a while to start sending it.
            let timeout = fileLists.isWaiting(for: username) ? timeouts.browse : timeouts.peerIdle
            guard let frame = try? await nextFrame(&frames, on: connection, timeout: timeout) else { return }
            await handlePeerFrame(frame, from: username, on: connection)
        }
    }

    private func handlePeerFrame(_ frame: Data, from username: String, on connection: any SlskStream) async {
        var reader = SlskReader(frame)
        guard let code = try? reader.u32() else { return }
        let payload = frame.dropFirst(4)
        switch SlskPeerCode(rawValue: code) {
        case .fileSearchResponse:
            // Answers to searches nobody is waiting for are dropped before inflating them.
            guard let token = SlskSearchResponse.token(in: payload), wantsResults(for: token),
                  case .success(let response) = await Self.parse({ try SlskSearchResponse(parsing: payload) }),
                  wantsResults(for: response.token) else { return }
            onEvent(.searchResults(token: response.token, results: response.results))
        case .transferRequest:
            if let request = try? SlskTransferRequest(parsing: payload) {
                await handleTransferRequest(request, from: username, on: connection)
            }
        case .uploadDenied:
            if let denied = try? SlskUploadDenied(parsing: payload) {
                handleUploadDenied(denied, from: username)
            }
        case .uploadFailed:
            if let failed = try? SlskUploadFailed(parsing: payload),
               let id = findDownload(path: failed.path, username: username) {
                failDownload(id, "The uploader reported a failure")
            }
        case .placeInQueueResponse:
            if let place = try? SlskPlaceInQueueResponse(parsing: payload),
               let id = findDownload(path: place.path, username: username) {
                onEvent(.downloadState(id: id, state: .queued(place: place.place)))
            }
        case .transferResponse:
            if let response = try? SlskTransferResponse(parsing: payload) {
                transferResponses.resolve(response.token, with: response)
            }
        case .queueUpload:
            if let request = try? SlskQueueUploadRequest(parsing: payload) {
                await handleQueueUpload(request.path, from: username, on: connection)
            }
        case .sharedFileListRequest:
            let payload = blockedUsers.contains(username) ? SlskShareSnapshot.empty.browsePayload : shares.browsePayload
            try? await connection.send(SlskPeerMessage.sharedFileListResponse(browsePayload: payload))
        case .sharedFileListResponse:
            guard fileLists.isWaiting(for: username) else { return }
            switch await Self.parse({ try SlskSharedFileList(parsing: payload, username: username) }) {
            case .success(let list):
                fileLists.resolve(username, with: .success(list))
            case .failure:
                fileLists.resolve(username, with: .failure(SlskError(message: "\(username)'s file list couldn't be read")))
            }
        case .userInfoRequest:
            guard !blockedUsers.contains(username) else { break }
            try? await connection.send(SlskPeerMessage.userInfoResponse(
                description: ownDescription,
                picture: ownPicture,
                uploadSlots: UInt32(Self.maxUploadSlots),
                queueLength: UInt32(uploadQueue.filter { !$0.started }.count),
                slotFree: activeUploadCount < Self.maxUploadSlots))
        case .userInfoResponse:
            if let info = try? SlskUserInfo(parsing: payload) {
                userInfos.resolve(username, with: info)
            }
        case .placeInQueueRequest:
            if let request = try? SlskPlaceInQueueRequest(parsing: payload) {
                let waiting = uploadQueue.filter { !$0.started }
                if let place = waiting.firstIndex(where: { $0.username == username && $0.file.virtualPath == request.path }) {
                    try? await connection.send(SlskPeerMessage.placeInQueueResponse(
                        path: request.path, place: UInt32(place + 1)))
                }
            }
        default:
            break
        }
    }

    /// Parses on a background thread, so big payloads (share lists, many results) don't hold
    /// up the client.
    private static func parse<T: Sendable>(_ parse: @escaping @Sendable () throws -> T) async -> Result<T, Error> {
        await Task.detached(priority: .utility) { Result { try parse() } }.value
    }

    /// The next frame on `connection`, reading as needed; nil when it closed. Throws when
    /// nothing arrives within `timeout`.
    private func nextFrame(
        _ frames: inout SlskFrameBuffer, on connection: any SlskStream, timeout: TimeInterval
    ) async throws -> Data? {
        while true {
            if let frame = try frames.nextFrame() { return frame }
            guard let chunk = try await connection.receive(timeout: timeout) else { return nil }
            frames.append(chunk)
        }
    }

    // MARK: Downloads

    /// Queues a download with the peer. Progress arrives as `.downloadState` events; the peer
    /// decides when the transfer actually starts (it may sit in their upload queue for a while).
    func download(_ request: SlskDownloadRequest) async {
        guard isLoggedIn else {
            onEvent(.downloadState(id: request.id, state: .failed("Not connected")))
            return
        }
        guard downloads[request.id] == nil, cancelledDownloadIDs.remove(request.id) == nil else { return }
        // A retry replaces any stale entry for the same file, so a late TransferRequest
        // can't be matched to a download the UI no longer shows.
        downloads = downloads.filter {
            $0.value.isCompleting || $0.value.request.username != request.username
                || $0.value.request.remotePath != request.remotePath
        }
        downloads[request.id] = ActiveDownload(request: request, expectedSize: request.size)
        onEvent(.downloadState(id: request.id, state: .connecting))

        guard let channel = await channel(to: request.username) else {
            failDownload(request.id, "Can't reach \(request.username)")
            return
        }
        guard downloads[request.id] != nil else { return }  // disconnected or cancelled meanwhile
        do {
            try await channel.send(SlskPeerMessage.queueUpload(path: request.remotePath))
            onEvent(.downloadState(id: request.id, state: .requested))
        } catch {
            failDownload(request.id, "Couldn't request the file")
        }
    }

    /// Forgets a download and closes its transfer if one is running. The peer gets no message
    /// for a queued file (the protocol has none); when it later offers the transfer,
    /// `handleTransferRequest` declines it. The download's own partial file is deleted.
    func cancelDownload(_ id: UUID) {
        guard let download = downloads.removeValue(forKey: id) else {
            cancelledDownloadIDs.insert(id)
            return
        }
        guard !download.isCompleting else { return }
        download.fileStream?.cancel()
        SlskTransferFiles.remove(download.request.partURL)
    }

    /// Ends a download that can't go on; its partial file stays for a retry.
    private func failDownload(_ id: UUID, _ reason: String) {
        guard let download = downloads[id], !download.isCompleting else { return }
        downloads[id] = nil
        download.fileStream?.cancel()
        onEvent(.downloadState(id: id, state: .failed(reason)))
    }

    /// The live download `username` means by `path` — never another user's.
    private func findDownload(path: String, username: String) -> UUID? {
        downloads.first { _, download in
            !download.isCompleting && download.request.username == username && download.request.remotePath == path
        }?.key
    }

    /// The peer is ready to upload: remember the transfer token so the coming `F` connection
    /// can be matched, and accept. Requests for nothing we asked for are declined.
    private func handleTransferRequest(
        _ request: SlskTransferRequest, from username: String, on connection: any SlskStream
    ) async {
        guard request.direction == 1 else { return }
        guard let id = findDownload(path: request.path, username: username) else {
            try? await connection.send(
                SlskPeerMessage.transferResponse(token: request.token, allowed: false, reason: "Cancelled"))
            return
        }
        downloads[id]?.transferToken = request.token
        if request.size > 0 { downloads[id]?.expectedSize = request.size }
        try? await connection.send(SlskPeerMessage.transferResponse(token: request.token, allowed: true))
    }

    private func handleUploadDenied(_ denied: SlskUploadDenied, from username: String) {
        guard let id = findDownload(path: denied.path, username: username) else { return }
        if denied.reason == "Queued" {
            onEvent(.downloadState(id: id, state: .queued(place: nil)))
        } else {
            failDownload(id, denied.reason)
        }
    }

    /// Runs an established `F` connection: reads the raw transfer token, matches it to one of
    /// `user`'s downloads, answers with our resume offset, and streams the raw bytes that follow
    /// into the download's part file (written off the actor).
    private func runFileConnection(_ connection: any SlskStream, buffered: Data, from user: String) async {
        var raw = buffered
        while raw.count < 4 {
            guard let chunk = try? await connection.receive(timeout: timeouts.peerIdle) else { return }
            raw.append(chunk)
        }
        var reader = SlskReader(raw)
        guard let token = try? reader.u32(),
              let match = downloads.first(where: {
                  $0.value.transferToken == token && $0.value.request.username == user && !$0.value.isCompleting
              }),
              match.value.fileStream == nil else { return }  // a second connection for a running transfer
        let id = match.key
        downloads[id]?.fileStream = connection
        defer { if downloads[id]?.fileStream === connection { downloads[id]?.fileStream = nil } }

        let expected = match.value.expectedSize
        let partURL = match.value.request.partURL
        let opened: (file: SlskPartFile, offset: UInt64)
        do {
            opened = try await SlskPartFile.open(partURL, expectedSize: expected)
        } catch {
            failDownload(id, "Couldn't write the file: \(error.localizedDescription)")
            return
        }
        let file = opened.file
        var received = opened.offset
        do {
            guard downloads[id] != nil else {
                // Cancelled while the file was opened.
                await file.close()
                SlskTransferFiles.remove(partURL)
                return
            }
            var writer = SlskWriter()
            writer.u64(received)
            try await connection.send(writer.data)

            var pending = Data(raw.dropFirst(4))
            var lastReport = ContinuousClock.now
            if received < expected {
                onEvent(.downloadState(id: id, state: .transferring(received: received, total: expected)))
            }
            while received < expected {
                if pending.isEmpty {
                    guard let chunk = try await connection.receive(timeout: timeouts.transferIdle) else { break }
                    pending = chunk
                }
                // Anything past the expected size isn't part of the file.
                let piece = pending.prefix(Int(min(UInt64(pending.count), expected - received)))
                pending = Data()
                try await file.write(piece)
                received += UInt64(piece.count)
                let now = ContinuousClock.now
                if now - lastReport > .milliseconds(250) || received >= expected {
                    lastReport = now
                    onEvent(.downloadState(id: id, state: .transferring(received: received, total: expected)))
                }
            }
            await file.close()
        } catch {
            await file.close()
            failDownload(id, "Transfer failed: \(error.localizedDescription)")
            return
        }
        guard downloads[id] != nil else { return }  // cancelled
        if received >= expected {
            await completeDownload(id)
        } else {
            failDownload(id, "Transfer interrupted")
        }
    }

    /// Moves the finished part file into place (never clobbering an existing file).
    private func completeDownload(_ id: UUID) async {
        guard let download = downloads[id], !download.isCompleting else { return }
        downloads[id]?.isCompleting = true
        downloads[id]?.fileStream = nil
        let request = download.request
        do {
            let url = try await SlskTransferFiles.moveIntoPlace(request.partURL, to: request.destinationURL)
            onEvent(.downloadState(id: id, state: .finished(url)))
        } catch {
            onEvent(.downloadState(id: id, state: .failed("Couldn't move the finished file")))
        }
        downloads[id] = nil
    }

    // MARK: Uploads

    /// A peer queued one of our shared files. Unknown paths are denied; known ones wait for
    /// an upload slot.
    private func handleQueueUpload(_ path: String, from user: String, on connection: any SlskStream) async {
        guard !blockedUsers.contains(user) else {
            try? await connection.send(SlskPeerMessage.uploadDenied(path: path, reason: "Banned"))
            return
        }
        guard let file = shares.filesByVirtualPath[path] else {
            try? await connection.send(SlskPeerMessage.uploadDenied(path: path, reason: "File not shared."))
            return
        }
        guard uploadQueue.count < 100 else {
            try? await connection.send(SlskPeerMessage.uploadDenied(path: path, reason: "Too many files"))
            return
        }
        guard !uploadQueue.contains(where: { $0.username == user && $0.file.virtualPath == path }) else { return }
        let job = UploadJob(username: user, file: file)
        uploadQueue.append(job)
        onEvent(.uploadStarted(id: job.id, username: user, virtualPath: path, size: file.size))
        onEvent(.uploadState(id: job.id, state: .waiting))
        pumpUploads()
    }

    /// Starts queued uploads while slots are free. One that can't get a task waits for the next
    /// transfer to end.
    private func pumpUploads() {
        while isLoggedIn, activeUploadCount < Self.maxUploadSlots,
              let index = uploadQueue.firstIndex(where: { !$0.started }) {
            let job = uploadQueue[index]
            guard spawn(.transfer, { await self.performUpload(job) }) else { return }
            uploadQueue[index].started = true
            activeUploadCount += 1
        }
    }

    private func finishUpload(_ job: UploadJob, state: SlskUploadState) {
        guard uploadQueue.contains(where: { $0.id == job.id }) else { return }  // ended with the session
        onEvent(.uploadState(id: job.id, state: state))
        uploadQueue.removeAll { $0.id == job.id }
        activeUploadCount = max(0, activeUploadCount - 1)
        pumpUploads()
    }

    /// One upload, start to finish: offer the transfer, wait for the downloader's go-ahead,
    /// open the `F` connection, honor their resume offset, and stream the file.
    private func performUpload(_ job: UploadJob) async {
        guard let channel = await channel(to: job.username) else {
            finishUpload(job, state: .failed("Can't reach \(job.username)"))
            return
        }
        let token = UInt32.random(in: 1 ..< UInt32.max)
        let answer = transferResponses.register(token, timeout: timeouts.transferResponse)
        do {
            try await channel.send(SlskPeerMessage.transferRequest(
                uploadToken: token, path: job.file.virtualPath, size: job.file.size))
        } catch {
            transferResponses.cancel(answer)
            finishUpload(job, state: .failed("Couldn't offer the file"))
            return
        }
        guard let response = await transferResponses.wait(answer) else {
            finishUpload(job, state: .failed("No answer from \(job.username)"))
            return
        }
        guard response.allowed else {
            finishUpload(job, state: .failed(response.reason.isEmpty ? "Declined" : response.reason))
            return
        }

        guard let connection = await openConnection(to: job.username, type: "F") else {
            finishUpload(job, state: .failed("Couldn't open a transfer connection"))
            return
        }
        let stream = connection.stream
        defer { stream.cancel() }
        do {
            var writer = SlskWriter()
            writer.u32(token)
            try await stream.send(writer.data)
            try await sendFile(job, over: stream, buffered: connection.leftover)
            finishUpload(job, state: .finished)
        } catch {
            try? await channel.send(SlskPeerMessage.uploadFailed(path: job.file.virtualPath))
            finishUpload(job, state: .failed(error.localizedDescription))
        }
    }

    /// Reads the downloader's resume offset, then streams the file from there; the file is read
    /// off the actor, a chunk ahead.
    private func sendFile(_ job: UploadJob, over stream: any SlskStream, buffered: Data) async throws {
        var raw = buffered
        while raw.count < 8 {
            guard let chunk = try await stream.receive(timeout: timeouts.peerIdle) else {
                throw SlskError(message: "The downloader closed the connection")
            }
            raw.append(chunk)
        }
        var reader = SlskReader(raw)
        let offset = try reader.u64()
        guard offset <= job.file.size else { throw SlskError(message: "Bad resume offset") }

        let file = try await SlskUploadFile.open(job.file.url, at: offset)
        defer { file.close() }
        var sent = offset
        var lastReport = ContinuousClock.now
        onEvent(.uploadState(id: job.id, state: .transferring(sent: sent, total: job.file.size)))
        while sent < job.file.size {
            // Smaller chunks under a speed cap, so the rate stays smooth.
            let chunkSize = uploadLimit.map { max(4 << 10, min(128 << 10, $0 / 4)) } ?? 128 << 10
            let chunk = try await file.read(upToCount: chunkSize)
            guard !chunk.isEmpty else { break }
            await paceUpload(chunk.count)
            try await stream.send(chunk)
            sent += UInt64(chunk.count)
            let now = ContinuousClock.now
            if now - lastReport > .milliseconds(250) || sent >= job.file.size {
                lastReport = now
                onEvent(.uploadState(id: job.id, state: .transferring(sent: sent, total: job.file.size)))
            }
        }
        guard sent >= job.file.size else { throw SlskError(message: "File ended early") }
        // Let the downloader finish reading and close; their close is the real "done".
        _ = try? await stream.receive(timeout: 30)
    }

    // MARK: Peer channels

    /// An open message connection to `user`, establishing one if needed. Concurrent requests
    /// (several files of one album) share the attempt.
    private func channel(to user: String) async -> (any SlskStream)? {
        if let existing = peerChannels[user] { return existing }
        if let inFlight = channelTasks[user] { return await inFlight.value }
        let task = Task { await self.establishChannel(to: user) }
        channelTasks[user] = task
        let result = await task.value
        if channelTasks[user] == task { channelTasks[user] = nil }
        return result
    }

    private func establishChannel(to user: String) async -> (any SlskStream)? {
        guard let connection = await openConnection(to: user, type: "P") else { return nil }
        let stream = connection.stream
        if !connection.pierced {
            // We dialed it, so nothing reads it yet. (A pierced one is read by its accept task.)
            let reading = spawn(.peer) {
                var frames = SlskFrameBuffer()
                await self.runPeerMessageLoop(stream, frames: &frames, username: user)
                stream.cancel()
                await self.channelClosed(user, connection: stream)
            }
            guard reading else {
                stream.cancel()
                return nil
            }
        }
        guard isLoggedIn else {
            stream.cancel()
            return nil
        }
        // The peer may have connected to us meanwhile; keep using that one.
        if let existing = peerChannels[user] { return existing }
        peerChannels[user] = stream
        return stream
    }

    /// A connection to `user` of `type` ("P" or "F"), made both ways at once: the server is asked
    /// to have the peer pierce our listener (they can always reach us that way when we can't
    /// reach them), and we dial them directly. Whichever connects first is used; the other is
    /// closed. The pierce token stays known until it expires.
    private func openConnection(to user: String, type: String) async -> SlskPeerConnection? {
        guard let server else { return nil }
        let token = UInt32.random(in: 1 ..< UInt32.max)
        let now = ContinuousClock.now
        pierceRequests = pierceRequests.filter { $0.value.expires > now }
        pierceRequests[token] = PierceRequest(user: user, type: type, expires: now + .seconds(timeouts.pierce * 2))
        let pierce = pierces.register(token, timeout: timeouts.pierce)
        do {
            try await server.send(SlskServerMessage.connectToPeer(token: token, username: user, connectionType: type))
        } catch {
            pierces.cancel(pierce)
        }
        let pierces = pierces
        return await withTaskGroup(of: SlskPeerConnection?.self) { group in
            group.addTask { await self.dial(user, type: type) }
            group.addTask { await pierces.wait(pierce) }
            var winner: SlskPeerConnection?
            for await candidate in group {
                guard let candidate else { continue }
                if winner == nil {
                    winner = candidate
                    group.cancelAll()
                } else {
                    candidate.stream.cancel()
                }
            }
            return winner
        }
    }

    /// Dials `user` directly and introduces ourselves with a PeerInit of `type`.
    private func dial(_ user: String, type: String) async -> SlskPeerConnection? {
        guard let address = await peerAddress(of: user), address.port > 0, !Task.isCancelled else { return nil }
        let connection = TCPConnection(host: address.host, port: address.port)
        do {
            try await connection.start(timeout: timeouts.dial)
            try await connection.send(SlskPeerInit.peerInit(username: username, connectionType: type))
            return SlskPeerConnection(stream: connection)
        } catch {
            connection.cancel()
            return nil
        }
    }

    private func channelClosed(_ user: String, connection: any SlskStream) {
        if peerChannels[user] === connection { peerChannels[user] = nil }
    }

    /// With no message connection left to `user`, nothing they were asked can be answered.
    private func messageConnectionEnded(_ user: String) {
        let remaining = messageConnections[user, default: 1] - 1
        guard remaining <= 0 else {
            messageConnections[user] = remaining
            return
        }
        messageConnections[user] = nil
        guard isLoggedIn else { return }
        fileLists.resolve(user, with: .failure(SlskError(message: "\(user) closed the connection")))
        userInfos.fail(user)
    }

    private func peerAddress(of user: String) async -> SlskPeerAddressReply? {
        guard let server else { return nil }
        let answer = peerAddresses.register(user, timeout: timeouts.peerAddress)
        do {
            try await server.send(SlskServerMessage.getPeerAddress(username: user))
        } catch {
            peerAddresses.cancel(answer)
            return nil
        }
        return await peerAddresses.wait(answer)
    }
}
