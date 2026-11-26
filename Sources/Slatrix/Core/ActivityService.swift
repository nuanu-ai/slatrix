import Foundation
import MatrixRustSDK
import Observation

struct ActivityItem: Identifiable, Hashable {
    enum Kind: String, Hashable { case message, invite, reaction }
    var id: String
    var roomID: String
    var eventID: String?
    var roomName: String
    var senderID: String
    var senderName: String
    var body: String
    var timestamp: Date
    var hasMention: Bool
    var threadRootID: String?
    var kind: Kind
    var avatarURL: String? = nil
    var allowsNativeNotification = true
    /// The reader has seen its message, so it leaves Activity’s count.
    var opened = false
}

/// Activity's red count, as in Slack: unread mentions, thread replies Activity lists that you haven't opened, and
/// invitations. Direct messages and channels keep their own badges, so their messages count only as mentions.
enum ActivityBadge {
    /// Rooms and activity items in the shown workspace, excluding rooms you already left so a left room's old reply
    /// can never keep a phantom count on Activity.
    static func scoped(rooms: [ChatRoom], items: [ActivityItem], workspaceID: String?) -> (
        rooms: [ChatRoom], items: [ActivityItem]
    ) {
        let scopedRooms = rooms.filter { room in
            room.membership != "leave"
                && (room.membership == "invite"
                    || (!room.isSpace
                        && WorkspaceMembership.includes(
                            direct: room.isDirect, spaceIDs: room.spaceIDs, spaceID: workspaceID)))
        }
        let ids = Set(scopedRooms.map(\.id))
        let inviteIDs = Set(scopedRooms.filter { $0.membership == "invite" }.map(\.id))
        let scopedItems = items.filter { item in
            ids.contains(item.roomID) && (item.kind != .invite || inviteIDs.contains(item.roomID))
        }
        return (scopedRooms, scopedItems)
    }

    /// Whether Activity lists `room` in its Unread / Mentions summary: every room counted by the badge (invitations
    /// and rooms with mentions, even when `hasUnread` is false) is always surfaced, while muted rooms without mentions
    /// or a manual unread flag stay quiet.
    static func isSummaryRoom(_ room: ChatRoom, mentionsOnly: Bool) -> Bool {
        room.membership != "leave"
            && (room.membership == "invite"
                || (mentionsOnly ? room.mentions > 0 : UnreadBadge(room) != .none))
    }

    static func count(rooms: [ChatRoom], items: [ActivityItem]) -> Int {
        let mentions = rooms.reduce(0) { count, room in
            switch room.membership {
            case "invite": count + 1
            case "leave": count
            default: count + room.mentions
            }
        }
        // A reply that mentions you already counts through its room's mentions.
        return mentions + items.count { $0.kind == .message && $0.threadRootID != nil && !$0.hasMention && !$0.opened }
    }

    /// Whether Activity marks the item unread: a thread reply until you open it, a mention until you open it or read
    /// its conversation's mentions, anything else until you open it or read its conversation, so the marks match what
    /// the count holds.
    static func isUnread(_ item: ActivityItem, room: ChatRoom?) -> Bool {
        guard !item.opened else { return false }
        if item.kind == .invite { return true }
        if item.kind == .message && item.threadRootID != nil && !item.hasMention { return true }
        guard let room else { return false }
        return item.hasMention ? room.mentions > 0 : UnreadBadge(room) != .none
    }

    /// Whether a server read receipt at `(receiptEventID, receiptTimestampMs)` covers `item`. Reactions match by
    /// timestamp only because `item.eventID` is the reacted message, which may have been read before the reaction.
    static func isCoveredByReceipt(
        _ item: ActivityItem, receiptEventID: String, receiptTimestampMs: UInt64?
    ) -> Bool {
        if item.kind != .reaction, let eventID = item.eventID, receiptEventID == eventID { return true }
        guard let receiptTimestampMs else { return false }
        let itemMs = UInt64(max(0, (item.timestamp.timeIntervalSince1970 * 1000).rounded()))
        return receiptTimestampMs >= itemMs
    }
}

@MainActor
@Observable final class ActivityService {
    private(set) var items: [ActivityItem] = []
    var mentions: [ActivityItem] { items.filter(\.hasMention) }
    private var seen: [String] = []
    private var seenIDs = Set<String>()
    static let maximumItems = 300

    func clear() {
        items = []
        seen = []
        seenIDs = []
    }

    /// Only notifications delivered by SDK sync enter this session-local feed.
    @discardableResult
    func receive(
        _ notification: NotificationItem, roomID: String, ownUserID: String, names: [String: String] = [:],
        receivedAt: Date = Date()
    ) -> ActivityItem? {
        var item: ActivityItem
        switch notification.event {
        case .timeline(let event):
            // Deleted before it synced, it still notifies; it leaves no row and no banner.
            guard event.senderId() != ownUserID, !MatrixMapping.isRedacted(event) else { return nil }
            var body = "Message preview unavailable"
            var kind: ActivityItem.Kind = .message
            var targetEventID = event.eventId()
            if let content = try? event.content() {
                guard case .messageLike(let like) = content else { return nil }
                switch like {
                case .roomMessage(let type, let inReplyTo):
                    let reply = inReplyTo != nil
                    switch type {
                    case .text(let value):
                        body = Self.previewBody(value.body, formatted: value.formatted, names: names, reply: reply)
                    case .notice(let value):
                        body = Self.previewBody(value.body, formatted: value.formatted, names: names, reply: reply)
                    case .emote(let value):
                        body = Self.previewBody(value.body, formatted: value.formatted, names: names, reply: reply)
                    default: body = "Shared an attachment"
                    }
                case .reactionContent(let relatedEventID):
                    kind = .reaction
                    targetEventID = relatedEventID
                    let key = Self.reactionKey(notification.rawEvent)
                    body = key.isEmpty ? "Reacted to a message" : "Reacted \(key)"
                case .poll(let question): body = "Poll: " + String(question.prefix(4096))
                case .sticker: body = "Shared a sticker"
                case .roomEncrypted: body = "Encrypted message · Unlock encryption to read it"
                default: return nil
                }
            }
            item = ActivityItem(
                id: Self.key(roomID: roomID, eventID: event.eventId()), roomID: roomID, eventID: targetEventID,
                roomName: notification.roomInfo.displayName, senderID: event.senderId(),
                senderName: Self.senderName(notification, event.senderId()), body: String(body.prefix(4096)),
                timestamp: Date(timeIntervalSince1970: Double(event.timestamp()) / 1000),
                hasMention: kind == .message && notification.hasMention == true,
                threadRootID: kind == .message ? (notification.threadId ?? event.threadRootEventId()) : nil,
                kind: kind, avatarURL: notification.senderInfo.avatarUrl)
        case .invite(let sender):
            item = ActivityItem(
                id: Self.key(roomID: roomID, eventID: "invite:\(sender)"), roomID: roomID, eventID: nil,
                roomName: notification.roomInfo.displayName, senderID: sender,
                senderName: Self.senderName(notification, sender),
                body: "You were invited to this conversation", timestamp: receivedAt, hasMention: false,
                threadRootID: nil, kind: .invite, avatarURL: notification.senderInfo.avatarUrl)
        }
        item.allowsNativeNotification = notification.actions.map { $0.contains(.notify) } ?? true
        return record(item) ? item : nil
    }

    private nonisolated static func reactionKey(_ rawEvent: String) -> String {
        guard let data = rawEvent.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [String: Any],
            let relatesTo = content["m.relates_to"] as? [String: Any],
            let key = relatesTo["key"] as? String
        else { return "" }
        return key
    }

    private nonisolated static func senderName(_ notification: NotificationItem, _ userID: String) -> String {
        DisplayNames.name(
            userID, member: notification.senderInfo.displayName, ambiguous: notification.senderInfo.isNameAmbiguous)
    }

    nonisolated static func key(roomID: String, eventID: String) -> String {
        "\(roomID.utf8.count):\(roomID)\(eventID)"
    }

    nonisolated static func previewBody(
        _ body: String, formatted: FormattedBody?, names: [String: String] = [:], reply: Bool = false
    )
        -> String
    {
        String(
            MatrixMapping.previewText(
                reply ? DesktopMessageNotification.withoutReplyFallback(body) : body, formatted: formatted,
                names: names
            ).prefix(4096))
    }

    nonisolated static func previewBody(for message: ChatMessage, names: [String: String] = [:]) -> String {
        String(MatrixMapping.messagePreviewText(message, names: names).prefix(4096))
    }

    /// The people a message notification mentions, so their names can be looked up before it shows.
    nonisolated static func mentionedIDs(_ notification: NotificationItem) -> Set<String> {
        guard case .timeline(let event) = notification.event,
            case .messageLike(.roomMessage(let type, _))? = try? event.content()
        else { return [] }
        let text: (body: String, formatted: FormattedBody?)
        switch type {
        case .text(let value): text = (value.body, value.formatted)
        case .notice(let value): text = (value.body, value.formatted)
        case .emote(let value): text = (value.body, value.formatted)
        default: return []
        }
        let runs = MessageBodyRenderer.shared.render(
            body: text.body, formattedBody: MatrixMapping.htmlBody(text.formatted)
        ).runs
        return Set(runs.compactMap(\.mention).filter { $0 != "@room" })
    }

    /// Drops the rows of deleted messages, by key. They stay recorded, so they never come back.
    func remove(_ keys: Set<String>) {
        let kept = items.filter { !keys.contains($0.id) }
        if kept.count != items.count { items = kept }
    }

    /// Opens the items whose message the reader has seen.
    func markSeen(_ isSeen: (ActivityItem) -> Bool) {
        for index in items.indices where !items[index].opened && isSeen(items[index]) { items[index].opened = true }
    }

    @discardableResult
    func record(_ item: ActivityItem) -> Bool {
        if seenIDs.contains(item.id) {
            // A later decryption may improve the same notification without notifying twice.
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                var updated = item
                if updated.kind == .invite { updated.timestamp = items[index].timestamp }
                updated.opened = items[index].opened
                items[index] = updated
            }
            return false
        }
        seenIDs.insert(item.id)
        seen.append(item.id)
        if seen.count > Self.maximumItems * 4 { seenIDs.remove(seen.removeFirst()) }
        items.append(item)
        items.sort { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp > $1.timestamp }
        if items.count > Self.maximumItems { items.removeLast(items.count - Self.maximumItems) }
        return true
    }
}
