import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// Thread card geometry measured without a window, catching height jumps when previews hydrate or fail.
@MainActor
struct ThreadsFeedRowTests {
    private let width: CGFloat = 680

    private func message(_ id: String, sender: String, body: String) -> ChatMessage {
        ChatMessage(
            id: id, roomID: "!room:example.org", senderID: "@sender:example.org", senderName: sender, body: body,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func height(
        item: ThreadFeedItem, root: ThreadPreview, latest: ThreadPreview?, zoom: CGFloat = 1
    ) -> CGFloat {
        let matrix = MatrixService.scratch()
        let view = ThreadFeedRow(
            item: item, root: root, latest: latest, matrix: matrix, onOpen: { _ in }, hydrate: { _ in }
        )
        .frame(width: width)
        .environmentObject(AppearanceStore())
        .environment(\.metrics, Metrics(zoom: zoom))
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    private func preview(
        feed: ThreadFeedService, roomID: String, eventID: String, hydrate item: ThreadFeedItem? = nil
    ) async -> ThreadPreview {
        if let item { await feed.hydratePreview(item) }
        return feed.preview(roomID: roomID, eventID: eventID)
    }

    // capability: threads.feed
    @Test("Hydrating a short, wrapped, or long thread card keeps its height stable")
    func hydrationHeightStability() async throws {
        let cases: [(name: String, rootBody: String, latestBody: String)] = [
            ("single line", "Quick check on the deploy status", "Looks green on staging."),
            (
                "wrapped",
                "We should keep the thread card heights completely stable when previews arrive from the server so nothing shifts under the pointer while reading.",
                "Agreed — matching the placeholder line spacing and font role prevents every row below from jumping."
            ),
            (
                "long clamped",
                Array(repeating: "Line of a long thread root message that wraps past three lines.", count: 8)
                    .joined(separator: " "),
                Array(repeating: "Long latest reply that must stay clamped at two lines inside the card.", count: 6)
                    .joined(separator: " ")
            ),
        ]

        for entry in cases {
            let roomID = "!room:example.org"
            let rootID = "$root-\(entry.name)"
            let latestID = "$reply-\(entry.name)"
            let fakeRoom = FakeThreadRoom(
                threads: FakeThreadList([
                    ThreadListItem(
                        rootEvent: threadEvent(
                            rootID, timestamp: 1_000,
                            content: textEvent(rootID, body: entry.rootBody).content),
                        latestEvent: threadEvent(
                            latestID, timestamp: 2_000,
                            content: textEvent(latestID, body: entry.latestBody).content),
                        numReplies: 4)
                ]),
                timelines: [
                    rootID: FakeEventTimeline(textEvent(rootID, body: entry.rootBody)),
                    latestID: FakeEventTimeline(textEvent(latestID, body: entry.latestBody)),
                ])
            let feed = ThreadFeedService()
            // Keep previews unhydrated first by gating timelines on a fresh open? Easier: inspect before vs after.
            let chatRoom = ChatRoom(id: roomID, name: "Engineering")
            let item = ThreadFeedItem(
                id: ActivityService.key(roomID: roomID, eventID: rootID), roomID: roomID, roomName: chatRoom.name,
                root: message(rootID, sender: "Alice", body: entry.rootBody),
                latest: message(latestID, sender: "Bob", body: entry.latestBody),
                replyCount: 4, isUnread: true)

            let loadingRoot = feed.preview(roomID: roomID, eventID: rootID)
            let loadingLatest = feed.preview(roomID: roomID, eventID: latestID)
            let before = height(item: item, root: loadingRoot, latest: loadingLatest)

            await feed.open(client: FakeThreadClient(fakeRoom), rooms: [chatRoom], workspaceID: nil) { _ in }
            let openItem = try #require(feed.items.first)
            await feed.hydratePreview(openItem)
            let readyRoot = feed.preview(roomID: roomID, eventID: rootID)
            let readyLatest = feed.preview(roomID: roomID, eventID: latestID)
            #expect(readyRoot.state == .ready && readyLatest.state == .ready)
            let after = height(item: openItem, root: readyRoot, latest: readyLatest)
            feed.close()

            #expect(
                abs(after - before) <= 3,
                "\(entry.name): loading height \(before) jumped to ready height \(after)")
        }
    }

    // capability: threads.feed
    @Test("A failed preview stays inside the message slot instead of adding a new row below the card")
    func failedPreviewDoesNotGrowCard() async throws {
        let roomID = "!room:example.org"
        let rootID = "$root-fail"
        let latestID = "$reply-fail"
        let fakeRoom = FakeThreadRoom(
            threads: FakeThreadList([
                ThreadListItem(
                    rootEvent: threadEvent(rootID, timestamp: 1_000, content: textEvent(rootID, body: "Short").content),
                    latestEvent: threadEvent(
                        latestID, timestamp: 2_000, content: textEvent(latestID, body: "Reply").content),
                    numReplies: 2)
            ]))
        fakeRoom.fail = true
        let chatRoom = ChatRoom(id: roomID, name: "General")
        let item = ThreadFeedItem(
            id: ActivityService.key(roomID: roomID, eventID: rootID), roomID: roomID, roomName: chatRoom.name,
            root: message(rootID, sender: "Alice", body: "Short"),
            latest: message(latestID, sender: "Bob", body: "Reply"),
            replyCount: 2, isUnread: false)

        let feed = ThreadFeedService()
        let before = height(
            item: item, root: feed.preview(roomID: roomID, eventID: rootID),
            latest: feed.preview(roomID: roomID, eventID: latestID))

        await feed.open(client: FakeThreadClient(fakeRoom), rooms: [chatRoom], workspaceID: nil) { _ in }
        let openItem = try #require(feed.items.first)
        await feed.hydratePreview(openItem)
        let failedRoot = feed.preview(roomID: roomID, eventID: rootID)
        let failedLatest = feed.preview(roomID: roomID, eventID: latestID)
        #expect(failedRoot.state == .failed && failedLatest.state == .failed)
        let after = height(item: openItem, root: failedRoot, latest: failedLatest)
        feed.close()

        #expect(abs(after - before) <= 3, "Failed preview grew card from \(before) to \(after)")
    }
}
