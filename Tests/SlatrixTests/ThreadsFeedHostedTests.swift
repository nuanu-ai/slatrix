import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// The Threads feed in a real offscreen window at the scale of a busy account: 600 threads across 50 conversations,
/// every root and latest reply hydrating to its current body, formatted or plain. Needs an awake display. Budgets sit
/// near three times an M4 Pro debug run: about 1 s, 40 ms, 60 ms and 18 ms.
@MainActor
@Suite(
    .serialized, .tags(.hosted, .budget),
    .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil && budgetsEnabled))
struct ThreadsFeedHostedTests {
    private static let roomCount = 50
    private static let threadsPerRoom = 12

    /// A thread message as the fake SDK serves it.
    private struct Message {
        var eventID: String
        var timestamp: UInt64
        var timeline: FakeEventTimeline
        /// Words only this message's body has.
        var marker: String
    }

    @MainActor private final class Harness {
        let matrix = MatrixService()
        let window = offscreenWindow(NSSize(width: 1_000, height: 900))
        var hosting: NSHostingView<AnyView>?
        /// By the message's key in the feed.
        var messages: [String: Message] = [:]
        var feed: ThreadFeedService { matrix.threadFeed }

        init() {
            _ = NSApplication.shared
            let tag = UUID().uuidString
            let bodies = busyConversation(roomCount * threadsPerRoom * 2, roomID: "!feed:example.org", tag: tag)
            var rooms: [String: FakeThreadRoom] = [:]
            for room in 0..<roomCount {
                let roomID = "!thread\(room):example.org"
                var threads: [ThreadListItem] = []
                var timelines: [String: FakeEventTimeline] = [:]
                for thread in 0..<threadsPerRoom {
                    // Newest first across conversations, so each page of discovery lands all over the feed.
                    let index = thread * roomCount + room
                    let rootID = "$\(tag)-\(room)-\(thread)"
                    let time = UInt64(1_761_192_000_000 - index * 60_000)
                    threads.append(
                        ThreadListItem(
                            rootEvent: threadEvent(rootID, timestamp: time),
                            latestEvent: threadEvent(rootID + "-reply", timestamp: time + 30_000), numReplies: 3))
                    for (offset, eventID) in [rootID, rootID + "-reply"].enumerated() {
                        let body = bodies[index * 2 + offset]
                        let timestamp = time + UInt64(offset * 30_000)
                        let timeline = FakeEventTimeline(
                            textEvent(eventID, body: body.body, formatted: body.formattedBody, timestamp: timestamp))
                        timelines[eventID] = timeline
                        messages[ActivityService.key(roomID: roomID, eventID: eventID)] = Message(
                            eventID: eventID, timestamp: timestamp, timeline: timeline,
                            marker: "\(tag) \(index * 2 + offset) ")
                    }
                }
                rooms[roomID] = FakeThreadRoom(threads: FakeThreadList(threads), timelines: timelines)
            }
            matrix.configureRoomOpenForChecks(
                client: FakeThreadClient(FakeThreadRoom(), rooms: rooms), roomList: FakeRoomListService(),
                user: ChatUser(id: "@reader:example.org", name: "Reader"))
            matrix.rooms = (0..<roomCount).map {
                ChatRoom(id: "!thread\($0):example.org", name: "Conversation \($0)", isDirect: $0 % 5 == 0)
            }
        }

        func open() {
            var workspaceID: String?
            let hosting = NSHostingView(
                rootView: AnyView(
                    ThreadsFeedView(
                        matrix: matrix, feed: feed,
                        workspaceID: Binding(get: { workspaceID }, set: { workspaceID = $0 }), onOpen: { _ in }
                    )
                    // As the window's pane holds it: all the space there is.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environmentObject(AppearanceStore()).environment(\.metrics, Metrics(zoom: 1))))
            self.hosting = hosting
            window.contentView = hosting
            window.orderFrontRegardless()
        }

        func close() {
            window.contentView = nil
            window.close()
            matrix.closeThreads()
        }

        /// Lays out and draws, as a frame would.
        func render() {
            hosting?.layoutSubtreeIfNeeded()
            hosting?.displayIfNeeded()
        }

        static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

        /// The message bodies on screen.
        func shownBodies() -> [String] {
            guard let hosting else { return [] }
            return Self.views(in: hosting).compactMap { $0 as? MessageTextView }.filter { !$0.visibleRect.isEmpty }
                .map(\.string)
        }

        /// Every conversation checked, and the first rows showing their current root and latest reply.
        func settled() -> Bool {
            render()
            guard !feed.isLoading, !feed.canCheckMore, feed.items.count == roomCount * threadsPerRoom else {
                return false
            }
            let shown = shownBodies()
            return feed.items.prefix(3).allSatisfy { item in
                [item.root.eventID, item.latest?.eventID].compactMap { $0 }.allSatisfy { eventID in
                    let marker = messages[ActivityService.key(roomID: item.roomID, eventID: eventID)]?.marker
                    return shown.contains { marker.map($0.contains) == true }
                }
            }
        }

        /// Opens the feed and scrolls halfway down, where the rows above are only estimated. Returns the main-thread
        /// time from the scroll until the rows there show their current messages.
        @discardableResult func openHalfway() async throws -> Duration {
            open()
            #expect(await eventually(timeout: .seconds(60)) { settled() })
            let scroll = try #require(Self.views(in: hosting!).compactMap { $0 as? NSScrollView }.first)
            let start = threadCPUTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.frame.height ?? 0) / 2))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(
                await eventually(timeout: .seconds(60)) {
                    render()
                    return shownBodies().count >= 4
                })
            return threadCPUTime() - start
        }
    }

    @Test("Opening Threads on a busy account shows its first rows, current, within budget")
    func openBudget() async {
        let harness = Harness()
        defer { harness.close() }
        let start = threadCPUTime()
        harness.open()
        #expect(await eventually(timeout: .seconds(60)) { harness.settled() })
        let time = threadCPUTime() - start
        #expect(time < .seconds(3), "\(time)")
    }

    @Test("Scrolling halfway down a busy Threads feed shows the rows there, current, within budget")
    func hydrationBudget() async throws {
        let harness = Harness()
        defer { harness.close() }
        let time = try await harness.openHalfway()
        #expect(time < .milliseconds(120), "\(time)")
    }

    @Test("100 room-list updates halfway down a busy Threads feed hold the main thread within budget")
    func roomListBudget() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.openHalfway()
        let start = threadCPUTime()
        for index in 0..<100 {
            // As the room-list refresher publishes: the sidebar's rooms, then the feed's.
            harness.matrix.rooms[index % Self.roomCount].unread = index % 7 + 1
            harness.feed.updateRooms(harness.matrix.rooms)
            await drainMainActor()
            harness.render()
        }
        let time = threadCPUTime() - start
        #expect(time < .milliseconds(200), "\(time)")
    }

    @Test("Live edits to the rows shown halfway down a busy Threads feed redraw within budget")
    func previewUpdateBudget() async throws {
        let harness = Harness()
        defer { harness.close() }
        try await harness.openHalfway()
        let bodies = harness.shownBodies()
        let shown = harness.messages.values.filter { message in bodies.contains { $0.contains(message.marker) } }
        #expect(shown.count >= 4)
        let start = threadCPUTime()
        for message in shown {
            message.timeline.emit(
                textEvent(message.eventID, body: "Edited \(message.marker)", timestamp: message.timestamp))
        }
        #expect(
            await eventually(timeout: .seconds(60)) {
                harness.render()
                let bodies = harness.shownBodies()
                return shown.allSatisfy { bodies.contains("Edited \($0.marker)") }
            })
        let time = threadCPUTime() - start
        #expect(time < .milliseconds(60), "\(time)")
    }
}
