import AppKit
import Foundation
import Observation

/// One line in a private conversation.
struct SoulseekChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var isOutgoing: Bool
    /// Waited on the server while we were offline, and arrived at login.
    var wasOffline = false
    /// Couldn't be handed to the server (not connected).
    var failed = false
}

/// Everything said between us and one user.
struct SoulseekConversation: Codable, Identifiable, Equatable {
    var user: String
    var messages: [SoulseekChatMessage] = []
    var unread = 0
    /// When the conversation was opened, so a new empty one sorts to the top.
    var started = Date()

    var id: String { user }
    var lastDate: Date { messages.last?.date ?? started }
}

/// Private conversations, latest first, kept in one JSON file in the app's support folder.
@MainActor
@Observable
final class SoulseekChats {
    private(set) var conversations: [SoulseekConversation] = []

    @ObservationIgnored private let fileURL: URL?
    private static let maxMessagesPerConversation = 2000
    /// Beyond this many conversations, the oldest ones without unread messages are let go.
    private static let maxConversations = 500
    nonisolated private static let writeQueue = DispatchQueue(label: "susurrus.soulseek.chats", qos: .utility)
    /// The latest history per file, waiting to be written; touched on `writeQueue` only.
    nonisolated(unsafe) private static var pendingWrites: [URL: [SoulseekConversation]] = [:]
    nonisolated(unsafe) private static var isWriteScheduled = false
    private static var flushesAtQuit = false

    nonisolated static var defaultURL: URL {
        LibraryStore.supportDirectory.appendingPathComponent("susurrus/Soulseek/Messages.json")
    }

    /// `fileURL` nil keeps history in memory only.
    init(fileURL: URL? = SoulseekChats.defaultURL) {
        self.fileURL = fileURL
        if fileURL != nil, !Self.flushesAtQuit {
            Self.flushesAtQuit = true
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
                SoulseekChats.flushWrites()
            }
        }
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([SoulseekConversation].self, from: data) {
            conversations = saved.sorted { $0.lastDate > $1.lastDate }
        }
    }

    var unreadTotal: Int { conversations.reduce(0) { $0 + $1.unread } }

    func conversation(with user: String) -> SoulseekConversation? {
        conversations.first { $0.user == user }
    }

    /// Makes sure a conversation with `user` exists (for "Message user").
    func open(_ user: String) {
        guard conversation(with: user) == nil else { return }
        conversations.insert(SoulseekConversation(user: user), at: 0)
        trimConversations(keeping: user)
        save()
    }

    /// Files an incoming message; `unread` false when the user is looking at the conversation.
    func receive(_ message: SlskPrivateMessage, unread: Bool) {
        append(SoulseekChatMessage(
            date: message.timestamp, text: message.message, isOutgoing: false, wasOffline: !message.isNew),
               to: message.username, unread: unread)
    }

    /// Files one of our messages; returns its ID so a failed send can be marked.
    @discardableResult
    func addOutgoing(_ text: String, to user: String) -> UUID {
        let message = SoulseekChatMessage(date: Date(), text: text, isOutgoing: true)
        append(message, to: user, unread: false)
        return message.id
    }

    func markFailed(_ id: UUID, in user: String) {
        guard let index = conversations.firstIndex(where: { $0.user == user }),
              let messageIndex = conversations[index].messages.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].messages[messageIndex].failed = true
        save()
    }

    func markRead(_ user: String) {
        guard let index = conversations.firstIndex(where: { $0.user == user }),
              conversations[index].unread > 0 else { return }
        conversations[index].unread = 0
        save()
    }

    func remove(_ user: String) {
        conversations.removeAll { $0.user == user }
        save()
    }

    private func append(_ message: SoulseekChatMessage, to user: String, unread: Bool) {
        var conversation = conversations.first { $0.user == user } ?? SoulseekConversation(user: user)
        conversations.removeAll { $0.user == user }
        // Offline messages carry the time the server got them; keep the thread in order.
        if let last = conversation.messages.last, last.date > message.date {
            let index = conversation.messages.lastIndex { $0.date <= message.date }.map { $0 + 1 } ?? 0
            conversation.messages.insert(message, at: index)
        } else {
            conversation.messages.append(message)
        }
        if conversation.messages.count > Self.maxMessagesPerConversation {
            conversation.messages.removeFirst(conversation.messages.count - Self.maxMessagesPerConversation)
        }
        if unread { conversation.unread += 1 }
        let position = conversations.firstIndex { $0.lastDate <= conversation.lastDate } ?? conversations.count
        conversations.insert(conversation, at: position)
        trimConversations(keeping: user)
        save()
    }

    /// Lets the oldest read conversations go once there are too many.
    private func trimConversations(keeping user: String) {
        while conversations.count > Self.maxConversations,
              let oldest = conversations.lastIndex(where: { $0.unread == 0 && $0.user != user }) {
            conversations.remove(at: oldest)
        }
    }

    /// Saves the whole history soon: changes in quick succession (a burst of offline messages)
    /// are written once, encoded off the main thread.
    private func save() {
        guard let fileURL else { return }
        let conversations = conversations
        Self.writeQueue.async {
            Self.pendingWrites[fileURL] = conversations
            guard !Self.isWriteScheduled else { return }
            Self.isWriteScheduled = true
            Self.writeQueue.asyncAfter(deadline: .now() + 0.5) { Self.writePending() }
        }
    }

    /// Call on `writeQueue`.
    nonisolated private static func writePending() {
        isWriteScheduled = false
        let writes = pendingWrites
        pendingWrites = [:]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (url, conversations) in writes {
            guard let data = try? encoder.encode(conversations) else { continue }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Writes pending changes now (at quit, and in tests that read the file straight back).
    nonisolated static func flushWrites() {
        writeQueue.sync { writePending() }
    }
}
