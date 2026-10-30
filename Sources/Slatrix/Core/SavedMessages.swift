import Foundation
import MatrixRustSDK
import Observation

/// Later, one list per account that every device shares through account data, by the rules in
/// `spec/saved-messages.json`. A message keeps only its latest entry, saved or removed, so merging two devices' lists
/// never loses a save and never brings back a removal. Only IDs and times, since the homeserver reads account data.
struct SavedMessages: Equatable, Sendable {
    static let eventType = "ai.nuanu.slatrix.later"
    /// Newest first.
    private(set) var saved: [SavedMessageReference] = []
    /// When each message left Later, newest first, so a device that still has it saved learns it went.
    private(set) var removed: [SavedMessageReference] = []

    private struct Key: Hashable {
        var roomID: String
        var eventID: String
    }
    private struct Entry {
        var reference: SavedMessageReference
        var isSaved: Bool
        var ts: Int64
        var key: Key { Key(roomID: reference.roomID, eventID: reference.eventID) }
    }
    private static let savedLimit = 10_000
    private static let removedLimit = 1_000
    /// The largest integer JSON numbers hold exactly.
    private static let maxTimestamp: Int64 = 9_007_199_254_740_991

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
                let reference = SavedMessageReference(
                    roomID: item.roomID, eventID: item.eventID, savedAt: Self.date(item.ts))
                guard reference.hasValidIDs, (0...Self.maxTimestamp).contains(item.ts) else { return nil }
                return Entry(reference: reference, isSaved: saved, ts: item.ts)
            }
        }
        self.init(entries(content.saved, saved: true) + entries(content.removed, saved: false))
    }

    private init(_ entries: [Entry]) {
        var latest: [Key: Entry] = [:]
        for entry in entries {
            if let kept = latest[entry.key], kept.ts > entry.ts || (kept.ts == entry.ts && !entry.isSaved) { continue }
            latest[entry.key] = entry
        }
        let ordered = latest.values.sorted { a, b in
            if a.ts != b.ts { return a.ts > b.ts }
            if a.reference.roomID != b.reference.roomID { return a.reference.roomID < b.reference.roomID }
            return a.reference.eventID < b.reference.eventID
        }
        saved = Array(ordered.filter(\.isSaved).map(\.reference).prefix(Self.savedLimit))
        removed = Array(ordered.filter { !$0.isSaved }.map(\.reference).prefix(Self.removedLimit))
    }

    /// What this device and the account know between them.
    func merged(with other: SavedMessages) -> SavedMessages {
        SavedMessages(saved: saved + other.saved, removed: removed + other.removed)
    }

    /// Saves or removes the message, stamped after any entry it has so a slow clock can't lose the change; a message
    /// already as asked stays as it is.
    func setting(roomID: String, eventID: String, saved isSaved: Bool, at now: Date) -> SavedMessages {
        let same = { (item: SavedMessageReference) in item.roomID == roomID && item.eventID == eventID }
        guard saved.contains(where: same) != isSaved else { return self }
        let previous = (saved + removed).filter(same).map { Self.milliseconds($0.savedAt) }.max()
        let ts = max(Self.milliseconds(now), previous.map { $0 + 1 } ?? 0)
        let entry = SavedMessageReference(roomID: roomID, eventID: eventID, savedAt: Self.date(ts))
        if isSaved { return SavedMessages(saved: saved + [entry], removed: removed) }
        return SavedMessages(saved: saved, removed: removed + [entry])
    }

    /// The content to write over the account's list, or nil when it already says the same.
    func content(over account: SavedMessages) -> String? { self == account ? nil : json }

    /// Both lists, newest first, as the account data event holds them.
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
    /// The vault only holds finite dates.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(min(max((date.timeIntervalSince1970 * 1_000).rounded(), 0), Double(maxTimestamp)))
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
/// and writes back whatever this device holds that the account lacks. It writes only over a list read from the server
/// or heard from a sync, never the store's, which lags until the first sync. A failed write stays here and goes again
/// with the next change or sync, or once the connection is back and the account has been read again.
@MainActor
@Observable final class SavedMessagesService {
    private(set) var list = SavedMessages()
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var handle: TaskHandle?
    @ObservationIgnored private var writer: Task<Void, Never>?
    @ObservationIgnored private var changes: AsyncStream<Void>.Continuation?
    /// The account's list as last read, heard or written; nil until read, so nothing is written over a list unseen.
    @ObservationIgnored private var published: SavedMessages?
    /// Lists heard from the account, so a write knows whether one landed while it was out.
    @ObservationIgnored private var heardCount = 0

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
        self.client = client
        if let accountID { switchAccount(to: accountID) }
        guard let client else { return }
        let session = session
        handle = client.observeRawAccountDataEvent(
            eventType: SavedMessages.eventType,
            listener: AccountDataObserver { content in
                // Read here, off the main thread, so a long list costs the window nothing.
                let remote = SavedMessages(json: content)
                Task { @MainActor [weak self] in
                    guard let self, self.session == session else { return }
                    self.receive(remote)
                }
            })
        // One write at a time; a change while one is out waits for it, and a failed one waits for the next change.
        let (stream, changes) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.changes = changes
        writer = Task { [weak self] in
            for await _ in stream {
                guard let self, let published = self.published else { continue }
                let next = self.list
                let heardCount = self.heardCount
                // A reconnection or a list heard while encoding means the account's list is no longer `published`.
                guard let content = await Self.content(next, over: published), self.published != nil,
                    self.heardCount == heardCount
                else { continue }
                guard (try? await client.setAccountData(eventType: SavedMessages.eventType, content: content)) != nil,
                    self.session == session
                else { continue }
                // A list heard meanwhile may have landed after this write, so it stands for the account's.
                if self.heardCount == heardCount { self.published = next }
            }
        }
        read()
    }

    /// What the device's vault held for the account when it opened.
    func merge(_ local: SavedMessages, accountID: String) {
        switchAccount(to: accountID)
        update(list.merged(with: local))
    }

    func set(roomID: String, eventID: String, saved: Bool) {
        update(list.setting(roomID: roomID, eventID: eventID, saved: saved, at: Date()))
        // Until the account is read nothing is written, so a read that failed must not hold this back.
        if published == nil { read() }
    }

    /// The connection is back: what the account held before may have changed, so read it again before writing.
    func resume() {
        published = nil
        read()
    }

    private func read() {
        guard let client else { return }
        let session = session
        Task { [weak self] in
            guard let remote = await Self.fetch(client) else { return }
            // A sync that answered meanwhile is at least as new.
            guard let self, self.session == session, self.published == nil else { return }
            self.receive(remote)
        }
    }

    private func switchAccount(to accountID: String) {
        guard accountID != self.accountID else { return }
        self.accountID = accountID
        list = SavedMessages()
    }

    private func receive(_ remote: SavedMessages) {
        published = remote
        heardCount += 1
        update(list.merged(with: remote))
    }

    private func update(_ next: SavedMessages) {
        if next != list { list = next }
        changes?.yield()
    }

    /// The account's list from the server, read off the main thread; nil when the server can't be reached.
    private nonisolated static func fetch(_ client: Client) async -> SavedMessages? {
        do { return SavedMessages(json: try await client.fetchAccountData(eventType: SavedMessages.eventType)) } catch {
            return nil
        }
    }

    /// Off the main thread, as `fetch`.
    private nonisolated static func content(_ list: SavedMessages, over account: SavedMessages) async -> String? {
        list.content(over: account)
    }
}
