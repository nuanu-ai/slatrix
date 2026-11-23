import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// A thread pane in the whole window, offscreen, against SDK fakes whose pages the test holds back; needs an awake
/// display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ThreadPaneHostedTests {
    typealias Harness = ConversationSwitchHostedTests.Harness

    /// The thread of the first conversation's newest message, opened through its menu with `replies`, its first page
    /// failing.
    private func openFailingThread(_ harness: Harness, replies: [TimelineItem] = []) async throws -> FakeLiveTimeline {
        try #require(await harness.settled(on: 0))
        harness.rooms[0].threadItems = replies
        let message = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? MessageTextView }
                .last { $0.window != nil && !$0.isEditable && !$0.string.isEmpty })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(message.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
        let room = harness.rooms[0]
        try #require(await eventually { room.timelines.all.count == 2 && room.pageGate.isWaiting })
        let thread = try #require(harness.rooms[0].timelines.all.last)
        thread.pageFailure = URLError(.notConnectedToInternet)
        return thread
    }

    /// The tops of the thread pane's message rows on screen, by event ID; beside the conversation, the pane's timeline is
    /// the rightmost.
    private func threadRows(_ harness: Harness) -> [String: CGFloat] {
        harness.hosting.layoutSubtreeIfNeeded()
        let views = Harness.views(in: harness.hosting).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        let pane = views.compactMap { $0 as? TimelineScrollView }.max {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        var rows: [String: CGFloat] = [:]
        for case let cell as TimelineCell in views where pane != nil && cell.enclosingScrollView === pane {
            if case .message(let entry) = cell.entry?.kind {
                rows[entry.message.eventID] = cell.convert(cell.bounds, to: nil).minY
            }
        }
        return rows
    }

    @Test("A thread's failed page shows beside the conversation without moving the thread's rows")
    func failureMovesNothing() async throws {
        let harness = try Harness()
        defer { harness.close() }
        VoiceOver.listen()
        defer { VoiceOver.done() }
        _ = try await openFailingThread(harness)
        let root = try #require(harness.matrix.threadOpening?.rootID)
        try #require(await eventually { threadRows(harness)[root] != nil })
        let before = try #require(threadRows(harness)[root])
        harness.rooms[0].pageGate.release()
        try #require(await eventually { !accessible("Retry", in: harness.hosting).isEmpty })
        #expect(threadRows(harness)[root] == before)
    }

    @Test("Retry on a thread's failed page goes on loading its replies past a page that shows none")
    func retryKeepsLoading() async throws {
        let harness = try Harness()
        defer { harness.close() }
        VoiceOver.listen()
        defer { VoiceOver.done() }
        // Narrow enough that the thread takes the conversation's place.
        harness.window.setContentSize(NSSize(width: 700, height: 900))
        let thread = try await openFailingThread(harness)
        harness.rooms[0].pageGate.release()
        try #require(await eventually { !accessible("Retry", in: harness.hosting).isEmpty })
        thread.olderPages = [[], [FakeTimelineItem(textEvent("$t0", body: "The oldest reply"), uniqueID: "thread-t0")]]
        #expect(accessible("Retry", in: harness.hosting).contains { $0.accessibilityPerformPress?() == true })
        #expect(await eventually { harness.sample().rows["$t0"] != nil })
    }

    @Test("Retry on a thread's failed page brings the page from screens away, leaving the replies where they were")
    func retryAsksFromAfar() async throws {
        let harness = try Harness()
        defer { harness.close() }
        VoiceOver.listen()
        defer { VoiceOver.done() }
        let replies = (0..<150).map {
            FakeTimelineItem(textEvent("$r\($0)", body: "Reply \($0)"), uniqueID: "thread-r\($0)")
        }
        let thread = try await openFailingThread(harness, replies: replies)
        harness.rooms[0].pageGate.release()
        try #require(await eventually { !accessible("Retry", in: harness.hosting).isEmpty })
        // The thread opens at its newest reply, screens under its loading row.
        try #require(await eventually { threadRows(harness)["$r149"] != nil })
        let before = threadRows(harness)["$r149"]
        thread.olderPages = [[FakeTimelineItem(textEvent("$t0", body: "The oldest reply"), uniqueID: "thread-t0")]]
        #expect(accessible("Retry", in: harness.hosting).contains { $0.accessibilityPerformPress?() == true })
        #expect(await eventually { harness.matrix.threadMessages.contains { $0.eventID == "$t0" } })
        #expect(threadRows(harness)["$r149"] == before)
    }

    @Test("Opening a thread whose root is in the conversation never flashes an Opening thread banner")
    func cachedRootNeverFlashesOpeningBanner() async throws {
        let harness = try Harness()
        defer { harness.close() }
        VoiceOver.listen()
        defer { VoiceOver.done() }
        try #require(await harness.settled(on: 0))
        harness.rooms[0].threadItems = [
            FakeTimelineItem(textEvent("$r1", body: "Reply 1"), uniqueID: "thread-r1")
        ]
        harness.rooms[0].threadStartReached = true
        var sawOpeningBanner = false
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
        ) { _, _ in
            MainActor.assumeIsolated {
                if !accessible("Opening thread…", in: harness.hosting).isEmpty { sawOpeningBanner = true }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        defer { CFRunLoopObserverInvalidate(observer) }

        let message = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? MessageTextView }
                .last { $0.window != nil && !$0.isEditable && !$0.string.isEmpty })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(message.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
        harness.hosting.layoutSubtreeIfNeeded()
        if !accessible("Opening thread…", in: harness.hosting).isEmpty { sawOpeningBanner = true }
        #expect(await eventually { threadRows(harness)["$r1"] != nil })
        #expect(!sawOpeningBanner)
    }

    private func openThreadMenu(for eventID: String, in harness: Harness) throws {
        let cell = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? TimelineCell }.first { cell in
                guard cell.window != nil, case .message(let entry) = cell.entry?.kind else { return false }
                return entry.message.eventID == eventID
            })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(cell.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
    }

    @Test("A cold tall thread with known replies waits for its first page instead of flashing the root and teleporting")
    func coldTallThreadDoesNotFlashRootThenTeleport() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(await harness.settled(on: 0))
        let room = harness.rooms[0]
        let rootID = "$s0-39"
        let replies = (0..<60).map {
            FakeTimelineItem(textEvent("$tall-\($0)", body: "Tall reply \($0)"), uniqueID: "tall-\($0)")
        }
        room.threadItems = []
        room.threadPages = [replies]
        room.threadStartReached = true
        // Give the root message a known reply count, as a message with a replies bar has.
        if let index = harness.matrix.messages.firstIndex(where: { $0.eventID == rootID }) {
            harness.matrix.messages[index].replyCount = 60
        }
        try openThreadMenu(for: rootID, in: harness)
        try #require(await eventually { room.timelines.all.count == 2 && room.pageGate.isWaiting })
        await harness.idle()
        #expect(threadRows(harness)[rootID] == nil)
        room.pageGate.release()
        #expect(await eventually { threadRows(harness)["$tall-59"] != nil })
        #expect(threadRows(harness)[rootID] == nil)
    }

    @Test("Reopening a tall thread cold restores the remembered reply instead of locking on the root alone")
    func coldThreadRestoresRememberedPosition() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(await harness.settled(on: 0))
        let room = harness.rooms[0]
        let rootID = "$s0-39"
        let replies = (0..<60).map {
            FakeTimelineItem(textEvent("$mem-\($0)", body: "Memory reply \($0)"), uniqueID: "mem-\($0)")
        }
        room.threadItems = []
        room.threadPages = [replies]
        room.threadStartReached = true

        // Seed a remembered reading position mid-thread, as leaving the thread would save.
        let key = TimelineMemory.Key(
            sessionID: harness.matrix.notificationSessionID, roomID: room.id(), threadRootID: rootID)
        TimelineMemory.positions[key] = TimelineMemory.Anchor(eventID: "$mem-20", offset: 0)
        defer { TimelineMemory.positions[key] = nil }

        try openThreadMenu(for: rootID, in: harness)
        try #require(await eventually { room.timelines.all.count == 2 && room.pageGate.isWaiting })
        // Let the window draw while the first page is still in flight.
        await harness.idle()
        room.pageGate.release()
        try #require(await eventually { harness.matrix.threadMessages.contains { $0.eventID == "$mem-20" } })
        #expect(await eventually { threadRows(harness)["$mem-20"] != nil })
        #expect(threadRows(harness)["$mem-59"] == nil)
    }
}
