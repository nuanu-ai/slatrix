import Foundation

/// Later, one list per account that every device shares through account data, by the rules in
/// `spec/saved-messages.json`. A message keeps only its latest entry, saved or removed, so merging two devices' lists
/// never loses a save and never brings back a removal. Only IDs and times, since the homeserver reads account data.
struct SavedMessages: Equatable {
    static let eventType = "ai.nuanu.slatrix.later"
    /// Newest first.
    private(set) var saved: [SavedMessageReference] = []
    /// When each message left Later, newest first, so a device that still has it saved learns it went.
    private(set) var removed: [SavedMessageReference] = []

    private struct Entry {
        var reference: SavedMessageReference
        var isSaved: Bool
        var ts: Int64
    }
    private static let removalMemory: Int64 = 90 * 86_400_000
    private static let limit = 10_000

    init(saved: [SavedMessageReference] = [], removed: [SavedMessageReference] = []) {
        self.init(saved.map { Self.entry($0, saved: true) } + removed.map { Self.entry($0, saved: false) })
    }

    /// The content of the account data event; nil, or anything that breaks the rules, reads as nothing saved.
    init(json: String?) {
        struct Item: Decodable {
            var room_id: String
            var event_id: String
            var ts: Int64
        }
        struct Lenient: Decodable {
            var item: Item?
            init(from decoder: Decoder) throws { item = try? Item(from: decoder) }
        }
        struct Content: Decodable {
            var saved: [Lenient]?
            var removed: [Lenient]?
        }
        guard let json, let content = try? JSONDecoder().decode(Content.self, from: Data(json.utf8)) else {
            self.init()
            return
        }
        func entries(_ items: [Lenient]?, saved: Bool) -> [Entry] {
            (items ?? []).compactMap(\.item).compactMap { item in
                guard ProtectedLocalState.validID(item.room_id), item.room_id.hasPrefix("!"),
                    ProtectedLocalState.validID(item.event_id), item.event_id.hasPrefix("$"),
                    (0...9_007_199_254_740_991).contains(item.ts)
                else { return nil }
                return Entry(
                    reference: SavedMessageReference(
                        roomID: item.room_id, eventID: item.event_id, savedAt: Self.date(item.ts)),
                    isSaved: saved, ts: item.ts)
            }
        }
        self.init(entries(content.saved, saved: true) + entries(content.removed, saved: false))
    }

    private init(_ entries: [Entry]) {
        var latest: [String: Entry] = [:]
        for entry in entries {
            if let kept = latest[entry.reference.id], kept.ts > entry.ts || (kept.ts == entry.ts && !entry.isSaved) {
                continue
            }
            latest[entry.reference.id] = entry
        }
        let newest = latest.values.map(\.ts).max() ?? 0
        let ordered = latest.values.sorted { a, b in
            if a.ts != b.ts { return a.ts > b.ts }
            if a.reference.roomID != b.reference.roomID { return a.reference.roomID < b.reference.roomID }
            return a.reference.eventID < b.reference.eventID
        }
        saved = Array(ordered.filter(\.isSaved).map(\.reference).prefix(Self.limit))
        removed = Array(
            ordered.filter { !$0.isSaved && newest - $0.ts <= Self.removalMemory }.map(\.reference).prefix(Self.limit))
    }

    /// What this device and the account know between them.
    func merged(with other: SavedMessages) -> SavedMessages {
        SavedMessages(saved: saved + other.saved, removed: removed + other.removed)
    }

    /// Saves the message, or removes it when it's saved, stamped after any entry it has so a slow clock can't lose it.
    func toggled(roomID: String, eventID: String, at now: Date) -> SavedMessages {
        let reference = SavedMessageReference(roomID: roomID, eventID: eventID)
        let isSaved = saved.contains { $0.id == reference.id }
        let previous = (saved + removed).filter { $0.id == reference.id }.map { Self.milliseconds($0.savedAt) }.max()
        let ts = max(Self.milliseconds(now), previous.map { $0 + 1 } ?? 0)
        let entry = SavedMessageReference(roomID: roomID, eventID: eventID, savedAt: Self.date(ts))
        return isSaved ? SavedMessages(saved: saved, removed: removed + [entry]) : SavedMessages(
            saved: saved + [entry], removed: removed)
    }

    /// The content to write: both lists, newest first.
    var json: String {
        func items(_ list: [SavedMessageReference]) -> [[String: Any]] {
            list.map { ["room_id": $0.roomID, "event_id": $0.eventID, "ts": Self.milliseconds($0.savedAt)] }
        }
        let content: [String: Any] = ["saved": items(saved), "removed": items(removed)]
        let data = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func entry(_ reference: SavedMessageReference, saved: Bool) -> Entry {
        let ts = milliseconds(reference.savedAt)
        return Entry(
            reference: SavedMessageReference(roomID: reference.roomID, eventID: reference.eventID, savedAt: date(ts)),
            isSaved: saved, ts: ts)
    }
    /// Within what JSON holds exactly; the vault only holds finite dates.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(min(max((date.timeIntervalSince1970 * 1_000).rounded(), 0), 9_007_199_254_740_991))
    }
    private static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1_000) }
}
