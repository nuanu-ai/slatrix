import AppKit
import SwiftUI
import Testing

@testable import Slatrix

struct DirectMessagesTests {
    // capability: home.dms
    @Test("The DMs page lists the newest conversation first and marks the latest message when it is yours")
    func newestFirst() {
        let rooms = [
            ChatRoom(id: "!team:example.org", name: "Team"),
            ChatRoom(
                id: "!avery:example.org", name: "Avery", isDirect: true,
                latest: LatestMessage(
                    body: "See you at noon", timestamp: Date(timeIntervalSince1970: 1_000), isOwn: false)),
            ChatRoom(id: "!casey:example.org", name: "Casey", isDirect: true),
            ChatRoom(
                id: "!blake:example.org", name: "Blake", isDirect: true,
                latest: LatestMessage(body: "Shipped it", timestamp: Date(timeIntervalSince1970: 2_000), isOwn: true)),
        ]
        let direct = ChatRoom.directMessages(rooms)
        #expect(direct.map(\.name) == ["Blake", "Avery", "Casey"])
        #expect(direct.map { $0.latest?.preview } == ["You: Shipped it", "See you at noon", nil])
    }

    @Test(
        "A latest message shows its time today, Yesterday the day before, and its date before that",
        arguments: [
            ("2026-10-30T09:41:00Z", "9:41 AM"), ("2026-10-29T23:59:00Z", "Yesterday"),
            ("2026-10-03T12:00:00Z", "Oct 3"), ("2025-12-24T12:00:00Z", "Dec 24, 2025"),
        ])
    func time(sent: String, shown: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let latest = LatestMessage(body: nil, timestamp: try Date(sent, strategy: .iso8601), isOwn: false)
        let label = latest.time(now: try Date("2026-10-30T15:00:00Z", strategy: .iso8601), calendar: calendar)
        #expect(label.replacingOccurrences(of: "\u{202F}", with: " ") == shown)
    }

    @MainActor
    @Test("A direct message's row keeps its height when its latest message arrives")
    func rowKeepsHeight() {
        func height(_ room: ChatRoom) -> CGFloat {
            NSHostingView(
                rootView: DirectMessageRow(room: room).frame(width: 600).environmentObject(AppearanceStore())
                    .environment(\.metrics, Metrics(zoom: 1))
            ).fittingSize.height
        }
        var room = ChatRoom(id: "!avery:example.org", name: "Avery", isDirect: true)
        let waiting = height(room)
        room.latest = LatestMessage(body: "See you at noon", timestamp: Date(), isOwn: false)
        #expect(height(room) == waiting)
    }
}
