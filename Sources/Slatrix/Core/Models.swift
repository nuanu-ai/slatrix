import Foundation

enum ConnectionStatus: String { case signedOut, connecting, syncing, ready, error }

struct Workspace: Identifiable, Hashable {
    var id: String
    var name: String
    var topic: String? = nil
    var canInvite: Bool? = nil
    var canManageRooms: Bool? = nil
    var avatarURL: String? = nil
    /// No joined space lists it as a child, so it gets its own icon in the rail.
    var isTopLevel = true
}

struct ChatRoom: Identifiable, Hashable {
    var id: String
    var name: String
    var topic: String = ""
    var isDirect = false
    var isEncrypted = false
    /// Slack's private channel: no one joins without an invitation.
    var isPrivate = false
    var unread = 0
    var unreadMessages = 0
    var isMarkedUnread = false
    var hasUnread: Bool { isMarkedUnread || unreadMessages > 0 || unread > 0 }
    var mentions = 0
    var favorite = false
    var muted = false
    var memberCount = 0
    var spaceIDs: [String] = []
    var membership = "join"
    var avatarURL: String? = nil
    var pinnedEventIDs: [String] = []
    var canPinMessages: Bool? = nil
    var fullyReadEventID: String? = nil
    var isSpace = false
    var directParentSpaceIDs: [String] = []
    var canInvite: Bool? = nil
    /// nil until the room's power levels are known; the composer shows until then.
    var canPostMessages: Bool? = nil
    /// Read for direct messages only, which the DMs page lists with it.
    var latest: LatestMessage? = nil

    /// The name in running text: Slack's "#design" for a channel anyone can join. Text has no lock, so a private
    /// channel reads as its bare name, like a person.
    var writtenName: String { isDirect || isPrivate ? name : "#" + name }

    /// The DMs list: the newest conversation first, then those with nothing to show yet by name. "Find a DM" narrows
    /// it by name, and Unreads to unread conversations and the one open.
    static func directMessages(
        _ rooms: [ChatRoom], matching search: String = "", unreadOnly: Bool = false, keeping openID: String? = nil
    ) -> [ChatRoom] {
        rooms.filter {
            $0.isDirect && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
                && (!unreadOnly || UnreadBadge($0) != .none || $0.id == openID)
        }.sorted {
            let (first, second) = ($0.latest?.timestamp ?? .distantPast, $1.latest?.timestamp ?? .distantPast)
            if first != second { return first > second }
            let names = $0.name.localizedStandardCompare($1.name)
            return names != .orderedSame ? names == .orderedAscending : $0.id < $1.id
        }
    }
}

/// A conversation's newest event; `body` is nil when there is nothing to preview, such as a membership change.
struct LatestMessage: Hashable {
    var body: String?
    var timestamp: Date
    var isOwn: Bool

    /// Slack marks your own message.
    var preview: String? { body.map { isOwn ? "You: \($0)" : $0 } }

    /// The time today, "Yesterday" the day before, and the date before that.
    func time(now: Date = Date(), calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle(
            locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(timestamp, inSameDayAs: now) { return timestamp.formatted(style.hour().minute()) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(timestamp, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        style = style.month(.abbreviated).day()
        let sameYear = calendar.isDate(timestamp, equalTo: now, toGranularity: .year)
        return timestamp.formatted(sameYear ? style : style.year())
    }
}

struct ChatUser: Identifiable, Hashable {
    var id: String
    var name: String
    var avatarURL: String? = nil
    /// "join", "invite", "leave", "ban" or "knock", as a room's member list has it.
    var membership = "join"
}

struct ChatMessage: Identifiable, Hashable {
    /// Stable identity in an open timeline: the SDK item's unique ID, which a local echo keeps when its remote event
    /// arrives. Messages from anywhere else are identified by their event ID.
    var id: String
    var roomID: String
    var senderID: String
    var senderName: String
    var body: String
    var formattedBody: String? = nil
    var timestamp: Date
    var kind: String = "m.text"
    var reactions: [MessageReaction] = []
    var replyCount = 0
    /// Who replied last in this message's thread, and when, from the thread summary.
    var lastReply: ThreadReply? = nil
    var threadRootID: String? = nil
    var isEdited = false
    var isRedacted = false
    var sendState = "sent"
    var attachment: MessageAttachment? = nil
    var replyToID: String? = nil
    var avatarURL: String? = nil
    var replyPreview: ChatReplyPreview? = nil
    var mediaCaption: String? = nil
    /// Set when `id` is a timeline item ID rather than the event ID.
    var timelineEventID: String? = nil
    /// The remote event ID, or the transaction ID of a local echo.
    var eventID: String { timelineEventID ?? id }
    var supportsCaptionEditing: Bool { ["m.image", "m.file"].contains(kind) && attachment != nil }
    var showsMessageBody: Bool {
        if supportsCaptionEditing { return mediaCaption.map { !$0.isEmpty } ?? false }
        return !body.isEmpty && (attachment == nil || body != attachment?.name)
    }
    // The current edit composer submits Markdown as m.text. Other message
    // kinds need their own type-preserving edit/caption payload first.
    var supportsTextEditing: Bool { kind == "m.text" && attachment == nil }
}

/// A message the reader asked to see, from pins, Later, search or a reply quote. Each jump is new, so jumping to the
/// same message again scrolls back to it.
struct MessageJump: Equatable {
    let roomID: String
    let eventID: String
    /// Set when the message is a thread reply: the conversation shows the root, the thread's pane the reply.
    var threadRootID: String? = nil
    let id = UUID()

    /// The message a pane scrolls to and highlights: the conversation's when `thread` is nil, else that thread's.
    func eventID(inThread thread: String?) -> String? {
        guard let thread else { return threadRootID ?? eventID }
        return thread == threadRootID ? eventID : nil
    }
}

struct ChatReplyPreview: Hashable {
    enum State: String, Hashable { case unavailable, pending, ready, failed }
    var state: State
    var eventID: String
    var senderID: String = ""
    var senderName: String = ""
    var body: String = ""
    var kind: String = "m.text"
    var isRedacted = false
}

struct MessageReaction: Hashable {
    var key: String
    var count: Int
    var mine: Bool
    /// User IDs, in the order they reacted.
    var senders: [String] = []
}

struct ThreadReply: Hashable {
    var senderID: String
    var senderName: String
    var avatarURL: String?
    var timestamp: Date

    /// "Last reply 2 hours ago", as Slack's replies bar puts it.
    static func lastReplyText(_ date: Date, now: Date, locale: Locale = .current) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Last reply just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return "Last reply " + formatter.localizedString(for: date, relativeTo: now)
    }
}

struct MessageAttachment: Hashable {
    var name: String
    var url: String
    var mimeType: String? = nil
    var size: UInt64? = nil
    /// Pixel dimensions from the event, so the image's box is reserved before its thumbnail loads.
    var width: UInt64? = nil
    var height: UInt64? = nil
    /// A GIF or another animated image, which plays inline.
    var animated = false
    /// A video's length.
    var duration: TimeInterval? = nil
}
