import Darwin
import Foundation
import Network

/// What the client needs from a TCP stream, whichever backend provides it.
/// Outbound connections use Network.framework (`TCPConnection`); the listener and its
/// accepted connections use BSD sockets, because `NWListener` fails outright on Macs
/// with certain network filters installed (observed: EINVAL on every bind).
protocol SlskStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// One chunk of whatever is available; `nil` on a clean close. With a timeout it throws when
    /// nothing arrives in time, and cancelling the calling task ends the wait the same way —
    /// either way, bytes that arrive later are kept for the next call.
    func receive(timeout: TimeInterval?) async throws -> Data?
    func cancel()
}

extension SlskStream {
    func receive() async throws -> Data? {
        try await receive(timeout: nil)
    }
}

// MARK: Input buffer

/// Bytes a connection has received that nobody has read yet, and the one read waiting for more.
/// A read that times out or is cancelled just gives up its place, so nothing is lost.
final class SlskInputBuffer: @unchecked Sendable {
    private struct Reader {
        let id: Int
        let continuation: CheckedContinuation<Data?, Error>
        let deadline: DispatchWorkItem?
    }

    private let lock = NSLock()
    private var buffered = Data()
    private var isAtEnd = false
    private var failure: Error?
    private var reader: Reader?
    private var lastReadID = 0
    private var drainHandler: (@Sendable () -> Void)?

    /// Bytes waiting to be read.
    var count: Int { lock.withLock { buffered.count } }

    /// True once the connection closed or failed (buffered bytes may still be waiting).
    var hasEnded: Bool { lock.withLock { isAtEnd || failure != nil } }

    /// Called (never under the lock) after a read took everything buffered, so the connection
    /// can read ahead again.
    func setDrainHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { drainHandler = handler }
    }

    func read(timeout: TimeInterval?) async throws -> Data? {
        let id = lock.withLock { () -> Int in
            lastReadID += 1
            return lastReadID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                lock.lock()
                if !buffered.isEmpty {
                    let chunk = buffered
                    buffered = Data()
                    let handler = drainHandler
                    lock.unlock()
                    continuation.resume(returning: chunk)
                    handler?()
                    return
                }
                if let failure {
                    lock.unlock()
                    continuation.resume(throwing: failure)
                    return
                }
                if isAtEnd || Task.isCancelled || reader != nil {
                    let overlapping = reader != nil
                    let atEnd = isAtEnd
                    lock.unlock()
                    if atEnd {
                        continuation.resume(returning: nil)
                    } else {
                        continuation.resume(throwing: overlapping ? SlskError(message: "overlapping reads") : CancellationError())
                    }
                    return
                }
                var deadline: DispatchWorkItem?
                if let timeout {
                    let item = DispatchWorkItem { [weak self] in
                        self?.endRead(id, with: SlskError(message: "nothing received for \(Int(timeout.rounded())) seconds"))
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
                    deadline = item
                }
                reader = Reader(id: id, continuation: continuation, deadline: deadline)
                lock.unlock()
            }
        } onCancel: {
            endRead(id, with: CancellationError())
        }
    }

    /// Bytes from the connection: straight to a waiting read, or into the buffer.
    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        guard let waiting = reader else {
            buffered.append(chunk)
            lock.unlock()
            return
        }
        reader = nil
        let handler = drainHandler
        lock.unlock()
        waiting.deadline?.cancel()
        waiting.continuation.resume(returning: chunk)
        handler?()
    }

    /// The connection closed — cleanly when `error` is nil. Buffered bytes are still read first.
    func finish(_ error: Error?) {
        lock.lock()
        guard !isAtEnd, failure == nil else {
            lock.unlock()
            return
        }
        if let error { failure = error } else { isAtEnd = true }
        // A waiting read means the buffer is empty.
        let waiting = reader
        reader = nil
        lock.unlock()
        guard let waiting else { return }
        waiting.deadline?.cancel()
        if let error {
            waiting.continuation.resume(throwing: error)
        } else {
            waiting.continuation.resume(returning: nil)
        }
    }

    private func endRead(_ id: Int, with error: Error) {
        lock.lock()
        guard let waiting = reader, waiting.id == id else {
            lock.unlock()
            return
        }
        reader = nil
        lock.unlock()
        waiting.deadline?.cancel()
        waiting.continuation.resume(throwing: error)
    }
}

// MARK: Listener

/// IPv4 TCP listener (the Soulseek network is IPv4-only).
final class SlskListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "susurrus.slsk.listener")
    private let lock = NSLock()
    /// The source was resumed once (it must be, before it's released — even if never started).
    private var isActive = false

    /// Binds the preferred port, falling back to an ephemeral one.
    init?(preferredPort: UInt16) {
        func bind(to port: UInt16, fd: Int32) -> Bool {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = INADDR_ANY
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        guard bind(to: preferredPort, fd: fd) || bind(to: 0, fd: fd), listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: bound.sin_port)
        guard port != 0 else {
            close(fd)
            return nil
        }

        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        self.fd = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { close(fd) }
    }

    deinit {
        // A source that was never started must still be activated before it's released.
        cancel()
    }

    func start(onAccept: @escaping @Sendable (SocketConnection) -> Void) {
        let fd = fd
        source.setEventHandler {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                onAccept(SocketConnection(fd: client))
            }
        }
        activate()
    }

    /// Stops listening and closes the socket.
    func cancel() {
        source.cancel()
        activate()
    }

    private func activate() {
        let wasActive = lock.withLock { () -> Bool in
            defer { isActive = true }
            return isActive
        }
        if !wasActive { source.resume() }
    }
}

// MARK: Accepted connections

/// Async reads/writes over a connected BSD socket. Reading runs ahead into an input buffer and
/// pauses while `readAhead` bytes wait unread, so a fast peer meets TCP flow control instead
/// of filling memory. Writes wait for the socket to drain; one that makes no progress for
/// `sendStallTimeout` fails, and so does the connection.
final class SocketConnection: SlskStream, @unchecked Sendable {
    private static let readAhead = 1 << 20
    static let sendStallTimeout: TimeInterval = 60

    private struct PendingWrite {
        let data: Data
        var offset = 0
        let continuation: CheckedContinuation<Void, Error>
    }

    private let fd: Int32
    private let queue = DispatchQueue(label: "susurrus.slsk.peer")
    private let readSource: DispatchSourceRead
    private let writeSource: DispatchSourceWrite
    private let input = SlskInputBuffer()

    // Everything below is touched on `queue` only.
    private var isReading = false
    private var isWaitingToWrite = false
    private var isClosed = false
    private var scratch = [UInt8](repeating: 0, count: 64 << 10)
    private var writes: [PendingWrite] = []
    private var lastWriteProgress = DispatchTime.now()
    private var isCheckingStall = false

    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var yes: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Writing to a peer that hung up must fail with an error, not SIGPIPE the app.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        writeSource.setEventHandler { [weak self] in self?.writeAvailable() }
        // The descriptor is closed once, after both sources are gone.
        let sources = DispatchGroup()
        sources.enter()
        sources.enter()
        readSource.setCancelHandler { sources.leave() }
        writeSource.setCancelHandler { sources.leave() }
        sources.notify(queue: queue) { Darwin.close(fd) }
        input.setDrainHandler { [weak self] in
            self?.queue.async { self?.resumeReading() }
        }
        queue.async { self.resumeReading() }
    }

    deinit {
        // Sources must not be released while suspended; cancelling closes the descriptor.
        guard !isClosed else { return }
        readSource.cancel()
        if !isReading { readSource.resume() }
        writeSource.cancel()
        if !isWaitingToWrite { writeSource.resume() }
    }

    func receive(timeout: TimeInterval?) async throws -> Data? {
        try await input.read(timeout: timeout)
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.isClosed else {
                    continuation.resume(throwing: SlskError(message: "connection closed"))
                    return
                }
                if self.writes.isEmpty { self.lastWriteProgress = .now() }
                self.writes.append(PendingWrite(data: data, continuation: continuation))
                self.writeAvailable()
            }
        }
    }

    func cancel() {
        queue.async { self.close(with: SlskError(message: "connection cancelled")) }
    }

    // MARK: Reading

    private func readAvailable() {
        guard !isClosed else { return }
        while input.count < Self.readAhead {
            let count = scratch.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                input.append(Data(scratch[0 ..< count]))
            } else if count == 0 {
                // End of stream: stop the source, or it reports the socket readable forever.
                input.finish(nil)
                pauseReading()
                return
            } else if errno == EWOULDBLOCK || errno == EAGAIN {
                return
            } else if errno == EINTR {
                continue
            } else {
                close(with: SlskError(message: "socket read failed (\(errno))"))
                return
            }
        }
        pauseReading()
    }

    private func pauseReading() {
        guard isReading else { return }
        readSource.suspend()
        isReading = false
    }

    private func resumeReading() {
        guard !isClosed, !isReading, !input.hasEnded, input.count < Self.readAhead else { return }
        isReading = true
        readSource.resume()
    }

    // MARK: Writing

    private func writeAvailable() {
        while let write = writes.first, !isClosed {
            let sent = write.data.withUnsafeBytes { bytes in
                Darwin.send(fd, bytes.baseAddress! + write.offset, bytes.count - write.offset, 0)
            }
            if sent > 0 {
                lastWriteProgress = .now()
                writes[0].offset += sent
                if writes[0].offset == writes[0].data.count {
                    writes.removeFirst().continuation.resume()
                }
            } else if sent == 0 || errno == EWOULDBLOCK || errno == EAGAIN {
                waitToWrite()
                return
            } else if errno == EINTR {
                continue
            } else {
                close(with: SlskError(message: "socket send failed (\(errno))"))
                return
            }
        }
        if isWaitingToWrite {
            writeSource.suspend()
            isWaitingToWrite = false
        }
    }

    private func waitToWrite() {
        if !isWaitingToWrite {
            isWaitingToWrite = true
            writeSource.resume()
        }
        scheduleStallCheck()
    }

    /// Fails the connection when the peer has accepted nothing for `sendStallTimeout`.
    private func scheduleStallCheck() {
        guard !isCheckingStall else { return }
        isCheckingStall = true
        queue.asyncAfter(deadline: lastWriteProgress + Self.sendStallTimeout) { [weak self] in
            guard let self else { return }
            self.isCheckingStall = false
            guard !self.writes.isEmpty, !self.isClosed else { return }
            if DispatchTime.now() >= self.lastWriteProgress + Self.sendStallTimeout {
                self.close(with: SlskError(message: "the peer stopped reading"))
            } else {
                self.scheduleStallCheck()
            }
        }
    }

    private func close(with error: Error) {
        guard !isClosed else { return }
        isClosed = true
        input.finish(error)
        let failed = writes
        writes = []
        for write in failed { write.continuation.resume(throwing: error) }
        readSource.cancel()
        if !isReading {
            isReading = true
            readSource.resume()
        }
        writeSource.cancel()
        if !isWaitingToWrite {
            isWaitingToWrite = true
            writeSource.resume()
        }
    }
}

// MARK: Outbound connections

/// Async wrapper around `NWConnection`, used for all outbound connections. Receives run ahead
/// into an input buffer (up to `readAhead` bytes), so reads can time out or be cancelled freely.
final class TCPConnection: SlskStream, @unchecked Sendable {
    private static let readAhead = 512 << 10
    /// A send still not handed to the network after this long means the peer stopped reading.
    static let sendStallTimeout: TimeInterval = 120

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "susurrus.slsk.tcp")
    private let input = SlskInputBuffer()
    private let lock = NSLock()
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var isReceiving = false
    private var isCancelled = false

    /// `keepAlive` probes an idle connection, so a dead one (after sleep, or a dropped network)
    /// is noticed within about a minute and a half.
    init(host: String, port: UInt16, keepAlive: Bool = false) {
        let parameters: NWParameters
        if keepAlive {
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 3
            parameters = NWParameters(tls: nil, tcp: tcp)
        } else {
            parameters = .tcp
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 2242,
            using: parameters
        )
        input.setDrainHandler { [weak self] in self?.receiveMore() }
    }

    /// Connects, giving up after `timeout` — or as soon as the peer refuses: Network.framework
    /// reports that as `.waiting` and would keep retrying until the deadline.
    func start(timeout: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !isCancelled else {
                    lock.unlock()
                    continuation.resume(throwing: SlskError(message: "connection cancelled"))
                    return
                }
                startContinuation = continuation
                lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.finishStart(nil)
                    case .waiting(let error), .failed(let error):
                        self?.finishStart(error)
                    case .cancelled:
                        self?.finishStart(SlskError(message: "connection cancelled"))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finishStart(SlskError(message: "connection timed out"))
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func finishStart(_ error: Error?) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        guard let continuation else { return }
        if let error {
            input.finish(error)
            connection.cancel()
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
            receiveMore()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outcome = SendOutcome()
            let deadline = DispatchWorkItem { [weak self] in
                guard outcome.claim() else { return }
                continuation.resume(throwing: SlskError(message: "the peer stopped reading"))
                self?.cancel()
            }
            outcome.deadline = deadline
            queue.asyncAfter(deadline: .now() + Self.sendStallTimeout, execute: deadline)
            connection.send(content: data, completion: .contentProcessed { error in
                guard outcome.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive(timeout: TimeInterval?) async throws -> Data? {
        try await input.read(timeout: timeout)
    }

    /// Keeps one receive outstanding while the input buffer has room.
    private func receiveMore() {
        lock.lock()
        guard !isReceiving, !isCancelled, startContinuation == nil, !input.hasEnded,
              input.count < Self.readAhead else {
            lock.unlock()
            return
        }
        isReceiving = true
        lock.unlock()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.lock.withLock { self.isReceiving = false }
            if let data, !data.isEmpty {
                self.input.append(data)
            } else if !isComplete, error == nil {
                self.input.finish(nil)
                return
            }
            if isComplete {
                self.input.finish(nil)
            } else if let error {
                self.input.finish(error)
            } else {
                self.receiveMore()
            }
        }
    }

    func cancel() {
        lock.withLock { isCancelled = true }
        finishStart(SlskError(message: "connection cancelled"))
        input.finish(SlskError(message: "connection cancelled"))
        connection.cancel()
    }
}

/// Settles a send exactly once: by its completion, or by the stall deadline.
private final class SendOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false
    private var stall: DispatchWorkItem?

    /// Fails the send when it fires first; cancelled once the send completes.
    var deadline: DispatchWorkItem? {
        get { lock.withLock { stall } }
        set { lock.withLock { stall = newValue } }
    }

    func claim() -> Bool {
        let (claimed, pending) = lock.withLock { () -> (Bool, DispatchWorkItem?) in
            defer { isSettled = true }
            return (!isSettled, stall)
        }
        if claimed { pending?.cancel() }
        return claimed
    }
}
