/// The conversations left most recently, oldest first, kept open so coming back to one is instant.
struct RecentTimelines<Entry> {
    /// With the open one, five live timelines: what a reader flips between in a session. Each holds its loaded
    /// history in memory and stays subscribed to sync, so the bound keeps both small.
    static var capacity: Int { 4 }
    private var entries: [(roomID: String, entry: Entry)] = []
    var roomIDs: [String] { entries.map(\.roomID) }

    func entry(_ roomID: String) -> Entry? { entries.first { $0.roomID == roomID }?.entry }

    mutating func take(_ roomID: String) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.roomID == roomID }) else { return nil }
        return entries.remove(at: index).entry
    }

    /// Returns what no longer fits, for the caller to close.
    mutating func keep(_ entry: Entry, for roomID: String) -> [Entry] {
        var dropped = take(roomID).map { [$0] } ?? []
        entries.append((roomID, entry))
        while entries.count > Self.capacity { dropped.append(entries.removeFirst().entry) }
        return dropped
    }

    mutating func removeAll() -> [Entry] {
        defer { entries = [] }
        return entries.map(\.entry)
    }
}
