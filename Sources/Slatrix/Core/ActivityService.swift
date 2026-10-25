import Foundation
import MatrixRustSDK
import Observation

struct ActivityItem: Identifiable, Hashable {
    enum Kind: String, Hashable { case message, invite }
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
    func receive(_ notification: NotificationItem, roomID: String, ownUserID: String, receivedAt: Date = Date())
        -> ActivityItem?
    {
        var item: ActivityItem
        switch notification.event {
        case .timeline(let event):
            guard event.senderId() != ownUserID else { return nil }
            var body = "Message preview unavailable"
            if let content = try? event.content() {
                guard case .messageLike(let like) = content else { return nil }
                switch like {
                case .roomMessage(let type, _):
                    switch type {
                    case .text(let value): body = Self.previewBody(value.body, formatted: value.formatted)
                    case .notice(let value): body = Self.previewBody(value.body, formatted: value.formatted)
                    case .emote(let value): body = Self.previewBody(value.body, formatted: value.formatted)
                    default: body = "Shared an attachment"
                    }
                case .poll(let question): body = "Poll: " + String(question.prefix(4096))
                case .sticker: body = "Shared a sticker"
                case .roomEncrypted: body = "Encrypted message · Unlock encryption to read it"
                default: return nil
                }
            }
            item = ActivityItem(
                id: Self.key(roomID: roomID, eventID: event.eventId()), roomID: roomID, eventID: event.eventId(),
                roomName: notification.roomInfo.displayName, senderID: event.senderId(),
                senderName: notification.senderInfo.displayName ?? event.senderId(), body: String(body.prefix(4096)),
                timestamp: Date(timeIntervalSince1970: Double(event.timestamp()) / 1000),
                hasMention: notification.hasMention == true,
                threadRootID: notification.threadId ?? event.threadRootEventId(), kind: .message,
                avatarURL: notification.senderInfo.avatarUrl)
        case .invite(let sender):
            item = ActivityItem(
                id: Self.key(roomID: roomID, eventID: "invite:\(sender)"), roomID: roomID, eventID: nil,
                roomName: notification.roomInfo.displayName, senderID: sender,
                senderName: notification.senderInfo.displayName ?? sender,
                body: "You were invited to this conversation", timestamp: receivedAt, hasMention: false,
                threadRootID: nil, kind: .invite, avatarURL: notification.senderInfo.avatarUrl)
        }
        item.allowsNativeNotification = notification.actions.map { $0.contains(.notify) } ?? true
        return record(item) ? item : nil
    }

    nonisolated static func key(roomID: String, eventID: String) -> String {
        "\(roomID.utf8.count):\(roomID)\(eventID)"
    }

    nonisolated static func previewBody(_ body: String, formatted: FormattedBody?) -> String {
        MatrixMapping.htmlBody(formatted)?.localizedCaseInsensitiveContains("data-mx-spoiler") == true
            ? "[Spoiler hidden]" : String(body.prefix(4096))
    }

    @discardableResult
    func record(_ item: ActivityItem) -> Bool {
        if seenIDs.contains(item.id) {
            // A later decryption may improve the same notification without notifying twice.
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                var updated = item
                if updated.kind == .invite { updated.timestamp = items[index].timestamp }
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
