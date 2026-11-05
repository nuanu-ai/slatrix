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

    @Test("Opening a thread takes its replies off the count, and a reply decrypted again stays opened")
    func openingThread() {
        let activity = ActivityService()
        activity.record(Self.reply(0))
        activity.markThreadOpened(roomID: "!room-0", rootID: "$root")
        activity.record(Self.reply(0))
        #expect(ActivityBadge.count(rooms: [], items: activity.items) == 0)
    }
}
