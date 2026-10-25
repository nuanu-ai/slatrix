import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Budgets for main-thread work at the scale of a busy account. The CI runner takes about 3.5 times as long as an M4 Pro
/// debug run, so a budget is set near seven times the local time: a required check must not flip on noise, and the
/// owner's performance log tracks finer drift. The room-list and rich-text budgets predate this and sit near three
/// times. The timeline table's budgets are in `TimelineHostedTests`.
@MainActor
@Suite(.serialized, .tags(.budget), .enabled(if: budgetsEnabled))
struct PerformanceBudgetTests {
    @Test("A room-list pass over 300 rooms in 20 workspaces publishes the sidebar within budget")
    func roomListBudget() async {
        var rooms: [ChatRoom] = []
        let time = await fastest(of: 5) {
            let spaces = (0..<20).map { FakeRoom(roomInfo(id: "!space\($0):example.org", isSpace: true)) }
            let client = FakeClient(
                rooms: spaces
                    + (0..<280).map {
                        FakeRoom(roomInfo(id: "!room\($0):example.org", name: "Room \($0)", unread: UInt64($0 % 3)))
                    })
            for index in 0..<280 {
                client.spaces.parents["!room\(index):example.org"] = ["!space\(index % 20):example.org"]
            }
            let refresher = RoomListRefresher()
            refresher.attach(client)
            let start = ContinuousClock.now
            await withCheckedContinuation { published in
                refresher.onChange = { published.resume() }
                refresher.request()
            }
            rooms = refresher.rooms
            return .now - start
        }
        #expect(rooms.count == 280 && rooms.allSatisfy { $0.spaceIDs.count == 1 })
        #expect(time < .milliseconds(35), "\(time)")
    }

    @Test("A 50-message diff on a 1,000-message timeline is applied and projected within budget")
    func timelineDiffBudget() async {
        let service = MatrixService()
        service.user = ChatUser(id: "@ana:example.org", name: "Ana")
        let roomID = "!busy:example.org"
        let time = await fastest(of: 5) {
            let items: [TimelineItem] = busyConversation(1_050, roomID: roomID, tag: UUID().uuidString).map {
                FakeTimelineItem(textEvent($0.id, body: $0.body, sender: $0.senderID))
            }
            var timeline = Array(items.prefix(1_000))
            let start = ContinuousClock.now
            timeline.apply([.append(Array(items.suffix(50)))])
            service.projectMediaCaptionForChecks(timeline, roomID: roomID, inThread: false)
            return .now - start
        }
        #expect(service.messages.count == 1_050)
        #expect(time < .milliseconds(25), "\(time)")
    }

    @Test("Rendering 1,000 formatted message bodies stays within budget")
    func richTextBudget() async {
        var last: RenderedMessageBody?
        let time = await fastest(of: 5) {
            let renderer = MessageBodyRenderer()
            let bodies = busyConversation(1_000, roomID: "!busy:example.org", tag: UUID().uuidString).map {
                (
                    $0.body,
                    "<p><strong>\($0.id)</strong> \($0.body) <em>today</em> <a href=\"https://example.org\">notes</a> "
                        + "<code>make check</code></p><ul><li>first</li><li>second</li></ul>"
                )
            }
            let start = ContinuousClock.now
            for (body, html) in bodies { last = renderer.render(body: body, formattedBody: html) }
            return .now - start
        }
        #expect(last?.runs.contains { $0.style.contains(.code) } == true)
        #expect(time < .milliseconds(900), "\(time)")
    }
}
