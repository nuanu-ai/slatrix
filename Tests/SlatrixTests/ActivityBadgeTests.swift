import Foundation
import Testing

@testable import Slatrix

/// Runs the shared cases in `spec/activity-badge.json`.
@MainActor
struct ActivityBadgeTests {
    struct Room: Decodable {
        var mentions: Int?
        var membership: String?
    }

    struct Reply: Decodable {
        var mention, opened: Bool?
    }

    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var rooms: [Room]
        var replies: [Reply]
        var count: Int
        var testDescription: String { name }
    }

    struct Spec: Decodable { var count: [Case] }

    private static func reply(_ index: Int, mention: Bool = false) -> ActivityItem {
        ActivityItem(
            id: "reply-\(index)", roomID: "!room-0", eventID: "$reply-\(index)", roomName: "room",
            senderID: "@alice:example.org", senderName: "Alice", body: "Reply",
            timestamp: Date(timeIntervalSince1970: 1), hasMention: mention, threadRootID: "$root", kind: .message)
    }

    // capability: activity.badge
    @Test("Activity's count", arguments: try SharedSpec.decode("spec/activity-badge.json", as: Spec.self).count)
    func count(spec: Case) {
        let rooms = spec.rooms.enumerated().map { index, room in
            var chatRoom = ChatRoom(id: "!room-\(index)", name: "room")
            chatRoom.mentions = room.mentions ?? 0
            chatRoom.membership = room.membership ?? "join"
            return chatRoom
        }
        let items = spec.replies.enumerated().map { index, reply in
            var item = Self.reply(index, mention: reply.mention ?? false)
            item.opened = reply.opened ?? false
            return item
        }
        #expect(ActivityBadge.count(rooms: rooms, items: items) == spec.count)
    }

    @Test("Only the replies the reader has seen leave the count, and one decrypted again stays seen")
    func seeingReplies() {
        let activity = ActivityService()
        activity.record(Self.reply(0))
        activity.record(Self.reply(1))
        activity.markSeen { $0.id == Self.reply(0).id }
        activity.record(Self.reply(0))
        #expect(ActivityBadge.count(rooms: [], items: activity.items) == 1)
    }

    @Test("A mention shows unread until it's opened or read, whatever chat comes after it")
    func mentionUnread() {
        var room = ChatRoom(id: "!room-0", name: "room")
        room.mentions = 1
        var mention = Self.reply(0, mention: true)
        mention.threadRootID = nil
        #expect(ActivityBadge.isUnread(mention, room: room))
        room.mentions = 0
        room.unreadMessages = 2
        #expect(!ActivityBadge.isUnread(mention, room: room))
        room.mentions = 1
        mention.opened = true
        #expect(!ActivityBadge.isUnread(mention, room: room))
    }
}
