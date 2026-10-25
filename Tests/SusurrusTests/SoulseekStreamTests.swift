import Foundation
import Testing
@testable import Susurrus

/// Both stream types over real loopback sockets: read deadlines, cancellation, and flow control
/// in both directions.
@Suite struct SoulseekStreamTests {
    @Test func silentConnectionsTimeOutCloseToTheirDeadline() async throws {
        let (client, server, listener) = try await connectedPair()
        defer { close(client, server, listener) }

        for stream in [client, server] as [any SlskStream] {
            let start = ContinuousClock.now
            await #expect(throws: SlskError.self) { try await stream.receive(timeout: 0.5) }
            let elapsed = ContinuousClock.now - start
            #expect(elapsed > .milliseconds(450) && elapsed < .milliseconds(1500), "timed out after \(elapsed)")
        }
        // Bytes arriving after a read gave up wait for the next read.
        try await client.send(Data("late".utf8))
        #expect(try await server.receive(timeout: 5) == Data("late".utf8))
        try await server.send(Data("back".utf8))
        #expect(try await client.receive(timeout: 5) == Data("back".utf8))
    }

    @Test func cancellingAReadEndsItAtOnce() async throws {
        let (client, server, listener) = try await connectedPair()
        defer { close(client, server, listener) }

        let reading = Task { try await server.receive() }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))

        try await client.send(Data([1, 2, 3]))
        #expect(try await server.receive(timeout: 5) == Data([1, 2, 3]))
    }

    /// A fast sender and a reader that looks away for a while: the accepted socket stops reading
    /// ahead and lets TCP hold the rest, rather than buffering without end or giving up.
    @Test func slowReadersStillGetEverything() async throws {
        let (client, server, listener) = try await connectedPair()
        defer { close(client, server, listener) }

        let payload = Self.payload(megabytes: 12)
        let sending = Task { try await client.send(payload) }
        try await Task.sleep(for: .seconds(1))
        let received = try await Self.read(payload.count, from: server)
        try await sending.value
        #expect(received == payload)
    }

    /// Sending to a peer that doesn't read for a while waits for it instead of failing.
    @Test func sendsWaitForSlowReaders() async throws {
        let (client, server, listener) = try await connectedPair()
        defer { close(client, server, listener) }

        let payload = Self.payload(megabytes: 8)
        let sending = Task { try await server.send(payload) }
        try await Task.sleep(for: .seconds(1))
        let received = try await Self.read(payload.count, from: client)
        try await sending.value
        #expect(received == payload)
    }

    @Test func theEndOfAStreamStaysTheEnd() async throws {
        let (client, server, listener) = try await connectedPair()
        defer { close(client, server, listener) }

        client.cancel()
        _ = try? await server.receive(timeout: 5)
        let start = ContinuousClock.now
        #expect((try? await server.receive(timeout: 5)) == nil)
        #expect(ContinuousClock.now - start < .milliseconds(200))
    }

    // MARK: Helpers

    /// An outbound `TCPConnection` and the `SocketConnection` a listener accepted for it.
    private func connectedPair() async throws -> (TCPConnection, SocketConnection, SlskListener) {
        guard let listener = SlskListener(preferredPort: 0) else { throw SlskError(message: "no listener") }
        let (accepted, continuation) = AsyncStream.makeStream(of: SocketConnection.self)
        listener.start { continuation.yield($0) }
        let client = TCPConnection(host: "127.0.0.1", port: listener.port)
        try await client.start(timeout: 5)
        var connections = accepted.makeAsyncIterator()
        guard let server = await connections.next() else { throw SlskError(message: "nothing accepted") }
        return (client, server, listener)
    }

    private func close(_ client: TCPConnection, _ server: SocketConnection, _ listener: SlskListener) {
        client.cancel()
        server.cancel()
        listener.cancel()
    }

    /// Distinct 64 KiB blocks, so lost or reordered data shows.
    private static func payload(megabytes: Int) -> Data {
        let block = Data((0 ..< 65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var data = Data(capacity: megabytes << 20)
        for index in 0 ..< megabytes * 16 {
            var numbered = block
            numbered[0] = UInt8(truncatingIfNeeded: index)
            numbered[1] = UInt8(truncatingIfNeeded: index >> 8)
            data.append(numbered)
        }
        return data
    }

    private static func read(_ count: Int, from stream: any SlskStream) async throws -> Data {
        var received = Data()
        while received.count < count {
            guard let chunk = try await stream.receive(timeout: 10) else { break }
            received.append(chunk)
        }
        return received
    }
}

@Suite struct SoulseekWaitersTests {
    @Test func answersBeforeTheWaitAreKept() async {
        let waiters = SlskWaiters<String, Int>()
        let ticket = waiters.register("a", timeout: 5)
        #expect(waiters.resolve("a", with: 7))
        #expect(await waiters.wait(ticket) == 7)
    }

    @Test func eachWaitHasItsOwnDeadline() async {
        let waiters = SlskWaiters<String, Int>()
        let early = waiters.register("a", timeout: 0.2)
        let late = waiters.register("a", timeout: 5)
        let start = ContinuousClock.now
        #expect(await waiters.wait(early) == nil)
        // Well before the other wait's 5 s (with room for a busy machine running tests in parallel).
        #expect(ContinuousClock.now - start < .seconds(3))
        // The other wait for the same key is still open.
        #expect(waiters.isWaiting(for: "a"))
        #expect(waiters.resolve("a", with: 3))
        #expect(await waiters.wait(late) == 3)
    }

    @Test func cancelledAndFailedWaitsEndWithNil() async throws {
        let waiters = SlskWaiters<UInt32, Int>()
        let ticket = waiters.register(1, timeout: 30)
        let waiting = Task { await waiters.wait(ticket) }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        #expect(await waiting.value == nil)

        let failing = waiters.register(2, timeout: 30)
        #expect(waiters.fail(2))
        #expect(await waiters.wait(failing) == nil)
        #expect(!waiters.resolve(2, with: 5), "nobody waits for it any more")
    }
}
