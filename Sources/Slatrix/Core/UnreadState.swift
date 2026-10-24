import Foundation
import MatrixRustSDK

enum UnreadNavigation {
    // Counts decide whether to offer an existing anchor, never where unread
    // messages start. Explicit history/thread navigation always wins.
    static func resumeAnchor(for room: ChatRoom?, selectedRoomID: String?, explicitEventID: String?, opensThread: Bool)
        -> String?
    {
        guard let room, room.id != selectedRoomID, room.membership == "join",
            room.unreadMessages > 0 || room.unread > 0, explicitEventID == nil, !opensThread,
            let id = room.fullyReadEventID, isRemoteEventID(id)
        else { return nil }
        return id
    }

    static func isRemoteEventID(_ id: String) -> Bool {
        MatrixID.isValid(id, sigil: "$")
    }
}

enum UnreadMapping {
    static func firstUnreadEventID(in items: [TimelineItem], roomID: String, ownUserID: String?) -> String? {
        var afterMarker = false
        for item in items {
            if item.asVirtual() == .readMarker {
                afterMarker = true
                continue
            }
            guard afterMarker, let event = item.asEvent(), event.isRemote,
                case .eventId(let id) = event.eventOrTransactionId, UnreadNavigation.isRemoteEventID(id),
                MatrixMapping.message(event, roomID: roomID, ownUserID: ownUserID) != nil
            else { continue }
            return id
        }
        return nil
    }

}

@MainActor
enum UnreadSDKActions {
    static func acknowledge(timeline: Timeline, eventID: String, validate: () throws -> Void) async throws {
        try validate()
        try await timeline.sendReadReceipt(receiptType: .read, eventId: eventID)
        try validate()
        try await timeline.sendReadReceipt(receiptType: .fullyRead, eventId: eventID)
        try validate()
    }

    static func markRoomRead(room: Room, validate: () throws -> Void) async throws {
        try validate()
        try await room.markAsRead(receiptType: .read)
        try validate()
        try await room.markAsRead(receiptType: .fullyRead)
        try validate()
    }

    static func loadForward(timeline: Timeline, validate: () throws -> Void) async throws -> Bool {
        try validate()
        let endReached = try await timeline.paginateForwards(numEvents: 50)
        try validate()
        return endReached
    }
}
