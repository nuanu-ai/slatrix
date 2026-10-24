import Foundation

/// A length prefix keeps room and event IDs unambiguous, including non-ASCII Matrix IDs.
struct ThreadDraftAddress: Hashable, Identifiable {
    var roomID: String
    var rootID: String
    var id: String { SavedMessageReference(roomID: roomID, eventID: rootID).id }

    init(roomID: String, rootID: String) {
        self.roomID = roomID
        self.rootID = rootID
    }
    init?(id: String) {
        guard id.utf8.count <= 4_128, let separator = id.firstIndex(of: ":"),
            let count = Int(id[..<separator]), count > 0, count <= 2_048
        else { return nil }
        let contents = Array(id[id.index(after: separator)...].utf8)
        guard contents.count > count,
            let room = String(bytes: contents.prefix(count), encoding: .utf8),
            let root = String(bytes: contents.dropFirst(count), encoding: .utf8),
            room.hasPrefix("!"), root.hasPrefix("$"),
            ProtectedLocalState.validID(room), ProtectedLocalState.validID(root)
        else { return nil }
        self.init(roomID: room, rootID: root)
        guard self.id == id else { return nil }
    }
}
