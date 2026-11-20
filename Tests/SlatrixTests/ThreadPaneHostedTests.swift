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

    /// The thread of the first conversation's newest message, opened through its menu, its first page failing.
    private func openFailingThread(_ harness: Harness) async throws -> FakeLiveTimeline {
        try #require(await harness.settled(on: 0))
        harness.rooms[0].threadItems = []
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
}
