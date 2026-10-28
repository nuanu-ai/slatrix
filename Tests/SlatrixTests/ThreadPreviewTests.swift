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

    @Test("Before hydration, a row never shows the thread list's original snapshot as current")
    func snapshotIsPlaceholder() async throws {
        let row = try await open()
        #expect(row.rootPreviewState == .snapshot && !row.root.body.contains("Original snapshot"))
    }

    @Test("Hydration shows the SDK's current edit of the root and deletion of the latest reply")
    func hydrationAppliesEditsAndRedactions() async throws {
        await feed.hydratePreview(try await open())
        let row = try #require(feed.items.first)
        #expect(row.root.body == "Edited successfully" && row.root.isEdited)
        #expect(row.latest?.isRedacted == true && row.latest?.body == "This message was deleted")
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
        root.emit(textEvent("$root", body: "Original must stay hidden", redacted: true))
        #expect(await eventually { feed.items.first?.root.isRedacted == true })
        room.threads.replaySnapshot()
        await drainMainActor()
        #expect(feed.items.first?.root.isRedacted == true && feed.items.first?.rootPreviewState == .ready)
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
        #expect(feed.items[0].rootPreviewState == .failed && !feed.items[0].root.body.contains("Original snapshot"))
        room.fail = false
        await feed.hydratePreview(feed.items[0], retry: true)
        #expect(feed.items[0].rootPreviewState == .ready)
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
        let evicted = feed.items.filter { $0.rootPreviewState == .snapshot }
        #expect(evicted.count == 1)
        let row = try #require(evicted.first)
        await feed.hydratePreview(row)
        #expect(feed.items.first { $0.id == row.id }?.rootPreviewState == .ready)
        #expect(feed.items.filter { $0.rootPreviewState == .snapshot }.count == 1)
        #expect(timelines[row.root.id]?.allListenersCancelled == false)
        feed.close()
    }
}
