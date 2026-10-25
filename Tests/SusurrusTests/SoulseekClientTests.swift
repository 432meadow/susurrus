import CoreServices
import Foundation
import Network
import Testing
@testable import Susurrus

/// End-to-end tests of the client against a mock Soulseek server on localhost:
/// login handshake, search, and downloads run the way the real network runs them —
/// results and files arrive from a "peer" (the mock's second listener) over direct
/// peer connections, including the raw-byte `F` connection for file transfers.
@Suite struct SoulseekClientLoopbackTests {
    @Test func logsInSearchesAndReceivesPeerResults() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }

        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!

        let client = SoulseekClient(
            username: "tester",
            password: "secret",
            server: (host: "127.0.0.1", port: mock.port)
        ) { continuation.yield($0) }

        try await client.connect()
        try await client.search(token: 4242, query: "test query")

        var results: [SlskSearchResult] = []
        var sawConnected = false
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            continuation.finish()
        }
        for await event in events {
            switch event {
            case .connected(let user, let greeting):
                sawConnected = true
                #expect(user == "tester")
                #expect(greeting == "Welcome to the mock")
            case .searchResults(let token, let batch):
                #expect(token == 4242)
                results = batch
                continuation.finish()
            case .disconnected(let reason, _):
                Issue.record("unexpected disconnect: \(reason ?? "-")")
                continuation.finish()
            default:
                break
            }
        }
        deadline.cancel()
        await client.disconnect()

        #expect(sawConnected)
        #expect(mock.failures.isEmpty)
        #expect(mock.receivedQuery == "test query")
        #expect(results.count == 1)
        #expect(results.first?.fileName == "01 Song.flac")
        #expect(results.first?.username == "mockpeer")
    }

    @Test func downloadsAFileFromAPeer() async throws {
        let fileData = Data((0 ..< 100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(fileData))
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: UInt64(fileData.count), in: folder)
        let finalState = try await runDownload(request, against: mock)

        #expect(finalState == .finished(request.destinationURL))
        #expect(try Data(contentsOf: request.destinationURL) == fileData)
        #expect(!FileManager.default.fileExists(atPath: request.partURL.path))
        #expect(mock.receivedOffset == 0)
        #expect(mock.failures.isEmpty)
        // Marked as downloaded, like a browser's downloads.
        let quarantine = try request.destinationURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "susurrus")
    }

    /// A finished download never replaces a file already at its destination.
    @Test func finishedDownloadsDontOverwriteExistingFiles() async throws {
        let fileData = Data((0 ..< 30_000).map { UInt8(truncatingIfNeeded: $0 &* 3) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(fileData))
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: UInt64(fileData.count), in: folder)
        try FileManager.default.createDirectory(at: request.destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: request.destinationURL)

        let finalState = try await runDownload(request, against: mock)

        let landed = request.destinationURL.deletingLastPathComponent().appendingPathComponent("01 Song 2.flac")
        #expect(finalState == .finished(landed))
        #expect(try Data(contentsOf: landed) == fileData)
        #expect(try Data(contentsOf: request.destinationURL) == Data("already here".utf8))
    }

    /// Two sources of the same file keep separate part files: another user's leftover bytes are
    /// neither resumed nor touched.
    @Test func doesNotResumeAnotherUsersPartFile() async throws {
        let fileData = Data((0 ..< 50_000).map { UInt8(truncatingIfNeeded: $0 &* 29) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(fileData))
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: UInt64(fileData.count), in: folder)
        let otherPart = SoulseekModel.partialFileURL(username: "someoneelse", remotePath: request.remotePath, downloadsFolder: folder)
        #expect(otherPart != request.partURL)
        try FileManager.default.createDirectory(at: otherPart.deletingLastPathComponent(), withIntermediateDirectories: true)
        let junk = Data(repeating: 0xEE, count: 20_000)
        try junk.write(to: otherPart)

        let finalState = try await runDownload(request, against: mock)

        #expect(finalState == .finished(request.destinationURL))
        #expect(mock.receivedOffset == 0)
        #expect(try Data(contentsOf: request.destinationURL) == fileData)
        #expect(try Data(contentsOf: otherPart) == junk)
    }

    /// A part file bigger than the file can't be this file's: the download starts over.
    @Test func restartsWhenThePartFileIsTooLarge() async throws {
        let fileData = Data((0 ..< 40_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(fileData))
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: UInt64(fileData.count), in: folder)
        try FileManager.default.createDirectory(at: request.partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 60_000).write(to: request.partURL)

        let finalState = try await runDownload(request, against: mock)

        #expect(finalState == .finished(request.destinationURL))
        #expect(mock.receivedOffset == 0)
        #expect(try Data(contentsOf: request.destinationURL) == fileData)
    }

    @Test func resumesFromAPartFile() async throws {
        let fileData = Data((0 ..< 80_000).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(fileData))
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: UInt64(fileData.count), in: folder)
        try FileManager.default.createDirectory(
            at: request.partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileData.prefix(30_000).write(to: request.partURL)

        let finalState = try await runDownload(request, against: mock)

        #expect(finalState == .finished(request.destinationURL))
        #expect(mock.receivedOffset == 30_000)
        #expect(try Data(contentsOf: request.destinationURL) == fileData)
        #expect(mock.failures.isEmpty)
    }

    @Test func deniedDownloadsFail() async throws {
        let mock = try await MockSoulseekServer(peerBehavior: .deny(reason: "File not shared."))
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: 1000, in: folder)
        let finalState = try await runDownload(request, against: mock)

        #expect(finalState == .failed("File not shared."))
        #expect(!FileManager.default.fileExists(atPath: request.destinationURL.path))
        #expect(mock.failures.isEmpty)
    }

    /// The serving side, end to end: a shared folder is scanned, a search arrives from the
    /// server, the client answers the searcher over a peer connection, the searcher queues the
    /// file, and the client uploads it over an `F` connection.
    @Test func answersSearchesAndUploadsSharedFiles() async throws {
        let mock = try await MockSoulseekServer()
        mock.requestUploadOnResult = true
        defer { mock.stop() }

        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let album = folder.appendingPathComponent("Album")
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
        let fileData = Data((0 ..< 60_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let fileURL = album.appendingPathComponent("01 Song.mp3")
        try fileData.write(to: fileURL)

        let snapshot = SlskShareScanner.scan(folder: folder) { _ in
            SlskFileAttributes(bitrate: 320, durationSeconds: 245, sampleRate: nil, bitDepth: nil)
        }
        #expect(snapshot.files.count == 1)

        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!

        let client = SoulseekClient(
            username: "tester",
            password: "secret",
            server: (host: "127.0.0.1", port: mock.port)
        ) { continuation.yield($0) }

        await client.updateShares(snapshot)
        try await client.connect()
        try await mock.deliverSearch(from: "wanter", token: 99, query: "album song")

        var uploadFinished = false
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            continuation.finish()
        }
        for await event in events {
            if case .uploadState(_, .finished) = event {
                uploadFinished = true
                continuation.finish()
            }
            if case .uploadState(_, .failed(let reason)) = event {
                Issue.record("upload failed: \(reason)")
                continuation.finish()
            }
        }
        deadline.cancel()
        await client.disconnect()

        #expect(uploadFinished)
        #expect(mock.failures.isEmpty)

        let response = try #require(mock.searchResponse)
        #expect(response.username == "tester")
        #expect(response.token == 99)
        #expect(response.results.count == 1)
        #expect(response.results.first?.fileName == "01 Song.mp3")
        #expect(response.results.first?.bitrate == 320)
        #expect(response.results.first?.durationSeconds == 245)

        #expect(mock.uploadOffer?.path == snapshot.files[0].virtualPath)
        #expect(mock.uploadOffer?.size == UInt64(fileData.count))
        #expect(mock.receivedFile == fileData)
    }

    /// Searches that match nothing — or queue requests for unshared paths — are not served.
    @Test func deniesUnsharedUploadsAndIgnoresNonMatches() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }

        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!
        let client = SoulseekClient(
            username: "tester",
            password: "secret",
            server: (host: "127.0.0.1", port: mock.port)
        ) { continuation.yield($0) }
        continuation.finish()
        _ = events

        try await client.connect()
        // Nothing shared: a search should produce no response at all.
        try await mock.deliverSearch(from: "wanter", token: 7, query: "anything at all")
        try await Task.sleep(for: .milliseconds(600))
        #expect(mock.searchResponse == nil)
        await client.disconnect()
    }

    @Test func browsesAPeersShare() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) { _ in }
        try await client.connect()
        let list = try await client.browse(user: "mockpeer")
        await client.disconnect()

        #expect(list.username == "mockpeer")
        #expect(list.folders.map(\.path) == [#"@@mock\Artist\Album"#, #"@@mock\Artist\Single"#])
        #expect(list.folders[0].files.map(\.path) == [#"@@mock\Artist\Album\01 Song.flac"#, #"@@mock\Artist\Album\02 Other.flac"#])
        #expect(list.folders[1].files.first?.bitrate == 320)
        #expect(mock.failures.isEmpty)
    }

    @Test func wishlistSearchesUseTheirOwnCodeAndTheServerSetsTheInterval() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) {
            continuation.yield($0)
        }
        try await client.connect()
        try await client.wishlistSearch(token: 4242, query: "rare album")

        var interval: Int?
        var resultToken: UInt32?
        let deadline = Task {
            try await Task.sleep(for: .seconds(10))
            continuation.finish()
        }
        for await event in events {
            if case .wishlistInterval(let seconds) = event { interval = seconds }
            if case .searchResults(let token, _) = event { resultToken = token }
            if interval != nil, resultToken != nil { continuation.finish() }
        }
        deadline.cancel()
        await client.disconnect()

        #expect(interval == 600)
        #expect(resultToken == 4242)
        #expect(mock.receivedWishlistQuery == "rare album")
        #expect(mock.receivedQuery == nil, "not sent as a regular search")
    }

    @Test func blockedUsersGetNoSearchResults() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(count: 1000).write(to: folder.appendingPathComponent("Album Song.mp3"))
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) { _ in }
        await client.updateShares(SlskShareScanner.scan(folder: folder) { _ in nil })
        await client.updateBlockedUsers(["wanter"])
        try await client.connect()
        try await mock.deliverSearch(from: "wanter", token: 5, query: "album song")
        try await Task.sleep(for: .milliseconds(800))
        #expect(mock.searchResponse == nil)
        await client.disconnect()
    }

    /// 60 KB at 30 KB/s: the first chunk goes straight away, the rest are paced, so the upload
    /// takes well over a second (it takes milliseconds unlimited).
    @Test func uploadsRespectTheSpeedLimit() async throws {
        let mock = try await MockSoulseekServer()
        mock.requestUploadOnResult = true
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileData = Data((0 ..< 60_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try fileData.write(to: folder.appendingPathComponent("Album Song.mp3"))

        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) {
            continuation.yield($0)
        }
        await client.updateShares(SlskShareScanner.scan(folder: folder) { _ in nil })
        await client.setUploadLimit(30_000)
        try await client.connect()
        try await mock.deliverSearch(from: "wanter", token: 9, query: "album song")

        var started: ContinuousClock.Instant?
        var elapsed: Duration?
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            continuation.finish()
        }
        for await event in events {
            if case .uploadState(_, .transferring) = event, started == nil { started = .now }
            if case .uploadState(_, .finished) = event {
                elapsed = started.map { .now - $0 }
                continuation.finish()
            }
        }
        deadline.cancel()
        await client.disconnect()

        let time = try #require(elapsed)
        #expect(time > .milliseconds(1300), "took \(time)")
        #expect(mock.receivedFile == fileData)
    }

    // MARK: Private messages

    @Test func receivesAndAcknowledgesPrivateMessages() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let (client, events, continuation) = makeClient(mock)
        try await client.connect()
        try await mock.deliverMessage(id: 501, from: "friend", text: "hello there", isNew: true)

        var received: SlskPrivateMessage?
        let deadline = finish(continuation, after: 10)
        for await event in events {
            if case .privateMessage(let message) = event {
                received = message
                continuation.finish()
            }
        }
        deadline.cancel()
        try await waitUntil { mock.ackedMessageIDs.contains(501) }
        await client.disconnect()

        let message = try #require(received)
        #expect(message.id == 501)
        #expect(message.username == "friend")
        #expect(message.message == "hello there")
        #expect(message.isNew)
        #expect(message.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(mock.ackedMessageIDs == [501])
        #expect(mock.failures.isEmpty)
    }

    @Test func sendsPrivateMessages() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) { _ in }
        try await client.connect()
        try await client.sendMessage(to: "friend", text: "got any more of that album?")
        try await waitUntil { !mock.sentMessages.isEmpty }
        await client.disconnect()

        #expect(mock.sentMessages.map(\.user) == ["friend"])
        #expect(mock.sentMessages.map(\.text) == ["got any more of that album?"])
        #expect(mock.failures.isEmpty)
    }

    /// Messages sent while we were offline arrive right after login, flagged as not new,
    /// and each one is acknowledged so the server stops resending them.
    @Test func offlineMessagesArriveAtLogin() async throws {
        let mock = try await MockSoulseekServer()
        mock.offlineMessages = [(11, "friend", "you there?"), (12, "friend", "ping me when you're back")]
        defer { mock.stop() }
        let (client, events, continuation) = makeClient(mock)
        try await client.connect()

        var received: [SlskPrivateMessage] = []
        let deadline = finish(continuation, after: 10)
        for await event in events {
            if case .privateMessage(let message) = event {
                received.append(message)
                if received.count == 2 { continuation.finish() }
            }
        }
        deadline.cancel()
        try await waitUntil { mock.ackedMessageIDs.count == 2 }
        await client.disconnect()

        #expect(received.map(\.message) == ["you there?", "ping me when you're back"])
        #expect(received.allSatisfy { !$0.isNew })
        #expect(Set(mock.ackedMessageIDs) == [11, 12])
    }

    /// A blocked user's message is acknowledged (or the server would keep resending it) but
    /// never reported.
    @Test func blockedUsersMessagesAreDropped() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let (client, events, continuation) = makeClient(mock)
        await client.updateBlockedUsers(["pest"])
        try await client.connect()
        try await mock.deliverMessage(id: 1, from: "pest", text: "buy my mixtape", isNew: true)
        try await mock.deliverMessage(id: 2, from: "friend", text: "hi", isNew: true)

        var senders: [String] = []
        let deadline = finish(continuation, after: 10)
        for await event in events {
            if case .privateMessage(let message) = event {
                senders.append(message.username)
                if message.username == "friend" { continuation.finish() }
            }
        }
        deadline.cancel()
        try await waitUntil { mock.ackedMessageIDs.count == 2 }
        await client.disconnect()

        #expect(senders == ["friend"])
        #expect(mock.ackedMessageIDs == [1, 2])
    }

    // MARK: User info

    @Test func answersUserInfoRequests() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) { _ in }
        await client.setOwnInfo(description: "susurrus on a Mac\nmostly jazz", picture: nil)
        try await client.connect()
        let info = try await mock.askClientForUserInfo()
        await client.disconnect()

        #expect(info.description == "susurrus on a Mac\nmostly jazz")
        #expect(info.picture == nil)
        #expect(info.uploadSlots == 2)
        #expect(info.queueLength == 0)
        #expect(info.slotFree)
        #expect(mock.failures.isEmpty)
    }

    @Test func blockedUsersGetNoUserInfo() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let client = SoulseekClient(username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port)) { _ in }
        await client.updateBlockedUsers(["mockpeer"])
        try await client.connect()
        await #expect(throws: SlskError.self) { try await mock.askClientForUserInfo(timeout: 1.5) }
        await client.disconnect()
    }

    /// The peer answers with its description and picture; the server with status (code 7,
    /// and the WatchUser reply) and stats (code 36, and the WatchUser reply).
    @Test func requestsUserInfoAndStats() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let (client, events, continuation) = makeClient(mock)
        try await client.connect()

        let info = try await client.userInfo(of: "mockpeer")
        #expect(info.description == "mock peer, sharing since forever")
        #expect(info.picture == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(info.uploadSlots == 3)
        #expect(info.queueLength == 7)
        #expect(!info.slotFree)

        await client.watch(user: "mockpeer")
        await client.requestStatusAndStats(of: "mockpeer")

        var statuses: [SlskUserStatus] = []
        var privileged: [Bool] = []
        var stats: [SlskUserStats] = []
        let deadline = finish(continuation, after: 10)
        for await event in events {
            switch event {
            case .userStatus(let user, let status, let isPrivileged):
                #expect(user == "mockpeer")
                statuses.append(status)
                privileged.append(isPrivileged)
            case .userStats(let user, let userStats):
                #expect(user == "mockpeer")
                stats.append(userStats)
            default:
                break
            }
            if statuses.count == 2, stats.count == 2 { continuation.finish() }
        }
        deadline.cancel()
        await client.disconnect()

        // WatchUser's reply first (online, no privilege flag), then GetUserStatus (away, privileged).
        #expect(statuses == [.online, .away])
        #expect(privileged == [false, true])
        let expected = SlskUserStats(averageSpeed: 250_000, uploadCount: 42, files: 1234, folders: 56)
        #expect(stats == [expected, expected])
        #expect(mock.watchedUsers == ["mockpeer"])
        #expect(mock.failures.isEmpty)
    }

    // MARK: Connections and deadlines

    /// An incoming connection that never says who it is gets closed at the handshake deadline.
    @Test func silentIncomingConnectionsCloseAtTheHandshakeDeadline() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        var timeouts = SoulseekClient.Timeouts()
        timeouts.handshake = 0.5
        let (client, _, _) = makeClient(mock, timeouts: timeouts)
        try await client.connect()
        try await waitUntil { mock.clientListenPort != nil }

        let silent = TCPConnection(host: "127.0.0.1", port: try #require(mock.clientListenPort))
        defer { silent.cancel() }
        try await silent.start(timeout: 5)
        let start = ContinuousClock.now
        _ = try? await silent.receive(timeout: 5)
        let elapsed = ContinuousClock.now - start
        await client.disconnect()

        #expect(elapsed > .milliseconds(400) && elapsed < .seconds(2), "closed after \(elapsed)")
    }

    /// Disconnecting closes every connection, idle ones included.
    @Test func disconnectingClosesIdleConnections() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let (client, _, _) = makeClient(mock)
        try await client.connect()
        try await waitUntil { mock.clientListenPort != nil }
        let idle = try await mock.openIdleConnection(as: "idler")
        try await Task.sleep(for: .milliseconds(300))  // the client takes it in

        let start = ContinuousClock.now
        await client.disconnect()
        _ = try? await idle.receive(timeout: 10)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(2), "closed after \(elapsed)")
    }

    /// A firewalled peer pierces the client's listener moments after the relayed request; that
    /// connection is used at once, while the direct dial is refused.
    @Test func reachesFirewalledPeersThroughTheirPierce() async throws {
        let mock = try await MockSoulseekServer()
        mock.reachability = .firewalled
        defer { mock.stop() }
        let (client, _, _) = makeClient(mock)
        try await client.connect()
        try await waitUntil { mock.clientListenPort != nil }

        let start = ContinuousClock.now
        let info = try await client.userInfo(of: "mockpeer")
        let elapsed = ContinuousClock.now - start
        await client.disconnect()

        #expect(info.description == "mock peer, sharing since forever")
        #expect(elapsed < .seconds(3), "took \(elapsed)")
        #expect(mock.failures.isEmpty)
    }

    @Test func downloadsFromFirewalledPeers() async throws {
        let fileData = Data((0 ..< 70_000).map { UInt8(truncatingIfNeeded: $0 &* 23) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(fileData))
        mock.reachability = .firewalled
        defer { mock.stop() }
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let request = downloadRequest(size: UInt64(fileData.count), in: folder)
        let start = ContinuousClock.now
        let finalState = try await runDownload(request, against: mock)
        let elapsed = ContinuousClock.now - start

        #expect(finalState == .finished(request.destinationURL))
        #expect(try Data(contentsOf: request.destinationURL) == fileData)
        #expect(elapsed < .seconds(5), "took \(elapsed)")
        #expect(mock.failures.isEmpty)
    }

    /// When the peer can't pierce either, the server says so (CantConnectToPeer) and the attempt
    /// fails right away instead of at the pierce deadline.
    @Test func cantConnectToPeerEndsTheAttemptEarly() async throws {
        let mock = try await MockSoulseekServer()
        mock.reachability = .unreachable
        defer { mock.stop() }
        let (client, _, _) = makeClient(mock)
        try await client.connect()

        let start = ContinuousClock.now
        await #expect(throws: SlskError.self) { try await client.userInfo(of: "mockpeer") }
        let elapsed = ContinuousClock.now - start
        await client.disconnect()

        #expect(elapsed < .seconds(3), "took \(elapsed)")
    }

    /// A login the server never answers fails at its deadline instead of hanging.
    @Test func unansweredLoginsTimeOut() async throws {
        let mock = try await MockSoulseekServer()
        mock.answersLogin = false
        defer { mock.stop() }
        var timeouts = SoulseekClient.Timeouts()
        timeouts.login = 1
        let (client, _, _) = makeClient(mock, timeouts: timeouts)

        let start = ContinuousClock.now
        await #expect(throws: SlskError.self) { try await client.connect() }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed > .milliseconds(900) && elapsed < .seconds(3), "took \(elapsed)")
        #expect(await client.isLoggedIn == false)
    }

    /// The account logging in elsewhere ends the session for good: no reconnecting after it.
    @Test func reloggedSessionsAreNotRetried() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let (client, events, continuation) = makeClient(mock)
        try await client.connect()
        try await mock.sendRelogged()

        var ended: (reason: String?, canReconnect: Bool)?
        let deadline = finish(continuation, after: 10)
        for await event in events {
            if case .disconnected(let reason, let canReconnect) = event {
                ended = (reason, canReconnect)
                continuation.finish()
            }
        }
        deadline.cancel()

        let session = try #require(ended)
        #expect(!session.canReconnect)
        #expect(session.reason?.contains("somewhere else") == true)
        #expect(await client.isLoggedIn == false)
    }

    /// Answers to searches the client isn't waiting for are dropped unread.
    @Test func ignoresResultsForUnknownSearches() async throws {
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let (client, events, continuation) = makeClient(mock)
        try await client.connect()
        try await waitUntil { mock.clientListenPort != nil }
        try await mock.sendSearchResult(token: 999)  // nobody searched for this
        try await client.search(token: 4242, query: "test query")

        var tokens: [UInt32] = []
        let deadline = finish(continuation, after: 10)
        for await event in events {
            guard case .searchResults(let token, _) = event else { continue }
            tokens.append(token)
            if token == 4242 {
                // Anything else would have come by now.
                Task {
                    try await Task.sleep(for: .milliseconds(500))
                    continuation.finish()
                }
            }
        }
        deadline.cancel()
        await client.disconnect()

        #expect(tokens == [4242])
    }

    /// A share list that can't be read fails the browse at once, not at the browse deadline.
    @Test func unreadableShareListsFailTheBrowseQuickly() async throws {
        let mock = try await MockSoulseekServer(peerBehavior: .corruptShareList)
        defer { mock.stop() }
        let (client, _, _) = makeClient(mock)
        try await client.connect()

        let start = ContinuousClock.now
        await #expect(throws: SlskError.self) { try await client.browse(user: "mockpeer") }
        let elapsed = ContinuousClock.now - start
        await client.disconnect()

        #expect(elapsed < .seconds(3), "took \(elapsed)")
    }

    // MARK: Helpers

    private func makeClient(
        _ mock: MockSoulseekServer, timeouts: SoulseekClient.Timeouts = .init()
    ) -> (SoulseekClient, AsyncStream<SlskEvent>, AsyncStream<SlskEvent>.Continuation) {
        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!
        let client = SoulseekClient(
            username: "tester", password: "secret", server: (host: "127.0.0.1", port: mock.port), timeouts: timeouts
        ) {
            continuation.yield($0)
        }
        return (client, events, continuation)
    }

    private func finish(_ continuation: AsyncStream<SlskEvent>.Continuation, after seconds: Double) -> Task<Void, Error> {
        Task {
            try await Task.sleep(for: .seconds(seconds))
            continuation.finish()
        }
    }

    /// Polls until `condition` holds; records an issue after `timeout`.
    private func waitUntil(timeout: Double = 5, _ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > .seconds(timeout) {
                Issue.record("timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeTempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurrus-slsk-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The request the model would make for mockpeer's `Album\01 Song.flac`.
    private func downloadRequest(size: UInt64, in folder: URL) -> SlskDownloadRequest {
        let remotePath = #"@@mock\Artist\Album\01 Song.flac"#
        let destination = SoulseekModel.localDestination(for: remotePath, downloadsFolder: folder)
        #expect(destination == folder.appendingPathComponent("Album/01 Song.flac"))
        return SlskDownloadRequest(
            id: UUID(),
            username: "mockpeer",
            remotePath: remotePath,
            size: size,
            partURL: SoulseekModel.partialFileURL(username: "mockpeer", remotePath: remotePath, downloadsFolder: folder),
            destinationURL: destination
        )
    }

    /// Connects, queues the download, and returns its terminal state (finished/failed).
    private func runDownload(
        _ request: SlskDownloadRequest, against mock: MockSoulseekServer
    ) async throws -> SlskDownloadState? {
        var eventContinuation: AsyncStream<SlskEvent>.Continuation!
        let events = AsyncStream<SlskEvent> { eventContinuation = $0 }
        let continuation = eventContinuation!

        let client = SoulseekClient(
            username: "tester",
            password: "secret",
            server: (host: "127.0.0.1", port: mock.port)
        ) { continuation.yield($0) }

        try await client.connect()
        await client.download(request)

        var finalState: SlskDownloadState?
        let deadline = Task {
            try await Task.sleep(for: .seconds(20))
            continuation.finish()
        }
        for await event in events {
            guard case .downloadState(let id, let state) = event, id == request.id else { continue }
            switch state {
            case .finished, .failed:
                finalState = state
                continuation.finish()
            default:
                break
            }
        }
        deadline.cancel()
        await client.disconnect()
        return finalState
    }
}

/// Speaks just enough of the server side of the protocol for the tests above, plus a second
/// listener acting as the peer "mockpeer": it answers search requests with one result, and
/// (depending on `peerBehavior`) either uploads a file the modern way — TransferRequest,
/// TransferResponse, then an outgoing `F` connection with token/offset exchange — or denies it.
private final class MockSoulseekServer: @unchecked Sendable {
    enum PeerBehavior {
        case searchOnly
        case upload(Data)
        case deny(reason: String)
        /// Answers a browse with bytes that aren't a share list.
        case corruptShareList
    }

    /// How the client can reach "mockpeer": by dialing it, only through the peer piercing the
    /// client's listener after a relayed ConnectToPeer (its own port refuses connections), or
    /// not at all (the server answers ConnectToPeer with CantConnectToPeer).
    enum Reachability {
        case direct
        case firewalled
        case unreachable
    }

    let port: UInt16
    /// When set, receiving a search response makes the mock turn around and queue a download
    /// of the first result (exercising the client's upload path).
    var requestUploadOnResult = false
    /// Delivered (as re-sent, not new) right after login, like messages that waited for us.
    var offlineMessages: [(id: UInt32, user: String, text: String)] = []
    var reachability = Reachability.direct
    /// False leaves the client's login unanswered.
    var answersLogin = true

    private let listener: SlskListener
    private let peerListener: SlskListener
    private let peerPort: UInt16
    /// A port nothing listens on, so dialing it is refused straight away.
    private let closedPort: UInt16
    private let behavior: PeerBehavior
    private let lock = NSLock()
    private var _receivedQuery: String?
    private var _receivedWishlistQuery: String?
    private var _receivedOffset: UInt64?
    private var _failures: [String] = []
    private var _clientListenPort: UInt16?
    private var _serverConnection: SocketConnection?
    private var _searchResponse: SlskSearchResponse?
    private var _uploadOffer: (token: UInt32, path: String, size: UInt64)?
    private var _receivedFile: Data?
    private var connections: [any SlskStream] = []
    private var _ackedMessageIDs: [UInt32] = []
    private var _sentMessages: [(user: String, text: String)] = []
    private var _watchedUsers: [String] = []

    var ackedMessageIDs: [UInt32] {
        lock.lock()
        defer { lock.unlock() }
        return _ackedMessageIDs
    }

    var sentMessages: [(user: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return _sentMessages
    }

    var watchedUsers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _watchedUsers
    }

    /// Server code 22, received side: u32 ID, u32 timestamp, string user, string message, bool new.
    func deliverMessage(id: UInt32, from username: String, text: String, isNew: Bool) async throws {
        guard let connection = serverConnection else { throw SlskError(message: "no server connection yet") }
        try await connection.send(messageFrame(id: id, from: username, text: text, isNew: isNew))
    }

    private func messageFrame(id: UInt32, from username: String, text: String, isNew: Bool) -> Data {
        var body = SlskWriter()
        body.u32(id)
        body.u32(1_700_000_000)
        body.string(username)
        body.string(text)
        body.bool(isNew)
        return serverFrame(code: 22, body: body)
    }

    /// Acts as "mockpeer" asking the client about itself: dial its listener, send peer code 15,
    /// read back the code 16 answer.
    func askClientForUserInfo(timeout: Double = 5) async throws -> SlskUserInfo {
        guard let port = clientListenPort, port != 0 else { throw SlskError(message: "client never sent SetWaitPort") }
        let peer = TCPConnection(host: "127.0.0.1", port: port)
        track(peer)
        defer { peer.cancel() }
        try await peer.start(timeout: 5)
        try await peer.send(SlskPeerInit.peerInit(username: "mockpeer", connectionType: "P"))
        try await peer.send(SlskPeerMessage.userInfoRequest())
        let receiving = Task { () throws -> SlskUserInfo in
            var frames = SlskFrameBuffer()
            while let chunk = try await peer.receive() {
                frames.append(chunk)
                while let frame = try frames.nextFrame() {
                    var reader = SlskReader(frame)
                    if try reader.u32() == SlskPeerCode.userInfoResponse.rawValue {
                        return try SlskUserInfo(parsing: Data(frame.dropFirst(4)))
                    }
                }
            }
            throw SlskError(message: "closed without user info")
        }
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            peer.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await receiving.value
        } catch {
            throw SlskError(message: "no user info: \(error)")
        }
    }

    var receivedQuery: String? {
        lock.lock()
        defer { lock.unlock() }
        return _receivedQuery
    }

    var receivedWishlistQuery: String? {
        lock.lock()
        defer { lock.unlock() }
        return _receivedWishlistQuery
    }

    var receivedOffset: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return _receivedOffset
    }

    var failures: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _failures
    }

    var clientListenPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return _clientListenPort
    }

    var searchResponse: SlskSearchResponse? {
        lock.lock()
        defer { lock.unlock() }
        return _searchResponse
    }

    var uploadOffer: (token: UInt32, path: String, size: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        return _uploadOffer
    }

    var receivedFile: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _receivedFile
    }

    private func record(_ update: (MockSoulseekServer) -> Void) {
        lock.lock()
        update(self)
        lock.unlock()
    }

    private var serverConnection: SocketConnection? {
        lock.lock()
        defer { lock.unlock() }
        return _serverConnection
    }

    /// Delivers a search to the client over the server connection (server code 26),
    /// the way user/room searches and branch-root duty arrive.
    func deliverSearch(from username: String, token: UInt32, query: String) async throws {
        guard let connection = serverConnection else { throw SlskError(message: "no server connection yet") }
        var body = SlskWriter()
        body.string(username)
        body.u32(token)
        body.string(query)
        try await connection.send(serverFrame(code: 26, body: body))
    }

    init(peerBehavior: PeerBehavior = .searchOnly) async throws {
        behavior = peerBehavior
        guard let listener = SlskListener(preferredPort: 0),
              let peerListener = SlskListener(preferredPort: 0),
              let closed = SlskListener(preferredPort: 0) else {
            throw SlskError(message: "mock listener failed")
        }
        closedPort = closed.port
        closed.cancel()
        self.listener = listener
        self.peerListener = peerListener
        port = listener.port
        peerPort = peerListener.port
        listener.start { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.track(connection)
            Task {
                do {
                    try await self.serve(connection)
                } catch {
                    self.recordFailure("serve: \(error)")
                }
            }
        }
        peerListener.start { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.track(connection)
            Task {
                do {
                    try await self.servePeer(connection)
                } catch {
                    self.recordFailure("servePeer: \(error)")
                }
            }
        }
    }

    private func track(_ connection: any SlskStream) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
    }

    private func recordQuery(_ query: String) {
        lock.lock()
        _receivedQuery = query
        lock.unlock()
    }

    private func recordOffset(_ offset: UInt64) {
        lock.lock()
        _receivedOffset = offset
        lock.unlock()
    }

    private func recordClientPort(_ port: UInt16?) {
        lock.lock()
        _clientListenPort = port
        lock.unlock()
    }

    private func recordFailure(_ message: String) {
        lock.lock()
        _failures.append(message)
        lock.unlock()
    }

    func stop() {
        listener.cancel()
        peerListener.cancel()
        lock.lock()
        let connections = connections
        lock.unlock()
        for connection in connections { connection.cancel() }
    }

    // MARK: Server connection

    private func serve(_ connection: SocketConnection) async throws {
        record { $0._serverConnection = connection }
        var frames = SlskFrameBuffer()
        while let chunk = try await connection.receive() {
            frames.append(chunk)
            while let frame = try frames.nextFrame() {
                var reader = SlskReader(frame)
                switch try reader.u32() {
                case 1:  // Login
                    guard answersLogin else { break }
                    var body = SlskWriter()
                    body.bool(true)
                    body.string("Welcome to the mock")
                    body.u32(0x7F00_0001)  // 127.0.0.1
                    body.string("hash")
                    body.bool(false)
                    try await connection.send(serverFrame(code: 1, body: body))
                    var interval = SlskWriter()
                    interval.u32(600)
                    try await connection.send(serverFrame(code: 104, body: interval))
                    for message in offlineMessages {
                        try await connection.send(messageFrame(id: message.id, from: message.user, text: message.text, isNew: false))
                    }
                case 2:  // SetWaitPort
                    recordClientPort(UInt16(exactly: try reader.u32()))
                case 3:  // GetPeerAddress: the "peer" lives on our second listener
                    let username = try reader.string()
                    var body = SlskWriter()
                    body.string(username)
                    body.u32(0x7F00_0001)  // 127.0.0.1
                    switch reachability {
                    case .direct: body.u32(UInt32(peerPort))
                    case .firewalled: body.u32(UInt32(closedPort))
                    case .unreachable: body.u32(0)
                    }
                    body.u32(1)
                    try await connection.send(serverFrame(code: 3, body: body))
                case 18:  // ConnectToPeer from the client: token, user, type
                    let token = try reader.u32()
                    let username = try reader.string()
                    let type = try reader.string()
                    switch reachability {
                    case .direct:
                        break  // the client's direct dial gets through
                    case .firewalled:
                        guard type == "P" else { break }
                        Task {
                            do {
                                try await self.pierce(token: token)
                            } catch {
                                self.recordFailure("pierce: \(error)")
                            }
                        }
                    case .unreachable:
                        var body = SlskWriter()
                        body.u32(token)
                        body.string(username)
                        try await connection.send(serverFrame(code: 1001, body: body))
                    }
                case 5:  // WatchUser: exists, online, stats, country code
                    let username = try reader.string()
                    record { $0._watchedUsers.append(username) }
                    var body = SlskWriter()
                    body.string(username)
                    body.bool(true)
                    body.u32(SlskUserStatus.online.rawValue)
                    Self.writeStats(&body)
                    body.string("IS")
                    try await connection.send(serverFrame(code: 5, body: body))
                case 7:  // GetUserStatus
                    var body = SlskWriter()
                    body.string(try reader.string())
                    body.u32(SlskUserStatus.away.rawValue)
                    body.bool(true)
                    try await connection.send(serverFrame(code: 7, body: body))
                case 36:  // GetUserStats
                    var body = SlskWriter()
                    body.string(try reader.string())
                    Self.writeStats(&body)
                    try await connection.send(serverFrame(code: 36, body: body))
                case 22:  // MessageUser, sent side: string user, string message
                    let user = try reader.string()
                    let text = try reader.string()
                    record { $0._sentMessages.append((user, text)) }
                case 23:  // MessageAcked
                    let id = try reader.u32()
                    record { $0._ackedMessageIDs.append(id) }
                case 26:  // FileSearch: deliver one result like a peer would
                    let token = try reader.u32()
                    recordQuery(try reader.string())
                    guard let peerPort = clientListenPort, peerPort != 0 else {
                        throw SlskError(message: "client never sent SetWaitPort")
                    }
                    try await sendResultAsPeer(to: peerPort, token: token)
                case 103:  // WishlistSearch: same as a search, recorded separately
                    let token = try reader.u32()
                    let query = try reader.string()
                    record { $0._receivedWishlistQuery = query }
                    guard let peerPort = clientListenPort, peerPort != 0 else {
                        throw SlskError(message: "client never sent SetWaitPort")
                    }
                    try await sendResultAsPeer(to: peerPort, token: token)
                default:
                    break  // status, shared counts, pings, ConnectToPeer relays
                }
            }
        }
    }

    /// avgspeed, uploadnum, unknown, files, dirs.
    private static func writeStats(_ body: inout SlskWriter) {
        body.u32(250_000)
        body.u32(42)
        body.u32(0)
        body.u32(1234)
        body.u32(56)
    }

    /// Server code 41: someone logged in with the client's account elsewhere.
    func sendRelogged() async throws {
        guard let connection = serverConnection else { throw SlskError(message: "no server connection yet") }
        try await connection.send(serverFrame(code: 41, body: SlskWriter()))
    }

    /// Answers a search the client may or may not have made, as "mockpeer".
    func sendSearchResult(token: UInt32) async throws {
        guard let port = clientListenPort, port != 0 else { throw SlskError(message: "client never sent SetWaitPort") }
        try await sendResultAsPeer(to: port, token: token)
    }

    /// Dials the client's listener and says hello as `user`, then stays quiet.
    func openIdleConnection(as user: String) async throws -> TCPConnection {
        guard let port = clientListenPort, port != 0 else { throw SlskError(message: "client never sent SetWaitPort") }
        let peer = TCPConnection(host: "127.0.0.1", port: port)
        track(peer)
        try await peer.start(timeout: 5)
        try await peer.send(SlskPeerInit.peerInit(username: user, connectionType: "P"))
        return peer
    }

    /// "mockpeer" behind a firewall: answers the relayed ConnectToPeer by dialing the client and
    /// piercing with its token, then serves peer messages on that connection.
    private func pierce(token: UInt32) async throws {
        guard let port = clientListenPort, port != 0 else { throw SlskError(message: "client never sent SetWaitPort") }
        let connection = TCPConnection(host: "127.0.0.1", port: port)
        track(connection)
        try await connection.start(timeout: 5)
        try await connection.send(SlskPeerInit.pierceFirewall(token: token))
        try await servePeer(connection, greeted: true)
    }

    private func sendResultAsPeer(to port: UInt16, token: UInt32) async throws {
        let peer = TCPConnection(host: "127.0.0.1", port: port)
        track(peer)
        try await peer.start(timeout: 5)
        try await peer.send(SlskPeerInit.peerInit(username: "mockpeer", connectionType: "P"))

        var body = SlskWriter()
        body.string("mockpeer")
        body.u32(token)
        body.u32(1)
        body.u8(1)
        body.string(#"@@mock\Artist\Album\01 Song.flac"#)
        body.u64(1_234_567)
        body.string("flac")
        body.u32(0)
        body.bool(true)
        body.u32(100_000)
        body.u32(0)
        body.u32(0)
        body.u32(0)
        var message = SlskWriter()
        message.u32(SlskPeerCode.fileSearchResponse.rawValue)
        let payload = message.data + (try SlskZlib.deflate(body.data))
        var framed = SlskWriter()
        framed.u32(UInt32(payload.count))
        try await peer.send(framed.data + payload)
    }

    private func serverFrame(code: UInt32, body: SlskWriter) -> Data {
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count + 4))
        framed.u32(code)
        return framed.data + body.data
    }

    // MARK: Peer connection (the uploading side)

    private static let transferToken: UInt32 = 7777

    /// `greeted` is true for a connection whose init is already done (one we pierced).
    private func servePeer(_ connection: any SlskStream, greeted: Bool = false) async throws {
        var frames = SlskFrameBuffer()
        var sawInit = greeted
        var initType = "P"
        while let chunk = try await connection.receive() {
            frames.append(chunk)
            while let frame = try frames.nextFrame() {
                if !sawInit {
                    guard case .peerInit(_, let type) = try SlskPeerInit.parse(frame) else {
                        throw SlskError(message: "expected PeerInit first")
                    }
                    sawInit = true
                    initType = type
                    if initType == "F" {
                        // Raw transfer bytes follow the init frame on an `F` connection.
                        try await receiveUpload(connection, buffered: frames.drainRemaining())
                        return
                    }
                    continue
                }
                var reader = SlskReader(frame)
                switch SlskPeerCode(rawValue: try reader.u32()) {
                case .queueUpload:
                    let path = try reader.string()
                    switch behavior {
                    case .searchOnly, .corruptShareList:
                        break
                    case .deny(let reason):
                        var body = SlskWriter()
                        body.string(path)
                        body.string(reason)
                        try await connection.send(peerFrame(code: .uploadDenied, body: body))
                    case .upload(let data):
                        var body = SlskWriter()
                        body.u32(1)  // direction: upload to the requester
                        body.u32(Self.transferToken)
                        body.string(path)
                        body.u64(UInt64(data.count))
                        try await connection.send(peerFrame(code: .transferRequest, body: body))
                    }
                case .transferResponse:
                    let token = try reader.u32()
                    let allowed = try reader.bool()
                    guard allowed, token == Self.transferToken, case .upload(let data) = behavior else { break }
                    let upload = Task {
                        do {
                            try await self.uploadFile(data)
                        } catch {
                            self.recordFailure("uploadFile: \(error)")
                        }
                    }
                    _ = upload
                case .fileSearchResponse:
                    // We are the searcher: the client answered our search with its matches.
                    let response = try SlskSearchResponse(parsing: Data(frame.dropFirst(4)))
                    record { $0._searchResponse = response }
                    if requestUploadOnResult, let first = response.results.first {
                        var body = SlskWriter()
                        body.string(first.path)
                        try await connection.send(peerFrame(code: .queueUpload, body: body))
                    }
                case .sharedFileListRequest:
                    if case .corruptShareList = behavior {
                        try await connection.send(SlskPeerMessage.sharedFileListResponse(browsePayload: Data(repeating: 0x78, count: 64)))
                        break
                    }
                    // Browse: two folders, bare file names as real clients send them.
                    var list = SlskWriter()
                    list.u32(2)
                    for (folder, files, bitrate) in [
                        (#"@@mock\Artist\Album"#, ["01 Song.flac", "02 Other.flac"], UInt32(0)),
                        (#"@@mock\Artist\Single"#, ["Single.mp3"], UInt32(320)),
                    ] {
                        list.string(folder)
                        list.u32(UInt32(files.count))
                        for name in files {
                            list.u8(1)
                            list.string(name)
                            list.u64(5000)
                            list.string("")
                            list.u32(bitrate > 0 ? 1 : 0)
                            if bitrate > 0 { list.u32(0); list.u32(bitrate) }
                        }
                    }
                    list.u32(0)
                    try await connection.send(SlskPeerMessage.sharedFileListResponse(browsePayload: try SlskZlib.deflate(list.data)))
                case .userInfoRequest:
                    try await connection.send(SlskPeerMessage.userInfoResponse(
                        description: "mock peer, sharing since forever", picture: Data([0x89, 0x50, 0x4E, 0x47]),
                        uploadSlots: 3, queueLength: 7, slotFree: false))
                case .transferRequest:
                    // The client offers to upload a file we queued: accept it.
                    let request = try SlskTransferRequest(parsing: Data(frame.dropFirst(4)))
                    record { $0._uploadOffer = (request.token, request.path, request.size) }
                    try await connection.send(SlskPeerMessage.transferResponse(token: request.token, allowed: true))
                default:
                    break
                }
            }
        }
    }

    /// The downloader's side of the client's upload: read the raw token, answer with offset 0,
    /// then collect the file bytes.
    private func receiveUpload(_ connection: any SlskStream, buffered: Data) async throws {
        var raw = buffered
        while raw.count < 4 {
            guard let chunk = try await connection.receive() else {
                throw SlskError(message: "uploader closed before sending a token")
            }
            raw.append(chunk)
        }
        var reader = SlskReader(raw)
        _ = try reader.u32()  // transfer token; one upload at a time in these tests
        guard let size = uploadOffer?.size else {
            throw SlskError(message: "F connection before a TransferRequest")
        }
        var offset = SlskWriter()
        offset.u64(0)
        try await connection.send(offset.data)

        var file = Data(raw.dropFirst(4))
        while file.count < Int(size) {
            guard let chunk = try await connection.receive() else { break }
            file.append(chunk)
        }
        record { $0._receivedFile = file }
        // A real downloader closes the connection once the file is complete;
        // the uploader takes that as the transfer being done.
        connection.cancel()
    }

    /// The modern transfer: the uploader opens the `F` connection, sends the raw transfer
    /// token, reads the raw 8-byte resume offset, and streams the file from there.
    private func uploadFile(_ data: Data) async throws {
        guard let port = clientListenPort, port != 0 else {
            throw SlskError(message: "client never sent SetWaitPort")
        }
        let connection = TCPConnection(host: "127.0.0.1", port: port)
        track(connection)
        try await connection.start(timeout: 5)
        try await connection.send(SlskPeerInit.peerInit(username: "mockpeer", connectionType: "F"))
        var token = SlskWriter()
        token.u32(Self.transferToken)
        try await connection.send(token.data)

        var raw = Data()
        while raw.count < 8 {
            guard let chunk = try await connection.receive() else {
                throw SlskError(message: "client closed before sending an offset")
            }
            raw.append(chunk)
        }
        var reader = SlskReader(raw)
        let offset = try reader.u64()
        recordOffset(offset)
        guard offset <= UInt64(data.count) else {
            throw SlskError(message: "offset beyond file size")
        }
        try await connection.send(Data(data.dropFirst(Int(offset))))
    }

    private func peerFrame(code: SlskPeerCode, body: SlskWriter) -> Data {
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count + 4))
        framed.u32(code.rawValue)
        return framed.data + body.data
    }
}
