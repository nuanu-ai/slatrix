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
        /// At the same moment saved beats removed, completed beats archived beats in progress, and a later reminder
        /// beats an earlier one or none, so a list an older build wrote back can't erase them.
        var rank: (Int64, Int, Int64) {
            let state = isSaved ? 1 + (LaterState.allCases.firstIndex(of: reference.laterState) ?? 0) : 0
            return (ts, state, reference.remindAt.map(SavedMessages.milliseconds) ?? -1)
        }
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
            var state: LaterState?
            var remindAt: Int64?
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case eventID = "event_id"
                case ts, state
                case remindAt = "remind_at"
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                roomID = try values.decode(String.self, forKey: .roomID)
                eventID = try values.decode(String.self, forKey: .eventID)
                ts = try values.decode(Int64.self, forKey: .ts)
                // What an entry adds to the ID and time never costs it its place.
                state = try? values.decodeIfPresent(LaterState.self, forKey: .state)
                remindAt = (try? values.decodeIfPresent(Int64.self, forKey: .remindAt)).flatMap { $0 }
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
                let remindAt = item.remindAt.flatMap { (0...Self.maxTimestamp).contains($0) ? Self.date($0) : nil }
                let reference = SavedMessageReference(
                    roomID: item.roomID, eventID: item.eventID, savedAt: Self.date(item.ts), state: item.state,
                    remindAt: remindAt)
                guard reference.hasValidIDs, (0...Self.maxTimestamp).contains(item.ts) else { return nil }
                return Self.entry(reference, saved: saved)
            }
        }
        self.init(entries(content.saved, saved: true) + entries(content.removed, saved: false))
    }

    private init(_ entries: [Entry]) {
        var latest: [Key: Entry] = [:]
        for entry in entries {
            if let kept = latest[entry.key], kept.rank >= entry.rank { continue }
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

    /// Saves or removes the message; a message already as asked, in any tab, stays as it is.
    func setting(roomID: String, eventID: String, saved isSaved: Bool, at now: Date) -> SavedMessages {
        guard (find(roomID, eventID) != nil) != isSaved else { return self }
        return stamped(SavedMessageReference(roomID: roomID, eventID: eventID), saved: isSaved, at: now)
    }

    /// Moves a saved message to another tab, clearing its reminder; one already there stays as it is.
    func changing(roomID: String, eventID: String, to state: LaterState, at now: Date) -> SavedMessages {
        guard let current = find(roomID, eventID), current.laterState != state else { return self }
        return stamped(SavedMessageReference(roomID: roomID, eventID: eventID, state: state), saved: true, at: now)
    }

    /// Sets the message's reminder, or clears it with nil, keeping it in progress and saving it if it wasn't.
    func reminding(roomID: String, eventID: String, at remindAt: Date?, now: Date) -> SavedMessages {
        let current = find(roomID, eventID)
        if remindAt == nil, current?.remindAt == nil { return self }
        if let current, current.laterState == .inProgress,
            current.remindAt.map(Self.milliseconds) == remindAt.map(Self.milliseconds)
        {
            return self
        }
        return stamped(
            SavedMessageReference(roomID: roomID, eventID: eventID, remindAt: remindAt), saved: true, at: now)
    }

    /// A tab's messages: In progress puts reminders first, soonest due first; every tab is otherwise newest first.
    func tab(_ state: LaterState) -> [SavedMessageReference] {
        let shown = saved.filter { $0.laterState == state }
        guard state == .inProgress else { return shown }
        let reminders = shown.compactMap { item in item.remindAt.map { (item, $0) } }.enumerated()
            .sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
        return reminders + shown.filter { $0.remindAt == nil }
    }

    /// The reminders still to come, soonest first: what a device notifies of.
    func reminders(after now: Date) -> [SavedMessageReference] {
        tab(.inProgress).filter { $0.remindAt.map { $0 > now } ?? false }
    }

    /// The content to write over the account's list, or nil when it already says the same.
    func content(over account: SavedMessages) -> String? { self == account ? nil : json }

    /// Both lists, newest first, as the account data event holds them.
    var json: String {
        func items(_ list: [SavedMessageReference]) -> [[String: Any]] {
            list.map {
                var item: [String: Any] = [
                    "room_id": $0.roomID, "event_id": $0.eventID, "ts": Self.milliseconds($0.savedAt),
                ]
                if let state = $0.state { item["state"] = state.rawValue }
                if let remindAt = $0.remindAt { item["remind_at"] = Self.milliseconds(remindAt) }
                return item
            }
        }
        let content: [String: Any] = ["saved": items(saved), "removed": items(removed)]
        let data = try? JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        return String(decoding: data ?? Data("{}".utf8), as: UTF8.self)
    }

    private func find(_ roomID: String, _ eventID: String) -> SavedMessageReference? {
        saved.first { $0.roomID == roomID && $0.eventID == eventID }
    }

    /// The new entry lands after any the message has, so a slow clock can't lose the change.
    private func stamped(_ change: SavedMessageReference, saved isSaved: Bool, at now: Date) -> SavedMessages {
        let previous = (saved + removed).filter { $0.roomID == change.roomID && $0.eventID == change.eventID }
            .map { Self.milliseconds($0.savedAt) }.max()
        var entry = change
        entry.savedAt = Self.date(max(Self.milliseconds(now), previous.map { $0 + 1 } ?? 0))
        if isSaved { return SavedMessages(saved: saved + [entry], removed: removed) }
        return SavedMessages(saved: saved, removed: removed + [entry])
    }

    private static func entry(_ reference: SavedMessageReference, saved: Bool) -> Entry {
        let ts = milliseconds(reference.savedAt)
        return Entry(
            reference: SavedMessageReference(
                roomID: reference.roomID, eventID: reference.eventID, savedAt: date(ts),
                state: saved ? reference.state : nil,
                remindAt: saved ? reference.remindAt.map { date(milliseconds($0)) } : nil),
            isSaved: saved, ts: ts)
    }
    /// The vault only holds finite dates.
    fileprivate static func milliseconds(_ date: Date) -> Int64 {
        Int64(min(max((date.timeIntervalSince1970 * 1_000).rounded(), 0), Double(maxTimestamp)))
    }
    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

/// Remind me's choices, as Slack offers them.
enum ReminderPreset: CaseIterable {
    case in20Minutes, in1Hour, in3Hours, tomorrow, nextWeek

    var title: String {
        switch self {
        case .in20Minutes: "In 20 minutes"
        case .in1Hour: "In 1 hour"
        case .in3Hours: "In 3 hours"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next week"
        }
    }

    /// Real minutes and hours from now; tomorrow and next week at 9:00 on the calendar's clock.
    func date(from now: Date, in calendar: Calendar = .current) -> Date {
        func nine(_ day: Date) -> Date { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day }
        let today = calendar.startOfDay(for: now)
        switch self {
        case .in20Minutes: return now.addingTimeInterval(20 * 60)
        case .in1Hour: return now.addingTimeInterval(60 * 60)
        case .in3Hours: return now.addingTimeInterval(3 * 60 * 60)
        case .tomorrow: return nine(calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        case .nextWeek:
            let monday = calendar.nextDate(
                after: today, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime)
            return nine(monday ?? today)
        }
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
            listener: AccountDataObserver { [weak self] content in
                // Read here, off the main thread, so a long list costs the window nothing.
                let remote = SavedMessages(json: content)
                Task { @MainActor in
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
        change(list.setting(roomID: roomID, eventID: eventID, saved: saved, at: Date()))
    }

    func set(roomID: String, eventID: String, state: LaterState) {
        change(list.changing(roomID: roomID, eventID: eventID, to: state, at: Date()))
    }

    func remind(roomID: String, eventID: String, at remindAt: Date?) {
        change(list.reminding(roomID: roomID, eventID: eventID, at: remindAt, now: Date()))
    }

    private func change(_ next: SavedMessages) {
        update(next)
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
