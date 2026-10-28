import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct ThreadPreviewTests {
    private let chatRoom = ChatRoom(id: "!room:example.org", name: "Room")
    private let root = FakeEventTimeline(textEvent("$root", body: "Edited successfully", edited: true))
    private let latest = FakeEventTimeline(textEvent("$reply", body: "Hidden old reply", redacted: true))
    private let room: FakeThreadRoom
    private let feed = ThreadFeedService()

    init() {
        room = FakeThreadRoom(
            threads: FakeThreadList([
                ThreadListItem(rootEvent: threadEvent("$root"), latestEvent: threadEvent("$reply"), numReplies: 9)
            ]), timelines: ["$root": root, "$reply": latest])
    }

    private func open() async throws -> ThreadFeedItem {
        await feed.open(client: FakeThreadClient(room), rooms: [chatRoom], workspaceID: nil) { _ in }
        return try #require(feed.items.first)
    }

    private func preview(_ eventID: String) -> ThreadPreview { feed.preview(roomID: chatRoom.id, eventID: eventID) }

    @Test("Before hydration, a row never shows the thread list's original snapshot as current")
    func snapshotIsPlaceholder() async throws {
        let row = try await open()
        let shown = preview("$root")
        #expect(shown.state == .snapshot && !shown.shown(row.root).body.contains("Original snapshot"))
    }

    @Test("Hydration shows the SDK's current edit of the root and deletion of the latest reply")
    func hydrationAppliesEditsAndRedactions() async throws {
        let row = try await open()
        let (shownRoot, shownLatest) = (preview("$root"), preview("$reply"))
        await feed.hydratePreview(row)
        let root = shownRoot.shown(row.root)
        let latest = shownLatest.shown(try #require(row.latest))
        #expect(root.body == "Edited successfully" && root.isEdited && root.replyCount == 9)
        #expect(latest.isRedacted && latest.body == "This message was deleted")
    }

    @Test("Hydration reads each event alone, without receipts, decryption reports, pagination or read markers")
    func hydrationIsReadOnly() async throws {
        await feed.hydratePreview(try await open())
        let configurations = room.configurations.all
        #expect(configurations.count == 2)
        for configuration in configurations {
            guard case .event(_, let context, let mode) = configuration.focus else {
                Issue.record("not an event focus")
                continue
            }
            #expect(context == 0 && mode == .automatic(hideThreadedEvents: false))
            #expect(configuration.trackReadReceipts == .disabled && !configuration.reportUtds)
        }
        #expect(root.sideEffects.all.isEmpty && latest.sideEffects.all.isEmpty)
    }

    @Test("A row that reappears reuses its live previews instead of opening new timelines")
    func reusesHydratedTimelines() async throws {
        let row = try await open()
        await feed.hydratePreview(row)
        let opened = room.configurations.all.count
        await feed.hydratePreview(row)
        #expect(room.configurations.all.count == opened)
    }

    @Test("A late thread-list snapshot cannot undo a live deletion of the root")
    func lateSnapshotKeepsLiveRedaction() async throws {
        await feed.hydratePreview(try await open())
        let shown = preview("$root")
        root.emit(textEvent("$root", body: "Original must stay hidden", redacted: true))
        #expect(await eventually { shown.message?.isRedacted == true })
        room.threads.replaySnapshot()
        await drainMainActor()
        let row = try #require(feed.items.first)
        #expect(shown.shown(row.root).isRedacted && shown.state == .ready)
    }

    @Test("Closing the feed stops every preview listener and ignores late updates")
    func closeStopsPreviews() async throws {
        await feed.hydratePreview(try await open())
        feed.close()
        root.emit(textEvent("$root", body: "Stale callback"))
        await drainMainActor()
        #expect(feed.items.isEmpty && root.allListenersCancelled && latest.allListenersCancelled)
    }

    @Test("Hydrating a row's preview leaves the feed's list of threads as it was")
    func hydrationKeepsList() async throws {
        let row = try await open()
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = feed.items
        } onChange: {
            changes.append(())
        }
        await feed.hydratePreview(row)
        #expect(changes.all.isEmpty)
    }

    @Test("A failed preview shows a placeholder until an explicit retry succeeds")
    func failureThenRetry() async throws {
        room.fail = true
        let row = try await open()
        await feed.hydratePreview(row)
        let shown = preview("$root")
        #expect(shown.state == .failed && !shown.shown(row.root).body.contains("Original snapshot"))
        room.fail = false
        await feed.hydratePreview(row, retry: true)
        #expect(shown.state == .ready)
    }
}

@MainActor
struct ThreadPreviewCacheTests {
    @Test("Hydrated previews are bounded; an evicted row hydrates again without losing its new timeline")
    func boundedCache() async throws {
        let ids = (0..<65).map { "$cache-\($0)" }
        let timelines = Dictionary(
            uniqueKeysWithValues: ids.map { ($0, FakeEventTimeline(textEvent($0, body: "Current"))) })
        let room = FakeThreadRoom(
            threads: FakeThreadList(
                ids.map { ThreadListItem(rootEvent: threadEvent($0), latestEvent: nil, numReplies: 1) }),
            timelines: timelines)
        let feed = ThreadFeedService()
        await feed.open(
            client: FakeThreadClient(room), rooms: [ChatRoom(id: "!room:example.org", name: "Room")], workspaceID: nil
        ) { _ in }
        for row in feed.items { await feed.hydratePreview(row) }
        func state(_ row: ThreadFeedItem) -> ThreadPreview.State {
            feed.preview(roomID: row.roomID, eventID: row.root.eventID).state
        }
        let evicted = feed.items.filter { state($0) == .snapshot }
        #expect(evicted.count == 1)
        let row = try #require(evicted.first)
        await feed.hydratePreview(row)
        #expect(state(row) == .ready)
        #expect(feed.items.filter { state($0) == .snapshot }.count == 1)
        #expect(timelines[row.root.id]?.allListenersCancelled == false)
        feed.close()
    }
}
