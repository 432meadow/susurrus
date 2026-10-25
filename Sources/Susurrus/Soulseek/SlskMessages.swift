import CryptoKit
import Foundation

/// Soulseek message encoding/decoding. Only the messages susurrus uses are implemented;
/// everything else is skipped by code. Layouts verified against Nicotine+ 3.3.10
/// (`doc/SLSKPROTOCOL.md` and `pynicotine/slskmessages.py`).

// MARK: Server messages (u32 code)

enum SlskServerCode: UInt32 {
    case login = 1
    case setWaitPort = 2
    case getPeerAddress = 3
    case watchUser = 5
    case unwatchUser = 6
    case getUserStatus = 7
    case connectToPeer = 18
    case messageUser = 22
    case messageAcked = 23
    case fileSearch = 26
    case setStatus = 28
    case ping = 32
    case sharedFoldersFiles = 35
    case getUserStats = 36
    case relogged = 41
    case haveNoParent = 71
    case embeddedMessage = 93
    case acceptChildren = 100
    case possibleParents = 102
    case wishlistSearch = 103
    case wishlistInterval = 104
    case branchLevel = 126
    case branchRoot = 127
    case cantConnectToPeer = 1001
}

enum SlskServerMessage {
    private static func frame(_ code: SlskServerCode, _ body: SlskWriter) -> Data {
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count + 4))
        framed.u32(code.rawValue)
        return framed.data + body.data
    }

    /// Code 1. Version/minor mirror Nicotine+ 3.3.10 (160 / 2); the hash is
    /// MD5(username + password) as lowercase hex.
    static func login(username: String, password: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        body.string(password)
        body.u32(160)
        let digest = Insecure.MD5.hash(data: Data((username + password).utf8))
        body.string(digest.map { String(format: "%02x", $0) }.joined())
        body.u32(2)
        return frame(.login, body)
    }

    /// Code 2. Nicotine+ sends just the port; the server also accepts SoulseekQt's longer form.
    static func setWaitPort(_ port: UInt16) -> Data {
        var body = SlskWriter()
        body.u32(UInt32(port))
        return frame(.setWaitPort, body)
    }

    /// Code 3. Asks for a user's IP and port so we can dial them directly.
    static func getPeerAddress(username: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        return frame(.getPeerAddress, body)
    }

    /// Code 18, sent: asks the server to relay a connection request, so the peer
    /// dials us and pierces with our token when we can't reach them directly.
    static func connectToPeer(token: UInt32, username: String, connectionType: String) -> Data {
        var body = SlskWriter()
        body.u32(token)
        body.string(username)
        body.string(connectionType)
        return frame(.connectToPeer, body)
    }

    /// Code 1001, sent: we couldn't answer a peer's indirect connection request (their
    /// `ConnectToPeer`), so they can stop waiting for our pierce.
    static func cantConnectToPeer(token: UInt32, username: String) -> Data {
        var body = SlskWriter()
        body.u32(token)
        body.string(username)
        return frame(.cantConnectToPeer, body)
    }

    /// Code 26. Lone "-" words are dropped, as in Nicotine+.
    static func fileSearch(token: UInt32, query: String) -> Data {
        var body = SlskWriter()
        body.u32(token)
        body.legacyString(query.split(separator: " ").filter { $0 != "-" }.joined(separator: " "))
        return frame(.fileSearch, body)
    }

    /// Code 103: like a file search, but for saved searches the client repeats on the interval
    /// the server gives it (code 104).
    static func wishlistSearch(token: UInt32, query: String) -> Data {
        var body = SlskWriter()
        body.u32(token)
        body.legacyString(query.split(separator: " ").filter { $0 != "-" }.joined(separator: " "))
        return frame(.wishlistSearch, body)
    }

    /// Code 28. 1 = away, 2 = online.
    static func setStatus(online: Bool) -> Data {
        var body = SlskWriter()
        body.u32(online ? 2 : 1)
        return frame(.setStatus, body)
    }

    /// Code 32. Sent periodically so a dead server connection is noticed.
    static func ping() -> Data {
        frame(.ping, SlskWriter())
    }

    /// Code 35. Tells the server how much we share (shown to other users).
    static func sharedFoldersFiles(folders: UInt32, files: UInt32) -> Data {
        var body = SlskWriter()
        body.u32(folders)
        body.u32(files)
        return frame(.sharedFoldersFiles, body)
    }

    /// Code 71. True asks the server for `PossibleParents` on the distributed network;
    /// false says we found one.
    static func haveNoParent(_ noParent: Bool) -> Data {
        var body = SlskWriter()
        body.bool(noParent)
        return frame(.haveNoParent, body)
    }

    /// Code 100. Whether we take distributed children (susurrus stays a leaf: false).
    static func acceptChildren(_ enabled: Bool) -> Data {
        var body = SlskWriter()
        body.bool(enabled)
        return frame(.acceptChildren, body)
    }

    /// Code 126. Our generation within the distributed branch (parent's level + 1).
    static func branchLevel(_ level: UInt32) -> Data {
        var body = SlskWriter()
        body.u32(level)
        return frame(.branchLevel, body)
    }

    /// Code 127. The username at the root of our distributed branch.
    static func branchRoot(_ username: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        return frame(.branchRoot, body)
    }

    /// Code 22, sent: string username, string message. The server holds it for an offline
    /// recipient and delivers it when they next log in.
    static func messageUser(username: String, message: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        body.string(message)
        return frame(.messageUser, body)
    }

    /// Code 23: u32 message ID. Without it the server sends the message again at every login.
    static func messageAcked(id: UInt32) -> Data {
        var body = SlskWriter()
        body.u32(id)
        return frame(.messageAcked, body)
    }

    /// Code 5: string username. The reply carries the user's status and stats; afterwards
    /// the server sends a `GetUserStatus` whenever their status changes.
    static func watchUser(_ username: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        return frame(.watchUser, body)
    }

    /// Code 6: string username. Stops the status updates `WatchUser` started; no reply.
    static func unwatchUser(_ username: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        return frame(.unwatchUser, body)
    }

    /// Code 7, sent: string username. Answered with the user's current status.
    static func getUserStatus(_ username: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        return frame(.getUserStatus, body)
    }

    /// Code 36, sent: string username. Answered with the user's current stats.
    static func getUserStats(_ username: String) -> Data {
        var body = SlskWriter()
        body.string(username)
        return frame(.getUserStats, body)
    }
}

/// User status codes: 0 offline, 1 away, 2 online.
enum SlskUserStatus: UInt32, Sendable, Codable {
    case offline = 0
    case away = 1
    case online = 2
}

/// Code 22, received: u32 ID, u32 timestamp (Unix seconds), string username, string message,
/// bool new. "New" is false when the server is re-sending a message that waited for us while
/// we were offline (or that we never acknowledged).
struct SlskPrivateMessage: Sendable, Equatable {
    var id: UInt32
    var timestamp: Date
    var username: String
    var message: String
    var isNew: Bool

    init(id: UInt32, timestamp: Date, username: String, message: String, isNew: Bool) {
        self.id = id
        self.timestamp = timestamp
        self.username = username
        self.message = message
        self.isNew = isNew
    }

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        id = try reader.u32()
        timestamp = Date(timeIntervalSince1970: TimeInterval(try reader.u32()))
        username = try reader.string()
        message = try reader.string()
        isNew = (try? reader.bool()) ?? true
    }
}

/// What the server tells us about a user's activity (codes 5 and 36).
struct SlskUserStats: Sendable, Equatable {
    /// Average upload speed, bytes/s.
    var averageSpeed: UInt32
    /// Uploaded files (rolls over after a while, per the spec).
    var uploadCount: UInt32
    var files: UInt32
    var folders: UInt32

    init(averageSpeed: UInt32, uploadCount: UInt32, files: UInt32, folders: UInt32) {
        self.averageSpeed = averageSpeed
        self.uploadCount = uploadCount
        self.files = files
        self.folders = folders
    }

    /// u32 avgspeed, u32 uploadnum, u32 unknown, u32 files, u32 dirs — shared by both replies.
    fileprivate init(reading reader: inout SlskReader) throws {
        averageSpeed = try reader.u32()
        uploadCount = try reader.u32()
        _ = try reader.u32()  // unknown
        files = try reader.u32()
        folders = try reader.u32()
    }
}

/// Code 36, received: string username, then the stats.
struct SlskUserStatsReply {
    var username: String
    var stats: SlskUserStats

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        username = try reader.string()
        stats = try SlskUserStats(reading: &reader)
    }
}

/// Code 7, received: string username, u32 status, bool privileged.
struct SlskUserStatusReply {
    var username: String
    var status: SlskUserStatus
    var privileged: Bool

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        username = try reader.string()
        status = SlskUserStatus(rawValue: try reader.u32()) ?? .offline
        privileged = (try? reader.bool()) ?? false
    }
}

/// Code 5, received: string username, bool exists, and when the user exists u32 status,
/// the stats, and (for away/online users) a country code we don't use.
struct SlskWatchUserReply {
    var username: String
    var exists: Bool
    var status: SlskUserStatus
    var stats: SlskUserStats?

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        username = try reader.string()
        exists = try reader.bool()
        guard exists else {
            status = .offline
            stats = nil
            return
        }
        status = SlskUserStatus(rawValue: try reader.u32()) ?? .offline
        stats = try SlskUserStats(reading: &reader)
        // string country code follows for away/online users; not needed.
    }
}

/// Code 26, received: a search the server delivers to us directly (outside the
/// distributed network — user and room searches, or when we're treated as a root).
struct SlskServerSearchRequest {
    var username: String
    var token: UInt32
    var query: String

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        username = try reader.string()
        token = try reader.u32()
        query = try reader.string()
    }
}

/// Code 102: ten candidate distributed parents.
struct SlskPossibleParents {
    var parents: [(username: String, host: String, port: UInt16)] = []

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        for _ in 0 ..< (try reader.u32()) {
            let username = try reader.string()
            let host = try reader.ipv4()
            let port = UInt16(exactly: try reader.u32()) ?? 0
            parents.append((username, host, port))
        }
    }
}

/// Code 93: a distributed message delivered over the server connection (we're being
/// treated as a branch root). The payload is a distributed message without its frame.
struct SlskEmbeddedMessage {
    var distributedCode: UInt8
    var payload: Data

    init(parsing data: Data) throws {
        var reader = SlskReader(data)
        distributedCode = try reader.u8()
        payload = Data(data.dropFirst(1))
    }
}

// MARK: Distributed messages (u8 code, over `D` connections)

/// What a distributed parent sends us. As a leaf (no children) we only consume these.
enum SlskDistribMessage {
    case search(username: String, token: UInt32, query: String)
    case branchLevel(Int32)
    case branchRoot(String)
    case embedded(code: UInt8, payload: Data)
    case other(code: UInt8)

    static let searchCode: UInt8 = 3

    static func parse(_ frame: Data) throws -> SlskDistribMessage {
        var reader = SlskReader(frame)
        switch try reader.u8() {
        case 3:
            return try parseSearch(Data(frame.dropFirst(1)))
        case 4:
            return .branchLevel(Int32(bitPattern: try reader.u32()))
        case 5:
            return .branchRoot(try reader.string())
        case 93:
            let code = try reader.u8()
            return .embedded(code: code, payload: Data(frame.dropFirst(2)))
        case let code:
            return .other(code: code)
        }
    }

    /// The body of a DistribSearch (code 3), as found in both `D` frames and embedded messages.
    static func parseSearch(_ body: Data) throws -> SlskDistribMessage {
        var reader = SlskReader(body)
        _ = try reader.u32()  // unknown
        let username = try reader.string()
        let token = try reader.u32()
        let query = try reader.string()
        return .search(username: username, token: token, query: query)
    }
}

/// Code 1 reply.
struct SlskLoginReply {
    var success: Bool
    var greeting: String  // MOTD on success, failure reason otherwise
    var ownIP: String?

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        success = try reader.bool()
        if success {
            greeting = try reader.string()
            ownIP = try reader.ipv4()
        } else {
            greeting = try reader.string()
            ownIP = nil
        }
    }
}

/// Code 3 reply. Port 0 means the user is offline or unreachable directly.
struct SlskPeerAddressReply {
    var username: String
    var host: String
    var port: UInt16

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        username = try reader.string()
        host = try reader.ipv4()
        port = UInt16(exactly: try reader.u32()) ?? 0
        // u32 unknown and the obfuscated port follow; not needed.
    }
}

/// Code 18, received: another user wants us to connect out to them
/// (they couldn't reach us directly).
struct SlskConnectToPeer {
    var username: String
    var connectionType: String  // "P", "F" or "D"
    var host: String
    var port: UInt16
    var token: UInt32

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        username = try reader.string()
        connectionType = try reader.string()
        host = try reader.ipv4()
        let rawPort = try reader.u32()
        guard let port = UInt16(exactly: rawPort), port > 0 else {
            throw SlskError(message: "bad peer port \(rawPort)")
        }
        self.port = port
        token = try reader.u32()
        // privileged bool, unknown u32 and obfuscated port follow; not needed.
    }
}

// MARK: Peer init messages (u8 code)

enum SlskPeerInit {
    static let pierceFirewallCode: UInt8 = 0
    static let peerInitCode: UInt8 = 1

    private static func frame(_ body: SlskWriter) -> Data {
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count))
        return framed.data + body.data
    }

    /// Init code 0: completes an indirect connection; the token comes from ConnectToPeer.
    static func pierceFirewall(token: UInt32) -> Data {
        var body = SlskWriter()
        body.u8(pierceFirewallCode)
        body.u32(token)
        return frame(body)
    }

    /// Init code 1: opens a direct connection; the token is always 0.
    static func peerInit(username: String, connectionType: String) -> Data {
        var body = SlskWriter()
        body.u8(peerInitCode)
        body.string(username)
        body.string(connectionType)
        body.u32(0)
        return frame(body)
    }

    enum Incoming {
        case peerInit(username: String, connectionType: String)
        case pierceFirewall(token: UInt32)
    }

    static func parse(_ payload: Data) throws -> Incoming {
        var reader = SlskReader(payload)
        switch try reader.u8() {
        case pierceFirewallCode:
            return .pierceFirewall(token: try reader.u32())
        case peerInitCode:
            return .peerInit(username: try reader.string(), connectionType: try reader.string())
        case let code:
            throw SlskError(message: "unknown peer init code \(code)")
        }
    }
}

// MARK: Peer messages (u32 code)

enum SlskPeerCode: UInt32 {
    case sharedFileListRequest = 4
    case sharedFileListResponse = 5
    case fileSearchResponse = 9
    case userInfoRequest = 15
    case userInfoResponse = 16
    case transferRequest = 40
    case transferResponse = 41
    case queueUpload = 43
    case placeInQueueResponse = 44
    case uploadFailed = 46
    case uploadDenied = 50
    case placeInQueueRequest = 51
}

/// Builders for the peer messages we send over `P` connections.
enum SlskPeerMessage {
    private static func frame(_ code: SlskPeerCode, _ body: SlskWriter) -> Data {
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count + 4))
        framed.u32(code.rawValue)
        return framed.data + body.data
    }

    /// Peer code 43: asks the peer to queue an upload of `path` to us. When ready,
    /// they answer with a `TransferRequest`.
    static func queueUpload(path: String) -> Data {
        var body = SlskWriter()
        body.string(path)
        return frame(.queueUpload, body)
    }

    /// Peer code 41, upload-response form: accepts or rejects the peer's `TransferRequest`.
    static func transferResponse(token: UInt32, allowed: Bool, reason: String = "") -> Data {
        var body = SlskWriter()
        body.u32(token)
        body.bool(allowed)
        if !allowed { body.string(reason) }
        return frame(.transferResponse, body)
    }

    /// Peer code 40, upload form: tells a downloader we're ready to send `path`.
    static func transferRequest(uploadToken token: UInt32, path: String, size: UInt64) -> Data {
        var body = SlskWriter()
        body.u32(1)  // direction: upload
        body.u32(token)
        body.string(path)
        body.u64(size)
        return frame(.transferRequest, body)
    }

    /// Peer code 9: our matches for someone's search. The body is zlib-wrapped.
    static func fileSearchResponse(
        username: String, token: UInt32, files: [SlskSharedFile],
        slotFree: Bool, averageSpeed: UInt32, queueLength: UInt32
    ) throws -> Data {
        var body = SlskWriter()
        body.string(username)
        body.u32(token)
        body.u32(UInt32(files.count))
        for file in files { body.fileInfo(file) }
        body.bool(slotFree)
        body.u32(averageSpeed)
        body.u32(queueLength)
        body.u32(0)  // unknown, official clients send 0

        var framed = SlskWriter()
        let compressed = try SlskZlib.deflate(body.data)
        framed.u32(UInt32(compressed.count + 4))
        framed.u32(SlskPeerCode.fileSearchResponse.rawValue)
        return framed.data + compressed
    }

    /// Peer code 5: our share list for a browse. The zlib payload is prebuilt per scan.
    static func sharedFileListResponse(browsePayload: Data) -> Data {
        var framed = SlskWriter()
        framed.u32(UInt32(browsePayload.count + 4))
        framed.u32(SlskPeerCode.sharedFileListResponse.rawValue)
        return framed.data + browsePayload
    }

    /// Peer code 4: ask a peer for their share list.
    static func sharedFileListRequest() -> Data {
        frame(.sharedFileListRequest, SlskWriter())
    }

    /// Peer code 15: ask a peer about themselves. Empty body.
    static func userInfoRequest() -> Data {
        frame(.userInfoRequest, SlskWriter())
    }

    /// Peer code 16: who we are, for the user-info pane of other clients. string description,
    /// bool has picture (+ bytes picture), u32 total upload slots, u32 queue size, bool slots
    /// free, then the optional u32 upload permission (1 = everyone may upload to us; susurrus
    /// takes no uploads, but that's what official clients send by default).
    static func userInfoResponse(description: String, picture: Data? = nil, uploadSlots: UInt32,
                                 queueLength: UInt32, slotFree: Bool) -> Data {
        var body = SlskWriter()
        body.string(description)
        if let picture, !picture.isEmpty {
            body.bool(true)
            body.bytes(picture)
        } else {
            body.bool(false)
        }
        body.u32(uploadSlots)
        body.u32(queueLength)
        body.bool(slotFree)
        body.u32(1)
        return frame(.userInfoResponse, body)
    }

    /// Peer code 50: we're not uploading `path` to this peer.
    static func uploadDenied(path: String, reason: String) -> Data {
        var body = SlskWriter()
        body.string(path)
        body.string(reason)
        return frame(.uploadDenied, body)
    }

    /// Peer code 46: our upload of `path` broke.
    static func uploadFailed(path: String) -> Data {
        var body = SlskWriter()
        body.string(path)
        return frame(.uploadFailed, body)
    }

    /// Peer code 44: where `path` sits in our upload queue.
    static func placeInQueueResponse(path: String, place: UInt32) -> Data {
        var body = SlskWriter()
        body.string(path)
        body.u32(place)
        return frame(.placeInQueueResponse, body)
    }
}

/// Peer code 16, received: what a user says about themselves. The trailing upload permission
/// is optional (SoulseekQt leaves it out).
struct SlskUserInfo: Sendable, Equatable {
    var description: String
    var picture: Data?
    var uploadSlots: UInt32
    var queueLength: UInt32
    var slotFree: Bool

    init(description: String, picture: Data?, uploadSlots: UInt32, queueLength: UInt32, slotFree: Bool) {
        self.description = description
        self.picture = picture
        self.uploadSlots = uploadSlots
        self.queueLength = queueLength
        self.slotFree = slotFree
    }

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        description = try reader.string()
        picture = try reader.bool() ? try reader.bytes() : nil
        uploadSlots = try reader.u32()
        queueLength = try reader.u32()
        slotFree = try reader.bool()
    }
}

/// Peer code 41, received in the upload direction: the downloader accepts or rejects
/// our `TransferRequest`.
struct SlskTransferResponse {
    var token: UInt32
    var allowed: Bool
    var reason: String

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        token = try reader.u32()
        allowed = try reader.bool()
        reason = allowed ? "" : ((try? reader.string()) ?? "")
    }
}

/// Peer code 43, received: a peer wants us to upload `path` to them.
struct SlskQueueUploadRequest {
    var path: String

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        path = try reader.string()
    }
}

/// Peer code 51, received: the peer asks where their file sits in our queue.
struct SlskPlaceInQueueRequest {
    var path: String

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        path = try reader.string()
    }
}

/// Peer code 40: the peer is ready to transfer. Direction 1 means they want to upload to us;
/// the token identifies the coming `F` connection.
struct SlskTransferRequest {
    var direction: UInt32
    var token: UInt32
    var path: String
    var size: UInt64

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        direction = try reader.u32()
        token = try reader.u32()
        path = try reader.string()
        // 0 when absent or implausible: the size from the search result stands.
        size = direction == 1 ? (try reader.fileSize() ?? 0) : 0
    }
}

/// Peer code 50: the peer rejected a queued upload. The reason "Queued" is not fatal —
/// it just restates that we're waiting for a slot.
struct SlskUploadDenied {
    var path: String
    var reason: String

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        path = try reader.string()
        reason = try reader.string()
    }
}

/// Peer code 46: an active upload's file connection broke on the peer's end.
struct SlskUploadFailed {
    var path: String

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        path = try reader.string()
    }
}

/// Peer code 44: our place in the peer's upload queue.
struct SlskPlaceInQueueResponse {
    var path: String
    var place: UInt32

    init(parsing payload: Data) throws {
        var reader = SlskReader(payload)
        path = try reader.string()
        place = try reader.u32()
    }
}

/// One file from a search response, flattened for display.
struct SlskSearchResult: Identifiable, Sendable {
    /// Unique only within one response batch; `SoulseekModel` renumbers on append.
    var id: Int
    var username: String
    /// Full remote path, backslash-separated (e.g. `@@abcde\Music\Artist\01 Song.flac`).
    var path: String
    var size: UInt64
    var bitrate: Int?
    var isVBR: Bool
    var durationSeconds: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var slotFree: Bool
    /// Peer's average upload speed, bytes/s.
    var averageSpeed: UInt32
    var queueLength: UInt32

    var fileName: String { String(path.split(separator: "\\").last ?? "") }
    var folder: String { path.split(separator: "\\").dropLast().suffix(2).joined(separator: "\\") }
    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
    var isLossless: Bool { ["flac", "alac", "wav", "aiff", "aif", "ape", "wv"].contains(fileExtension) }
}

/// Peer code 9: a batch of search matches from one user. The whole payload is one zlib stream.
struct SlskSearchResponse {
    var username: String
    var token: UInt32
    var results: [SlskSearchResult]

    /// The search token, read from the start of the payload without inflating the rest — so
    /// answers to searches nobody is waiting for cost next to nothing.
    static func token(in payload: Data) -> UInt32? {
        // A username long enough to push the token past this is no real username.
        guard let head = try? SlskZlib.inflatePrefix(payload, count: 1024) else { return nil }
        var reader = SlskReader(head)
        _ = try? reader.string()
        return try? reader.u32()
    }

    init(parsing payload: Data) throws {
        var reader = SlskReader(try SlskZlib.inflate(payload))
        username = try reader.string()
        token = try reader.u32()

        struct File {
            var path: String
            var size: UInt64
            var attributes: [UInt32: UInt32]
        }
        func fileList() throws -> [File] {
            let count = try reader.u32()
            var files: [File] = []
            files.reserveCapacity(min(Int(count), 4096))
            for _ in 0 ..< count {
                _ = try reader.u8()  // always 1
                let path = try reader.string()
                let size = try reader.fileSize()
                _ = try reader.string()  // extension; blank from SoulseekQt
                var attributes: [UInt32: UInt32] = [:]
                for _ in 0 ..< (try reader.u32()) {
                    attributes[try reader.u32()] = try reader.u32()
                }
                // A file with an impossible size is garbage; leave it out.
                if let size { files.append(File(path: path, size: size, attributes: attributes)) }
            }
            return files
        }

        let files = try fileList()
        // Trailing fields are optional in old clients; results without them stay usable.
        let slotFree = (try? reader.bool()) ?? false
        let averageSpeed = (try? reader.u32()) ?? 0
        let queueLength = (try? reader.u32()) ?? 0
        // u32 unknown and the privately-shared list may follow; ignored.

        let username = username
        results = files.enumerated().map { index, file in
            SlskSearchResult(
                id: index, username: username, path: file.path, size: file.size, attributes: file.attributes,
                slotFree: slotFree, averageSpeed: averageSpeed, queueLength: queueLength
            )
        }
    }
}

extension SlskSearchResult {
    /// Attribute codes: 0 bitrate, 1 duration, 2 VBR, 4 sample rate, 5 bit depth.
    init(id: Int, username: String, path: String, size: UInt64, attributes: [UInt32: UInt32],
         slotFree: Bool, averageSpeed: UInt32, queueLength: UInt32) {
        self.init(
            id: id,
            username: username,
            path: path,
            size: size,
            bitrate: attributes[0].map(Int.init),
            isVBR: attributes[2] == 1,
            durationSeconds: attributes[1].map(Int.init),
            sampleRate: attributes[4].map(Int.init),
            bitDepth: attributes[5].map(Int.init),
            slotFree: slotFree,
            averageSpeed: averageSpeed,
            queueLength: queueLength
        )
    }
}

/// Peer code 5: a user's whole share, folder by folder. The payload is one zlib stream:
/// u32 folder count, then per folder its path and file records (as in search results), then
/// u32 unknown and an optional list of buddy-only folders (ignored: those downloads are denied).
struct SlskSharedFileList: Sendable {
    struct Folder: Sendable, Identifiable {
        /// Backslash-separated remote path.
        var path: String
        var files: [SlskSearchResult]
        var id: String { path }
    }

    var username: String
    var folders: [Folder]

    var fileCount: Int { folders.reduce(0) { $0 + $1.files.count } }

    init(parsing payload: Data, username: String) throws {
        var reader = SlskReader(try SlskZlib.inflate(payload, limit: SlskZlib.maxShareListSize))
        self.username = username
        var folders: [Folder] = []
        var nextID = 0
        let folderCount = try reader.u32()
        folders.reserveCapacity(min(Int(folderCount), 50_000))
        for _ in 0 ..< folderCount {
            let path = try reader.string()
            let fileCount = try reader.u32()
            var files: [SlskSearchResult] = []
            files.reserveCapacity(min(Int(fileCount), 4096))
            for _ in 0 ..< fileCount {
                _ = try reader.u8()  // always 1
                let name = try reader.string()
                let size = try reader.fileSize()
                _ = try reader.string()  // extension
                var attributes: [UInt32: UInt32] = [:]
                for _ in 0 ..< (try reader.u32()) {
                    attributes[try reader.u32()] = try reader.u32()
                }
                guard let size else { continue }  // an impossible size: garbage, left out
                // Clients send bare file names here; a few send the whole path.
                let fullPath = name.contains("\\") ? name : path + "\\" + name
                files.append(SlskSearchResult(
                    id: nextID, username: username, path: fullPath, size: size, attributes: attributes,
                    slotFree: false, averageSpeed: 0, queueLength: 0))
                nextID += 1
            }
            folders.append(Folder(path: path, files: files))
        }
        self.folders = folders
    }
}
