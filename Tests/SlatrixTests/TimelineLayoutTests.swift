import Foundation
import Testing

@testable import Slatrix

struct TimelineLayoutTests {
    // UTC+8, so 23:00 UTC on the 21st is already the 22nd here.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }()
    private static let locale = Locale(identifier: "en_US")
    /// Thursday 23 October 2025, 12:00 at UTC+8.
    private static let now = Date(timeIntervalSince1970: 1_761_192_000)

    @Test("A hovered message's time in the gutter leaves out AM and PM, which don't fit there")
    func gutterTime() {
        func time(_ date: Date) -> String {
            TimelineLayout.gutterTime(date, calendar: Self.calendar, locale: Self.locale)
        }
        #expect(time(Self.now) == "12:00")
        #expect(time(Self.now.addingTimeInterval(65 * 60)) == "1:05")
    }

    private func message(_ id: String, _ sender: String, at minutesBeforeNow: Double) -> ChatMessage {
        ChatMessage(
            id: id, roomID: "!room:example.org", senderID: sender, senderName: sender, body: id,
            timestamp: Self.now.addingTimeInterval(-minutesBeforeNow * 60))
    }

    private func layout(
        _ messages: [ChatMessage], unread: String? = nil, groups: Bool = true, threadRoot: String? = nil,
        repliesLine: Int? = nil
    ) -> [String] {
        TimelineLayout.rows(
            messages, unreadBoundaryEventID: unread, groups: groups, threadRootEventID: threadRoot,
            repliesLine: repliesLine, now: Self.now, calendar: Self.calendar, locale: Self.locale
        ).map { row in
            switch row.kind {
            case .day(let label): "day \(label)"
            case .unread: "unread"
            case .replies(let count): "\(count) replies"
            case .message(let message, let grouped, let time): "\(message.id)\(grouped ? " grouped" : "") \(time)"
            }
        }.map { $0.replacingOccurrences(of: "\u{202F}", with: " ") }
    }

    // capability: conversation.grouping
    @Test("Messages from one person within five minutes group under one header")
    func groupsBySenderAndTime() {
        let rows = layout([
            message("a", "@alice", at: 30), message("b", "@alice", at: 27), message("c", "@bob", at: 26),
            message("d", "@bob", at: 20), message("e", "@bob", at: 10),
        ])
        #expect(rows == ["day Today", "a 11:30 AM", "b grouped 11:33 AM", "c 11:34 AM", "d 11:40 AM", "e 11:50 AM"])
    }

    struct GroupingCase: Decodable, CustomTestStringConvertible {
        struct Message: Decodable {
            var sender: String
            var second: Double
        }
        var name: String
        var messages: [Message]
        var grouped: [Bool]
        var testDescription: String { name }
    }

    struct GroupingSpec: Decodable { var cases: [GroupingCase] }

    // capability: conversation.grouping
    @Test(
        "Grouping matches the shared cases",
        arguments: try SharedSpec.decode("spec/message-grouping.json", as: GroupingSpec.self).cases)
    func sharedGrouping(spec: GroupingCase) {
        let messages = spec.messages.enumerated().map { index, message in
            ChatMessage(
                id: "m\(index)", roomID: "!room:example.org", senderID: message.sender, senderName: message.sender,
                body: "", timestamp: Self.now.addingTimeInterval(message.second))
        }
        let grouped = TimelineLayout.rows(
            messages, unreadBoundaryEventID: nil, groups: true, now: Self.now, calendar: Self.calendar,
            locale: Self.locale
        ).compactMap { row -> Bool? in
            if case .message(_, let grouped, _) = row.kind { grouped } else { nil }
        }
        #expect(grouped == spec.grouped)
    }

    @Test("Compact density never groups")
    func compactDoesNotGroup() {
        let rows = layout([message("a", "@alice", at: 3), message("b", "@alice", at: 2)], groups: false)
        #expect(rows == ["day Today", "a 11:57 AM", "b 11:58 AM"])
    }

    // capability: conversation.day-dividers
    @Test("Day dividers follow the calendar's time zone and name today and yesterday")
    func dayDividers() {
        let rows = layout([
            message("older", "@alice", at: 3 * 24 * 60), message("yesterday", "@alice", at: 24 * 60),
            message("late", "@alice", at: 12 * 60 + 1),
            // 00:01 today at UTC+8, two minutes after "late", still starts a new day.
            message("midnight", "@alice", at: 12 * 60 - 1),
        ])
        #expect(
            rows == [
                "day Monday, October 20", "older 12:00 PM", "day Yesterday", "yesterday 12:00 PM", "late 11:59 PM",
                "day Today", "midnight 12:01 AM",
            ])
    }

    // capability: conversation.unread-line
    @Test("The unread line goes above its event and starts a new group")
    func unreadBoundary() {
        var local = message("txn", "@alice", at: 1)
        local.timelineEventID = "$event"
        let rows = layout([message("a", "@alice", at: 2), local], unread: "$event")
        #expect(rows == ["day Today", "a 11:58 AM", "unread", "txn 11:59 AM"])
    }

    @Test("In a thread the line counting its replies sets the root apart, and the first reply starts its own group")
    func repliesDivider() {
        let thread = [message("root", "@alice", at: 3), message("a", "@alice", at: 2), message("b", "@alice", at: 1)]
        #expect(
            layout(thread, threadRoot: "root", repliesLine: 5)
                == ["day Today", "root 11:57 AM", "5 replies", "a 11:58 AM", "b grouped 11:59 AM"])
        // No count, no line; the first reply still starts its own group.
        #expect(
            layout(thread, threadRoot: "root") == ["day Today", "root 11:57 AM", "a 11:58 AM", "b grouped 11:59 AM"])
        // Older replies still to load sit above the newest, with the root not yet among them: no line.
        #expect(
            layout(Array(thread.dropFirst()), threadRoot: "root", repliesLine: 5)
                == ["day Today", "a 11:58 AM", "b grouped 11:59 AM"])
    }

    // capability: conversation.unread-line
    @MainActor
    @Test(
        "A message that arrives while the conversation is open adds no unread line, unread conversation or not",
        arguments: [nil, "$a"])
    func noLineForLiveArrivals(anchor: String?) {
        let cache = TimelineLayoutCache()
        var first = message("a", "@alice", at: 2)
        first.timelineEventID = "$a"
        var later = message("b", "@bob", at: 1)
        later.timelineEventID = "$b"
        _ = cache.rows([first], firstUnreadEventID: nil, unreadAnchor: anchor, groups: true)
        let rows = cache.rows([first, later], firstUnreadEventID: "$b", unreadAnchor: anchor, groups: true)
        #expect(!rows.contains { if case .unread = $0.kind { true } else { false } })
    }

    /// The message the unread line sits above, if there is a line.
    private func belowLine(_ rows: [TimelineLayout.Row]) -> String? {
        guard let line = rows.firstIndex(where: { if case .unread = $0.kind { true } else { false } }),
            rows.indices.contains(line + 1), case .message(let message, _, _) = rows[line + 1].kind
        else { return nil }
        return message.eventID
    }

    // capability: conversation.unread-line
    @MainActor
    @Test(
        "An unread conversation that opens before its read marker has its line at once, where its fully-read event says",
        arguments: [
            // Above the first message someone else sent after it, past your own.
            ("$a", "$c"),
            // A conversation that didn't open as unread.
            (nil, nil),
            // Only your own message follows it.
            ("$d", nil),
        ] as [(String?, String?)])
    func lineFromAnchor(anchor: String?, line: String?) {
        let cache = TimelineLayoutCache()
        let messages = [("a", "@alice"), ("b", "@me"), ("c", "@alice"), ("d", "@alice"), ("e", "@me")].enumerated()
            .map { index, sent in
                var message = message(sent.0, sent.1, at: Double(5 - index))
                message.timelineEventID = "$\(sent.0)"
                return message
            }
        func rows(_ marker: String?) -> [TimelineLayout.Row] {
            cache.rows(messages, firstUnreadEventID: marker, unreadAnchor: anchor, me: "@me", groups: true)
        }
        #expect(belowLine(rows(nil)) == line)
        // A marker that lands later, wherever, changes nothing.
        #expect(belowLine(rows("$d")) == line)
    }

    // capability: conversation.unread-line
    @MainActor
    @Test(
        "A partial sliding-sync cache waits for older history to bring the unread anchor without marking live arrivals")
    func partialCacheWaitsForUnreadAnchor() {
        let cache = TimelineLayoutCache()
        func make(_ id: String, _ sender: String, at minutes: Double) -> ChatMessage {
            var item = message(id, sender, at: minutes)
            item.timelineEventID = "$\(id)"
            return item
        }
        let a = make("a", "@alice", at: 6)
        let b = make("b", "@alice", at: 5)
        let c = make("c", "@me", at: 4)
        let d = make("d", "@alice", at: 3)
        let e = make("e", "@bob", at: 2)
        let f = make("f", "@bob", at: 1)

        // Initial partial cache holds only the newest two messages, not yet reaching the anchor "$b".
        let initial = cache.rows([d, e], firstUnreadEventID: nil, unreadAnchor: "$b", me: "@me", groups: true)
        #expect(belowLine(initial) == nil)
        // A live arrival while older history is still loading must not get an unread line.
        let withLive = cache.rows([d, e, f], firstUnreadEventID: "$f", unreadAnchor: "$b", me: "@me", groups: true)
        #expect(belowLine(withLive) == nil)
        // Once readOlder prepends history reaching "$b", the unread line lands above "$d" (skipping own "$c").
        let loaded = cache.rows(
            [a, b, c, d, e, f], firstUnreadEventID: nil, unreadAnchor: "$b", me: "@me", groups: true)
        #expect(belowLine(loaded) == "$d")
        // Once resolved, later markers cannot move it.
        let later = cache.rows(
            [a, b, c, d, e, f], firstUnreadEventID: "$e", unreadAnchor: "$b", me: "@me", groups: true)
        #expect(belowLine(later) == "$d")
    }

    // capability: conversation.day-dividers
    @Test("Day dividers stay distinct when server timestamps return to an earlier day")
    func repeatedDayIdentities() {
        let messages = [
            message("a", "@alice", at: 0), message("b", "@bob", at: 24 * 60), message("c", "@alice", at: -1),
        ]
        let rows = TimelineLayout.rows(
            messages, unreadBoundaryEventID: nil, groups: true, now: Self.now, calendar: Self.calendar,
            locale: Self.locale)
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(
            rows.compactMap { row -> String? in
                if case .day(let label) = row.kind { return label }
                return nil
            } == ["Today", "Yesterday", "Today"])
    }

    @Test("Row identities survive older messages arriving above them")
    func stableIdentities() {
        let recent = [message("b", "@alice", at: 10)]
        let before = TimelineLayout.rows(
            recent, unreadBoundaryEventID: nil, groups: true, now: Self.now, calendar: Self.calendar,
            locale: Self.locale)
        let after = TimelineLayout.rows(
            [message("a", "@alice", at: 20)] + recent, unreadBoundaryEventID: nil, groups: true, now: Self.now,
            calendar: Self.calendar, locale: Self.locale)
        #expect(Set(before.map(\.id)).isSubset(of: Set(after.map(\.id))))
    }

    @MainActor
    @Test("Cancelling an opening local echo before backfill arrives never marks live arrivals as unread")
    func cancelledLocalEchoNeverMarksLiveArrivalsUnread() {
        let cache = TimelineLayoutCache()
        var pending = message("txn-1", "@me", at: 10)
        pending.sendState = "sending"
        let anchor = message("$m8", "@me", at: 30)
        let unreadOld = message("$m9", "@alice", at: 20)
        let live = message("$live", "@bob", at: 0)

        // Room opens with only a pending local echo; unreadAnchor ($m8) is not in the cache yet.
        _ = cache.rows(
            [pending], firstUnreadEventID: nil, unreadAnchor: "$m8", me: "@me", groups: true)
        // Local echo is cancelled, backfill brings only the read anchor ($m8), and a live message arrives after open.
        let rows = cache.rows(
            [anchor, live], firstUnreadEventID: nil, unreadAnchor: "$m8", me: "@me", groups: true)
        #expect(!rows.contains { $0.id == "unread" })

        // When an older unread message ($m9) also arrives before the opening cutoff, only $m9 gets the unread line.
        let cache2 = TimelineLayoutCache()
        _ = cache2.rows(
            [pending], firstUnreadEventID: nil, unreadAnchor: "$m8", me: "@me", groups: true)
        let rows2 = cache2.rows(
            [anchor, unreadOld, live], firstUnreadEventID: nil, unreadAnchor: "$m8", me: "@me", groups: true)
        let unreadIndex = rows2.firstIndex { $0.id == "unread" }
        #expect(unreadIndex.map { rows2[$0 + 1].id == unreadOld.id } == true)
    }
}
