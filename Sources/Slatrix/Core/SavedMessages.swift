import Foundation
import MatrixRustSDK
import Observation

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
            var roomID: String
            var eventID: String
            var ts: Int64
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case eventID = "event_id"
                case ts
            }
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
                guard ProtectedLocalState.validID(item.roomID), item.roomID.hasPrefix("!"),
                    ProtectedLocalState.validID(item.eventID), item.eventID.hasPrefix("$"),
                    (0...9_007_199_254_740_991).contains(item.ts)
                else { return nil }
                return Entry(
                    reference: SavedMessageReference(
                        roomID: item.roomID, eventID: item.eventID, savedAt: Self.date(item.ts)),
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
        if isSaved { return SavedMessages(saved: saved, removed: removed + [entry]) }
        return SavedMessages(saved: saved + [entry], removed: removed)
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
    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

private final class AccountDataObserver: RawAccountDataListener {
    let callback: @Sendable (String) -> Void
    init(_ callback: @escaping @Sendable (String) -> Void) { self.callback = callback }
    func onChange(content: String) { callback(content) }
}

/// Keeps an account's Later in step with its account data: merges what other devices write as each sync brings it,
/// and writes back whatever this device holds that the account lacks. A failed write stays here and goes again with
/// the next change, sync or reconnection.
@MainActor
@Observable final class SavedMessagesService {
    private(set) var list = SavedMessages()
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var handle: TaskHandle?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var changes: AsyncStream<Void>.Continuation?
    /// The account's list as last read or written; nil until read, so nothing is written over a list not yet seen.
    @ObservationIgnored private var published: SavedMessages?
    /// Lists heard from the account, so a write knows whether one landed while it was out.
    @ObservationIgnored private var heard = 0

    /// The signed-in account's client, or nil on sign-out. The list stays with its account until another account, or
    /// the preview, takes over, so the last save to the device's vault still has it.
    func attach(_ client: Client?, accountID: String?) {
        handle?.cancel()
        handle = nil
        writer?.cancel()
        changes?.finish()
        changes = nil
        published = nil
        session = UUID()
        if let accountID { own(accountID) }
        guard let client else { return }
        let session = session
        handle = client.observeRawAccountDataEvent(
            eventType: SavedMessages.eventType,
            listener: AccountDataObserver { content in
                Task { @MainActor [weak self] in
                    guard let self, self.session == session else { return }
                    self.receive(content)
                }
            })
        Task { [weak self] in
            let stored: String?
            do { stored = try await client.accountData(eventType: SavedMessages.eventType) } catch { return }
            // A sync that already answered is at least as new as the store.
            guard let self, self.session == session, self.published == nil else { return }
            self.receive(stored)
        }
        // One write at a time; a change while one is out waits for it, and a failed one waits for the next change.
        let (stream, changes) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.changes = changes
        writer = Task { [weak self] in
            for await _ in stream {
                guard let self, let published = self.published, self.list != published else { continue }
                let next = self.list
                let heard = self.heard
                guard (try? await client.setAccountData(eventType: SavedMessages.eventType, content: next.json)) != nil,
                    self.session == session
                else { continue }
                // A list heard meanwhile may have landed after this write, so it stands for the account's.
                if self.heard == heard { self.published = next }
            }
        }
    }

    /// What the device's vault held for the account when it opened.
    func merge(_ local: SavedMessages, accountID: String) {
        own(accountID)
        update(list.merged(with: local))
    }

    func toggle(roomID: String, eventID: String) {
        update(list.toggled(roomID: roomID, eventID: eventID, at: Date()))
    }

    /// Writes what an earlier attempt couldn't, now the connection is back.
    func resume() { changes?.yield() }

    private func own(_ accountID: String) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        list = SavedMessages()
    }

    private func receive(_ content: String?) {
        let remote = SavedMessages(json: content)
        published = remote
        heard += 1
        update(list.merged(with: remote))
    }

    private func update(_ next: SavedMessages) {
        if next != list { list = next }
        changes?.yield()
    }
}
