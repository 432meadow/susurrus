import SwiftUI

// MARK: - User menu

/// The per-user actions every Soulseek right-click menu offers.
struct SoulseekUserMenu: View {
    let soulseek: SoulseekModel
    let user: String
    var showsBrowse = true

    var body: some View {
        Button("Message \(user)") { soulseek.message(user) }
        Button("Show Info for \(user)") { soulseek.showUserInfo(user) }
        if showsBrowse {
            Button("Browse \(user)'s Files") { soulseek.browse(user: user) }
        }
        if soulseek.blockedUsers.contains(user) {
            Button("Unblock \(user)") { soulseek.unblock(user) }
        } else {
            Button("Block \(user)") { soulseek.block(user) }
        }
    }
}

// MARK: - Online status

/// A small dot for a user's status: rose online, ochre away, hollow offline or unknown.
struct UserStatusDot: View {
    let status: SlskUserStatus?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .help(Self.text(for: status))
            // The colour alone doesn't say it.
            .accessibilityLabel(Self.text(for: status))
    }

    private var color: Color {
        switch status {
        case .online: Palette.warm
        case .away: Palette.ochre
        case .offline, nil: .secondary.opacity(0.35)
        }
    }

    static func text(for status: SlskUserStatus?) -> String {
        switch status {
        case .online: "Online"
        case .away: "Away"
        case .offline: "Offline"
        case nil: "Status unknown"
        }
    }
}

// MARK: - Messages tab

/// Private conversations: the list (latest first, unread counts) on the left, the chosen
/// conversation and a reply field on the right.
struct MessagesPane: View {
    @Environment(AppModel.self) private var model
    @State private var conversationToDelete: String?

    private var soulseek: SoulseekModel { model.soulseek }

    var body: some View {
        @Bindable var soulseek = soulseek
        Group {
            if soulseek.chats.conversations.isEmpty {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Enter a username above, or right-click a search result, transfer or browsed user ▸ Message. Messages sent to you while you're offline wait on the server and arrive when you next connect.")
                )
            } else {
                HSplitView {
                    List(selection: $soulseek.selectedConversation) {
                        ForEach(soulseek.chats.conversations) { conversation in
                            ConversationRow(
                                conversation: conversation,
                                status: soulseek.userDetails[conversation.user]?.status)
                                .badge(conversation.unread)
                                .tag(conversation.user)
                                .contextMenu {
                                    SoulseekUserMenu(soulseek: soulseek, user: conversation.user)
                                    Divider()
                                    Button("Delete Conversation…", role: .destructive) {
                                        conversationToDelete = conversation.user
                                    }
                                }
                        }
                    }
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
                    Group {
                        if let user = soulseek.selectedConversation, let conversation = soulseek.chats.conversation(with: user) {
                            // A fresh view per user: drafts and focus never carry over to someone else.
                            ConversationView(conversation: conversation)
                                .id(user)
                        } else {
                            ContentUnavailableView("Choose a Conversation", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .alert(
            "Delete the conversation with \(conversationToDelete ?? "")?",
            isPresented: Binding(get: { conversationToDelete != nil }, set: { if !$0 { conversationToDelete = nil } }),
            presenting: conversationToDelete
        ) { user in
            Button("Delete", role: .destructive) { soulseek.removeConversation(user) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its messages are removed from this Mac. This can't be undone.")
        }
        .onAppear { soulseek.isShowingMessages = true }
        .onDisappear { soulseek.isShowingMessages = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-mark: messages that came in while susurrus was in the background stay unread
            // until it's in front again.
            soulseek.isShowingMessages = true
        }
    }
}

private struct ConversationRow: View {
    let conversation: SoulseekConversation
    let status: SlskUserStatus?

    var body: some View {
        HStack(spacing: 8) {
            UserStatusDot(status: status)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(conversation.user)
                        .fontWeight(conversation.unread > 0 ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer()
                    Text(conversation.lastDate.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var preview: String {
        guard let last = conversation.messages.last else { return "No messages yet" }
        return last.isOutgoing ? "You: \(last.text)" : last.text
    }
}

/// One conversation: a header with the user's status and actions, the messages, a reply field.
private struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let conversation: SoulseekConversation
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    private var soulseek: SoulseekModel { model.soulseek }
    private var user: String { conversation.user }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(conversation.messages.enumerated()), id: \.element.id) { index, message in
                            if showsTime(at: index) {
                                Text(message.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 6)
                            }
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: conversation.messages.last?.id) { _, _ in scrollToEnd(proxy, animated: true) }
            }
            Divider()
            composer
        }
        .onAppear {
            draft = soulseek.messageDrafts[user] ?? ""
            draftFocused = true
        }
        .onChange(of: draft) { _, text in
            soulseek.messageDrafts[user] = text.isEmpty ? nil : text
        }
    }

    private var header: some View {
        let details = soulseek.userDetails[user]
        return HStack(spacing: 8) {
            UserStatusDot(status: details?.status)
            Text(user).font(.headline)
            Text(UserStatusDot.text(for: details?.status))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Info") { soulseek.showUserInfo(user) }
            Button("Browse Files") { soulseek.browse(user: user) }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField(soulseek.blockedUsers.contains(user) ? "\(user) is blocked" : "Message \(user)", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1 ... 5)
                .focused($draftFocused)
                .onSubmit(send)
                .disabled(soulseek.blockedUsers.contains(user))
            Button("Send", action: send)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || soulseek.blockedUsers.contains(user))
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        soulseek.send(text, to: user)
        draft = ""
    }

    /// A timestamp above the first message and after any lull of ten minutes or more.
    private func showsTime(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let messages = conversation.messages
        return messages[index].date.timeIntervalSince(messages[index - 1].date) >= 600
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = false) {
        guard let last = conversation.messages.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

private struct MessageBubble: View {
    let message: SoulseekChatMessage

    var body: some View {
        HStack {
            if message.isOutgoing { Spacer(minLength: 60) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(message.isOutgoing ? Palette.cool.opacity(0.35) : Color.secondary.opacity(0.12))
                    )
                    .help(message.date.formatted(date: .abbreviated, time: .shortened))
                if message.failed {
                    Label("Not sent — susurrus wasn't connected", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.ochre)
                } else if message.wasOffline {
                    Text("Sent while you were offline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !message.isOutgoing { Spacer(minLength: 60) }
        }
    }
}

// MARK: - User info sheet

/// What we know about one user: online status and server stats, plus the description,
/// picture and upload slots they report, with Browse, Message and Block.
struct UserInfoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let user: String

    private var soulseek: SoulseekModel { model.soulseek }
    private var details: SoulseekUserDetails { soulseek.userDetails[user] ?? SoulseekUserDetails() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                picture
                VStack(alignment: .leading, spacing: 4) {
                    Text(user).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        UserStatusDot(status: details.status)
                        Text(UserStatusDot.text(for: details.status))
                        if details.privileged {
                            Text("· Privileged")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                if let stats = details.stats {
                    row("Shares", "\(stats.files.formatted()) files in \(stats.folders.formatted()) folders")
                    row("Upload speed", stats.averageSpeed > 0
                        ? "\(ByteCountFormatter.string(fromByteCount: Int64(stats.averageSpeed), countStyle: .file))/s average"
                        : "–")
                    row("Uploads", stats.uploadCount.formatted())
                }
                if case .loaded(let info) = details.info {
                    row("Upload slots", "\(info.uploadSlots.formatted())\(info.slotFree ? ", one free now" : ", all busy")")
                    row("Queue", info.queueLength == 0 ? "Empty" : "\(info.queueLength.formatted()) waiting")
                }
            }
            .font(.callout)

            description

            HStack {
                Button("Browse Files") {
                    soulseek.browse(user: user)
                    dismiss()
                }
                Button("Message") {
                    soulseek.message(user)
                    dismiss()
                }
                if soulseek.blockedUsers.contains(user) {
                    Button("Unblock") { soulseek.unblock(user) }
                } else {
                    Button("Block") { soulseek.block(user) }
                }
                Spacer()
                Button("Refresh") { soulseek.requestUserInfo(user) }
                    .disabled(isLoading)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var isLoading: Bool {
        if case .loading = details.info { true } else { false }
    }

    @ViewBuilder private var picture: some View {
        if case .loaded(let info) = details.info, let data = info.picture, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "person.crop.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
        }
    }

    @ViewBuilder private var description: some View {
        switch details.info {
        case .notRequested, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking \(user) about themselves…").foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .loaded(let info):
            ScrollView {
                Text(info.description.isEmpty ? "No description." : info.description)
                    .foregroundStyle(info.description.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
