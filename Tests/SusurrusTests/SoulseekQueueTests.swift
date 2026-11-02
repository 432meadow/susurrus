import Foundation
import Testing
@testable import Susurrus

/// Downloads keep going: through interruptions and lost connections, and across a quit. The model
/// against the mock server, with short delays and an account of its own (no keychain).
@MainActor
@Suite(.serialized) struct SoulseekQueueTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SoulseekQueueTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private static let remotePath = #"@@mock\Artist\Album\01 Song.flac"#

    private func makeModel(_ mock: MockSoulseekServer, retryDelays: [TimeInterval] = [0.05, 0.05, 0.05], requeueInterval: TimeInterval = 3600) -> SoulseekModel {
        let network = SoulseekModel.Network(server: ("127.0.0.1", mock.port), account: ("tester", "secret"),
                                            reconnectDelay: 0.05, retryDelays: retryDelays, requeueInterval: requeueInterval)
        let model = SoulseekModel(chats: SoulseekChats(fileURL: nil), shareWalkURL: nil, network: network)
        model.downloadFolderPath = folder.path
        return model
    }

    private func forgetSettings() {
        for key in ["soulseek.downloadFolder", "soulseek.choseOffline"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func result(size: UInt64) -> SlskSearchResult {
        SlskSearchResult(id: 0, username: "mockpeer", path: Self.remotePath, size: size, bitrate: nil, isVBR: false, durationSeconds: nil,
                         sampleRate: nil, bitDepth: nil, slotFree: true, averageSpeed: 0, queueLength: 0)
    }

    private func waitUntil(timeout: Double = 15, _ what: Comment? = nil, _ condition: () -> Bool) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if ContinuousClock.now - start > .seconds(timeout) {
                Issue.record(what ?? "timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func state(of model: SoulseekModel) -> SlskDownloadState? { model.downloads.first?.state }

    // MARK: Interruptions

    @Test func aDownloadCutOffMidTransferResumesByItself() async throws {
        defer { forgetSettings() }
        let data = Data((0 ..< 80_000).map { UInt8(truncatingIfNeeded: $0 &* 5) })
        let mock = try await MockSoulseekServer(peerBehavior: .upload(data))
        defer { mock.stop() }
        mock.cutFirstUploadAfter = 30_000
        let model = makeModel(mock)
        defer { model.disconnect() }

        model.download([result(size: UInt64(data.count))])
        try await waitUntil { model.downloads.first?.isFinished == true }

        let row = try #require(model.downloads.first)
        #expect(try Data(contentsOf: row.localURL) == data)
        #expect(mock.receivedOffset == 30_000, "it carried on where it stopped")
        #expect(mock.queueUploadCount == 2)
        #expect(model.activeDownloadCount == 0)
    }

    @Test func triesRunningOutEndInFailure() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        mock.reachability = .unreachable
        let model = makeModel(mock, retryDelays: [0.01, 0.01])
        defer { model.disconnect() }

        model.download([result(size: 1000)])
        try await waitUntil { if case .failed = state(of: model) { true } else { false } }
        #expect(state(of: model) == .failed("Can't be reached"))
        #expect(model.downloads.first?.tries == 2)
        #expect(model.activeDownloadCount == 0)
    }

    @Test func aRefusalForGoodIsntRetried() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer(peerBehavior: .deny(reason: "File not shared."))
        defer { mock.stop() }
        let model = makeModel(mock)
        defer { model.disconnect() }

        model.download([result(size: 1000)])
        try await waitUntil { if case .failed = state(of: model) { true } else { false } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(state(of: model) == .failed("File not shared."))
        #expect(mock.queueUploadCount == 1)
    }

    @Test func gettingFurtherDoesntCountAgainstADownload() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock, retryDelays: [3600, 3600])
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .requested }
        let row = try #require(model.downloads.first)
        let session = try #require(row.session)

        model.applyDownloadState(row.id, .interrupted("Transfer interrupted"), from: session)
        #expect(model.downloads.first?.tries == 1)
        // (The client still has this one, since the interruption was only reported here: it won't start again.)
        model.tryNow(row.id)
        try await waitUntil { state(of: model) == .connecting && model.downloads.first?.session != nil }
        model.applyDownloadState(row.id, .transferring(received: 500, total: 1000), from: session)
        try await waitUntil { model.downloads.first?.furthest == 500 }
        #expect(model.downloads.first?.tries == 0)

        // The same bytes again aren't progress.
        model.applyDownloadState(row.id, .interrupted("Transfer interrupted"), from: session)
        #expect(model.downloads.first?.tries == 1)
    }

    @Test func aLateReportDoesntChangeATryThatsOver() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock, retryDelays: [3600])
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .requested }
        let row = try #require(model.downloads.first)
        let session = try #require(row.session)

        model.applyDownloadState(row.id, .interrupted("Transfer interrupted"), from: session)
        model.applyDownloadState(row.id, .transferring(received: 5, total: 1000), from: session)
        try await Task.sleep(for: .milliseconds(350))  // past the progress batching
        #expect(state(of: model) == .interrupted("Transfer interrupted"))
    }

    @Test func aClientThatWasReplacedCantOverruleTheNextOne() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock)
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .requested }
        let row = try #require(model.downloads.first)
        let session = try #require(row.session)

        model.applyDownloadState(row.id, .failed("Stale"), from: session - 1)
        #expect(state(of: model) == .requested)

        let url = folder.appendingPathComponent("landed.flac")
        model.applyDownloadState(row.id, .finished(url), from: session - 1)
        #expect(state(of: model) == .finished(url), "a file it finished is finished")
    }

    @Test func aFileThatLandedAsItWasCancelledCountsAsFinished() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock)
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .requested }
        let row = try #require(model.downloads.first)
        let session = try #require(row.session)

        model.cancel([row.id])
        #expect(state(of: model) == .cancelled)
        model.applyDownloadState(row.id, .failed("Too late"), from: session)
        #expect(state(of: model) == .cancelled)

        let url = folder.appendingPathComponent("landed.flac")
        model.applyDownloadState(row.id, .finished(url), from: session)
        #expect(state(of: model) == .finished(url))
        #expect(model.downloads.first?.localURL == url)
    }

    @Test func cancellingADownloadBetweenTriesDeletesItsPart() async throws {
        defer { forgetSettings() }
        let data = Data(repeating: 4, count: 50_000)
        let mock = try await MockSoulseekServer(peerBehavior: .upload(data))
        defer { mock.stop() }
        mock.cutFirstUploadAfter = 10_000
        let model = makeModel(mock, retryDelays: [3600])
        defer { model.disconnect() }
        model.download([result(size: UInt64(data.count))])
        try await waitUntil { if case .interrupted = state(of: model) { true } else { false } }
        let row = try #require(model.downloads.first)
        #expect(FileManager.default.fileExists(atPath: row.partURL.path))
        #expect(row.retryDate != nil)

        model.cancel([row.id])
        try await waitUntil { !FileManager.default.fileExists(atPath: row.partURL.path) }
        #expect(state(of: model) == .cancelled)
    }

    @Test func retryingAFailedDownloadKeepsItsPlaceAndPart() async throws {
        defer { forgetSettings() }
        let data = Data(repeating: 6, count: 50_000)
        let mock = try await MockSoulseekServer(peerBehavior: .upload(data))
        defer { mock.stop() }
        mock.cutFirstUploadAfter = 10_000
        let model = makeModel(mock, retryDelays: [])
        defer { model.disconnect() }
        model.download([result(size: UInt64(data.count))])
        try await waitUntil { if case .failed = state(of: model) { true } else { false } }
        let row = try #require(model.downloads.first)

        model.retry(row.id)
        try await waitUntil { model.downloads.first?.isFinished == true }
        #expect(model.downloads.count == 1)
        #expect(model.downloads.first?.partURL == row.partURL && model.downloads.first?.tries == 0)
        #expect(mock.receivedOffset == 10_000, "it carried on from its part file")
    }

    // MARK: Uploaders coming and going

    @Test func anOfflineUploaderIsWaitedForAndAskedOnceItsBack() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        mock.reachability = .unreachable
        mock.watchedStatus = .offline
        let model = makeModel(mock, retryDelays: [0.01])
        defer { model.disconnect() }

        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .interrupted("Offline") }
        let row = try #require(model.downloads.first)
        #expect(row.retryDate == nil && row.tries == 0, "it isn't held against the download")
        #expect(mock.watchedUsers.contains("mockpeer"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(state(of: model) == .interrupted("Offline"), "no retries while they're away")

        mock.reachability = .direct
        try await mock.sendStatus(of: "mockpeer", .online)
        try await waitUntil { state(of: model) == .requested }
    }

    @Test func anUploaderWhoCameBackIsAskedAgainForWhatTheyHadQueued() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock)
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .requested && mock.queueUploadCount == 1 }

        try await mock.sendStatus(of: "mockpeer", .offline)
        try await waitUntil { model.userDetails["mockpeer"]?.status == .offline }
        try await mock.sendStatus(of: "mockpeer", .online)
        try await waitUntil { mock.queueUploadCount == 2 }
        #expect(state(of: model) == .requested)
    }

    @Test func uploadersAreAskedAgainNowAndThen() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock, requeueInterval: 0.1)
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { mock.queueUploadCount >= 3 }
        #expect(state(of: model) == .requested)
    }

    // MARK: Lost connections

    @Test func aLostConnectionPutsDownloadsOnHoldAndTheyCarryOn() async throws {
        defer { forgetSettings() }
        let data = Data(repeating: 8, count: 20_000)
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock)
        defer { model.disconnect() }
        model.download([result(size: UInt64(data.count))])
        try await waitUntil { state(of: model) == .requested && mock.queueUploadCount == 1 }

        mock.dropClient()
        try await waitUntil { mock.queueUploadCount == 2 }
        try await waitUntil { state(of: model) == .requested }
        #expect(model.downloads.count == 1)
    }

    @Test func goingOfflineByHandWaitsUntilConnected() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let model = makeModel(mock)
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { state(of: model) == .requested }
        #expect(model.resumesDownloadsAtLaunch)

        model.disconnect()
        try await waitUntil { state(of: model) == .waitingForConnection }
        #expect(model.activeDownloadCount == 1)
        #expect(!model.resumesDownloadsAtLaunch, "offline on purpose stays offline at the next launch")
        try await Task.sleep(for: .milliseconds(150))
        #expect(state(of: model) == .waitingForConnection, "no reconnecting by itself")

        model.connect()
        try await waitUntil { state(of: model) == .requested }
        #expect(mock.queueUploadCount == 2)
    }

    @Test func goingOfflinePutsARetryOffUntilTheNextSession() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        mock.reachability = .unreachable
        let model = makeModel(mock, retryDelays: [3600])
        defer { model.disconnect() }
        model.download([result(size: 1000)])
        try await waitUntil { if case .interrupted = state(of: model) { true } else { false } }
        #expect(model.downloads.first?.retryDate != nil)

        model.disconnect()
        #expect(state(of: model) == .waitingForConnection && model.downloads.first?.retryDate == nil, "nothing promises a time it can't keep")

        mock.reachability = .direct
        model.connect()
        try await waitUntil { state(of: model) == .requested }
    }

    @Test func aDownloadQueuedWhileOfflineWaitsForTheConnection() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        mock.answersLogin = false
        let network = SoulseekModel.Network(server: ("127.0.0.1", mock.port), account: ("", ""), reconnectDelay: 3600, retryDelays: [], requeueInterval: 3600)
        let model = SoulseekModel(chats: SoulseekChats(fileURL: nil), shareWalkURL: nil, network: network)
        model.downloadFolderPath = folder.path
        model.download([result(size: 1000)])  // no account: it can't connect
        try await waitUntil { state(of: model) == .waitingForConnection }
        #expect(model.activeDownloadCount == 1)
    }

    // MARK: Across a quit

    @Test func theQueueSurvivesAQuit() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let file = folder.appendingPathComponent("Soulseek/Downloads.json")

        let first = makeModel(mock)
        first.restoreDownloads(from: file)
        first.download([
            result(size: 1000),
            SlskSearchResult(id: 1, username: "other", path: #"@@o\A\failed.flac"#, size: 2, bitrate: nil, isVBR: false, durationSeconds: nil,
                             sampleRate: nil, bitDepth: nil, slotFree: true, averageSpeed: 0, queueLength: 0),
            SlskSearchResult(id: 2, username: "other", path: #"@@o\A\finished.flac"#, size: 2, bitrate: nil, isVBR: false, durationSeconds: nil,
                             sampleRate: nil, bitDepth: nil, slotFree: true, averageSpeed: 0, queueLength: 0),
            SlskSearchResult(id: 3, username: "other", path: #"@@o\A\cancelled.flac"#, size: 2, bitrate: nil, isVBR: false, durationSeconds: nil,
                             sampleRate: nil, bitDepth: nil, slotFree: true, averageSpeed: 0, queueLength: 0),
        ])
        try await waitUntil { first.downloads[0].state == .requested }
        try await waitUntil { first.downloads.allSatisfy { $0.session != nil } }
        let wanted = first.downloads[0]
        for row in first.downloads[1...] {
            let session = try #require(row.session)
            switch row.remotePath.split(separator: "\\").last {
            case "failed.flac": first.applyDownloadState(row.id, .failed("File not shared."), from: session)
            case "finished.flac": first.applyDownloadState(row.id, .finished(folder.appendingPathComponent("finished.flac")), from: session)
            default: first.cancel([row.id])
            }
        }
        first.finishSavingQueue()
        first.disconnect()
        UserDefaults.standard.removeObject(forKey: "soulseek.choseOffline")  // it quit, rather than going offline

        let next = makeModel(mock)
        next.restoreDownloads(from: file)
        #expect(next.downloads.map(\.fileName) == ["01 Song.flac", "failed.flac"], "finished and cancelled ones aren't kept")
        #expect(next.downloads[0].id == wanted.id && next.downloads[0].partURL == wanted.partURL && next.downloads[0].localURL == wanted.localURL)
        #expect(next.downloads[0].state == .waitingForConnection)
        #expect(next.downloads[1].state == .failed("File not shared."))
        #expect(next.activeDownloadCount == 1 && next.resumesDownloadsAtLaunch)

        let before = mock.queueUploadCount
        next.connect()
        defer { next.disconnect() }
        try await waitUntil { next.downloads[0].state == .requested && mock.queueUploadCount > before }
        #expect(next.downloads[1].state == .failed("File not shared."), "that one waits for Retry")
    }

    @Test func theFileGoesWhenThereIsNothingLeftToKeep() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let file = folder.appendingPathComponent("Downloads.json")
        let model = makeModel(mock)
        defer { model.disconnect() }
        model.restoreDownloads(from: file)
        model.download([result(size: 1000)])
        model.finishSavingQueue()
        #expect(FileManager.default.fileExists(atPath: file.path))
        model.cancel(model.downloads.map(\.id))
        model.finishSavingQueue()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func aFolderNotImportedAtQuitIsImportedAtTheNextLaunch() async throws {
        defer { forgetSettings() }
        let mock = try await MockSoulseekServer()
        defer { mock.stop() }
        let file = folder.appendingPathComponent("Downloads.json")
        let album = folder.appendingPathComponent("Album", isDirectory: true)
        try JSONEncoder().encode(SoulseekSavedQueue(imports: [album.path])).write(to: file)

        let model = makeModel(mock)
        var imported: [URL] = []
        model.importFolders = { folders in
            imported += folders
            return true
        }
        model.restoreDownloads(from: file)
        try await waitUntil { !imported.isEmpty }
        #expect(imported.map(\.path) == [album.path])
        model.finishSavingQueue()
        #expect(!FileManager.default.fileExists(atPath: file.path), "done with")
    }

    @Test func aDamagedQueueFileIsAnEmptyQueue() throws {
        defer { forgetSettings() }
        let file = folder.appendingPathComponent("Downloads.json")
        try Data("not json".utf8).write(to: file)
        #expect(SoulseekQueueFile(url: file).load() == SoulseekSavedQueue())
    }
}
