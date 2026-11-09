import Foundation

/// Reading positions outlive loaded history; opening a room can load the remembered event again.
@MainActor enum TimelineMemory {
    struct Key: Hashable {
        var sessionID: UUID
        var roomID: String
        var threadRootID: String? = nil
    }

    struct Anchor {
        var eventID: String
        var offset: CGFloat
    }

    static var positions: [Key: Anchor] = [:]
}
