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

    /// Row heights the last few timelines' tables measured, by row ID, each with a hash of the row and the table it
    /// was measured for, so the next table on a timeline measures none of the rows it shows the same way. Hashes, so
    /// no message outlives its table.
    static var heights: [(key: Key, rows: [String: (fingerprint: Int, height: CGFloat)])] = []
}
