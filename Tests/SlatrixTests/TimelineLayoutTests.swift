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

    private func message(_ id: String, _ sender: String, at minutesBeforeNow: Double) -> ChatMessage {
        ChatMessage(
            id: id, roomID: "!room:example.org", senderID: sender, senderName: sender, body: id,
            timestamp: Self.now.addingTimeInterval(-minutesBeforeNow * 60))
    }

    private func layout(_ messages: [ChatMessage], unread: String? = nil, groups: Bool = true) -> [String] {
        TimelineLayout.rows(
            messages, unreadBoundaryEventID: unread, groups: groups, now: Self.now, calendar: Self.calendar,
            locale: Self.locale
        ).map { row in
            switch row.kind {
            case .day(let label): "day \(label)"
            case .unread: "unread"
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
}
