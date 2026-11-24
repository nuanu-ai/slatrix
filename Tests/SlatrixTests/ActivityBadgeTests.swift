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

    @Test("Left rooms and out-of-workspace replies never leave a phantom count on Activity")
    func scopedExcludesLeftRoomsAndMatchesFeed() {
        var joined = ChatRoom(id: "!joined", name: "Joined", mentions: 1)
        joined.spaceIDs = ["!space-a"]
        var left = ChatRoom(id: "!left", name: "Left", mentions: 2)
        left.membership = "leave"
        left.spaceIDs = ["!space-a"]
        var otherSpace = ChatRoom(id: "!other", name: "Other", mentions: 1)
        otherSpace.spaceIDs = ["!space-b"]
        var spaceInvite = ChatRoom(id: "!space-c", name: "Space C")
        spaceInvite.isSpace = true
        spaceInvite.membership = "invite"

        let leftReply = ActivityItem(
            id: "left-reply", roomID: "!left", eventID: "$r1", roomName: "Left",
            senderID: "@alice:example.org", senderName: "Alice", body: "Reply",
            timestamp: Date(timeIntervalSince1970: 1), hasMention: false, threadRootID: "$root", kind: .message)
        let joinedReply = ActivityItem(
            id: "joined-reply", roomID: "!joined", eventID: "$r2", roomName: "Joined",
            senderID: "@alice:example.org", senderName: "Alice", body: "Reply",
            timestamp: Date(timeIntervalSince1970: 2), hasMention: false, threadRootID: "$root", kind: .message)

        let scope = ActivityBadge.scoped(
            rooms: [joined, left, otherSpace, spaceInvite], items: [leftReply, joinedReply], workspaceID: "!space-a")
        #expect(scope.rooms.map(\.id) == ["!joined", "!space-c"])
        #expect(scope.items.map(\.id) == ["joined-reply"])
        #expect(ActivityBadge.count(rooms: scope.rooms, items: scope.items) == 3)
        // Every joined room counted by the badge (even with mentions > 0 and hasUnread == false) must appear in All.
        #expect(ActivityBadge.isSummaryRoom(joined, mentionsOnly: false))
        #expect(ActivityBadge.isSummaryRoom(joined, mentionsOnly: true))
        #expect(!ActivityBadge.isSummaryRoom(left, mentionsOnly: false))
        #expect(ActivityBadge.isSummaryRoom(spaceInvite, mentionsOnly: false))
    }
}
