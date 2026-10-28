import Testing

@testable import Slatrix

/// Runs the shared cases in `spec/unread-badge.json`.
struct UnreadBadgeTests {
    struct Room: Decodable {
        var direct, muted, markedUnread, space: Bool?
        var messages, notifications, mentions: Int?
        var membership: String?

        var chatRoom: ChatRoom {
            var room = ChatRoom(id: "!room", name: "room")
            room.isDirect = direct ?? false
            room.muted = muted ?? false
            room.isMarkedUnread = markedUnread ?? false
            room.isSpace = space ?? false
            room.unreadMessages = messages ?? 0
            room.unread = notifications ?? 0
            room.mentions = mentions ?? 0
            room.membership = membership ?? "join"
            return room
        }
    }

    struct One: Decodable, CustomTestStringConvertible {
        var name: String
        var room: Room
        var badge: String
        var testDescription: String { name }
    }

    struct Combined: Decodable, CustomTestStringConvertible {
        var name: String
        var rooms: [Room]
        var badge: String
        var testDescription: String { name }
    }

    struct Spec: Decodable {
        var badge: [One]
        var combined: [Combined]
    }

    private static func label(_ badge: UnreadBadge) -> String {
        switch badge {
        case .none: "none"
        case .bold: "bold"
        case .count(let count): count
        }
    }

    @Test("A conversation's row", arguments: try SharedSpec.decode("spec/unread-badge.json", as: Spec.self).badge)
    func badge(spec: One) {
        #expect(Self.label(UnreadBadge(spec.room.chatRoom)) == spec.badge)
    }

    @Test(
        "The collapsed sidebar's button, for every conversation at once",
        arguments: try SharedSpec.decode("spec/unread-badge.json", as: Spec.self).combined)
    func combined(spec: Combined) {
        #expect(Self.label(UnreadBadge.combined(spec.rooms.map(\.chatRoom))) == spec.badge)
    }
}
