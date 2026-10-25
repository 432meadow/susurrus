import Foundation

/// Callers waiting for an answer that arrives some other way — a server reply, a peer's message,
/// a pierced connection — keyed by what identifies the answer (a username, a token). Every wait
/// has its own deadline; one that times out, is cancelled or fails gets nil.
///
/// Register before sending the request, so even an instant answer finds its waiter:
///
///     let ticket = addresses.register(user, timeout: 8)
///     try await server.send(request)
///     let address = await addresses.wait(ticket)
final class SlskWaiters<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    struct Ticket: Sendable {
        let key: Key
        fileprivate let id: Int
    }

    private enum Slot {
        /// Registered; nobody is waiting yet.
        case open
        case waiting(CheckedContinuation<Value?, Never>)
        /// Settled before anyone waited.
        case settled(Value?)
    }

    private let lock = NSLock()
    private var slots: [Key: [Int: Slot]] = [:]
    private var lastID = 0

    func register(_ key: Key, timeout: TimeInterval) -> Ticket {
        let ticket = lock.withLock { () -> Ticket in
            lastID += 1
            slots[key, default: [:]][lastID] = .open
            return Ticket(key: key, id: lastID)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.settle(ticket, with: nil)
        }
        return ticket
    }

    /// The answer, or nil when the deadline passed, the wait was cancelled or the key failed.
    func wait(_ ticket: Ticket) async -> Value? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                lock.lock()
                switch slots[ticket.key]?[ticket.id] {
                case .open:
                    slots[ticket.key]?[ticket.id] = .waiting(continuation)
                    lock.unlock()
                case .settled(let value):
                    remove(ticket)
                    lock.unlock()
                    continuation.resume(returning: value)
                case .waiting, nil:
                    lock.unlock()
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            settle(ticket, with: nil)
        }
    }

    /// Hands `value` to every unsettled ticket for `key`; false when there was none.
    @discardableResult
    func resolve(_ key: Key, with value: Value) -> Bool {
        settleAll(key, with: value)
    }

    /// Ends every unsettled ticket for `key` with nil (the answer can't come any more).
    @discardableResult
    func fail(_ key: Key) -> Bool {
        settleAll(key, with: nil)
    }

    /// Drops a ticket nobody will wait for (its request couldn't be sent).
    func cancel(_ ticket: Ticket) {
        lock.lock()
        let slot = slots[ticket.key]?[ticket.id]
        remove(ticket)
        lock.unlock()
        if case .waiting(let continuation) = slot { continuation.resume(returning: nil) }
    }

    /// True while some ticket for `key` is still unsettled.
    func isWaiting(for key: Key) -> Bool {
        lock.withLock {
            slots[key]?.values.contains { if case .settled = $0 { false } else { true } } ?? false
        }
    }

    /// Ends every wait with nil (the connection is going away).
    func failAll() {
        lock.lock()
        let all = slots
        slots = [:]
        lock.unlock()
        for byID in all.values {
            for case .waiting(let continuation) in byID.values { continuation.resume(returning: nil) }
        }
    }

    private func settle(_ ticket: Ticket, with value: Value?) {
        lock.lock()
        switch slots[ticket.key]?[ticket.id] {
        case .open:
            slots[ticket.key]?[ticket.id] = .settled(value)
            lock.unlock()
        case .waiting(let continuation):
            remove(ticket)
            lock.unlock()
            continuation.resume(returning: value)
        case .settled, nil:
            lock.unlock()
        }
    }

    private func settleAll(_ key: Key, with value: Value?) -> Bool {
        lock.lock()
        guard let byID = slots[key] else {
            lock.unlock()
            return false
        }
        var waiting: [CheckedContinuation<Value?, Never>] = []
        var settledAny = false
        for (id, slot) in byID {
            switch slot {
            case .open:
                slots[key]?[id] = .settled(value)
                settledAny = true
            case .waiting(let continuation):
                slots[key]?[id] = nil
                waiting.append(continuation)
                settledAny = true
            case .settled:
                break
            }
        }
        if slots[key]?.isEmpty == true { slots[key] = nil }
        lock.unlock()
        for continuation in waiting { continuation.resume(returning: value) }
        return settledAny
    }

    /// Call with the lock held.
    private func remove(_ ticket: Ticket) {
        slots[ticket.key]?[ticket.id] = nil
        if slots[ticket.key]?.isEmpty == true { slots[ticket.key] = nil }
    }
}
