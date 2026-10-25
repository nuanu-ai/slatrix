import CoreGraphics
import Testing

@testable import Slatrix

struct TimelineScrollPolicyTests {
    typealias Policy = TimelineScrollPolicy
    typealias Viewport = TimelineScrollPolicy.Viewport

    @Test(
        "A live timeline at its end follows new messages; anywhere else keeps the top visible row still",
        arguments: [
            (Viewport(top: 400, height: 600, contentHeight: 1_000), true, Policy.Position.bottom),
            (Viewport(top: 399, height: 600, contentHeight: 1_000), true, .bottom),
            (Viewport(top: 300, height: 600, contentHeight: 1_000), true, .anchored(rowID: "row", offset: -20)),
            // A timeline opened at an older message never follows the end.
            (Viewport(top: 400, height: 600, contentHeight: 1_000), false, .anchored(rowID: "row", offset: -120)),
        ])
    func keepsPosition(viewport: Viewport, live: Bool, expected: Policy.Position) {
        let row = Policy.RowFrame(id: "row", top: 280, height: 50)
        #expect(Policy.position(of: viewport, live: live, firstVisibleRow: row) == expected)
    }

    @Test("Older messages arriving above keep the anchored row at the same point on screen")
    func prependIsPixelStable() {
        let before = Viewport(top: 300, height: 600, contentHeight: 1_000)
        let position = Policy.position(
            of: before, live: true, firstVisibleRow: Policy.RowFrame(id: "row", top: 280, height: 50))
        // 640 points of history arrive above the row.
        let top = Policy.top(for: position, contentHeight: 1_640, viewportHeight: 600) {
            $0 == "row" ? Policy.RowFrame(id: "row", top: 920, height: 50) : nil
        }
        #expect(top == 940)
        #expect(920 - top! == 280 - before.top)
    }

    @Test(
        "Restoring a position stays inside the content",
        arguments: [
            (Policy.Position.bottom, 1_000.0, 400.0), (.bottom, 300, 0),
            (.anchored(rowID: "row", offset: 500), 1_000, 0),
            (.anchored(rowID: "row", offset: -900), 1_000, 400), (.centered(rowID: "row"), 1_000, 0),
        ])
    func clamps(position: Policy.Position, contentHeight: CGFloat, expected: CGFloat) {
        let top = Policy.top(for: position, contentHeight: contentHeight, viewportHeight: 600) { _ in
            Policy.RowFrame(id: "row", top: 100, height: 40)
        }
        #expect(top == expected)
    }

    @Test("A position whose row is gone restores nothing")
    func missingRow() {
        #expect(
            Policy.top(
                for: .anchored(rowID: "gone", offset: 0), contentHeight: 1_000, viewportHeight: 600, frame: { _ in nil }
            ) == nil)
    }

    @Test("A conversation resumed from its cache opens at its unread line, wherever the reader left off")
    func liveOpensAtUnread() {
        let loaded: Set = ["unread", "left"]
        #expect(
            Policy.opening(
                focusedRowID: nil, unreadRowID: "unread", startsAtUnread: true,
                remembered: .anchored(rowID: "left", offset: -12), contains: loaded.contains)
                == .anchored(rowID: "unread", offset: 0))
    }

    @Test("A linked message opens centred, below the unread line when resuming, else where the reader left off")
    func opening() {
        let loaded: Set = ["unread", "linked", "left"]
        let remembered = Policy.Position.anchored(rowID: "left", offset: -12)
        #expect(
            Policy.opening(
                focusedRowID: "linked", unreadRowID: "unread", startsAtUnread: false, remembered: remembered,
                contains: loaded.contains) == .centered(rowID: "linked"))
        #expect(
            Policy.opening(
                focusedRowID: "linked", unreadRowID: "unread", startsAtUnread: true, remembered: nil,
                contains: loaded.contains) == .anchored(rowID: "unread", offset: 0))
        #expect(
            Policy.opening(
                focusedRowID: nil, unreadRowID: nil, startsAtUnread: false, remembered: remembered,
                contains: loaded.contains) == remembered)
        #expect(
            Policy.opening(
                focusedRowID: nil, unreadRowID: nil, startsAtUnread: false,
                remembered: .anchored(rowID: "unloaded", offset: 0), contains: loaded.contains) == .bottom)
        #expect(
            Policy.opening(
                focusedRowID: nil, unreadRowID: nil, startsAtUnread: false, remembered: nil,
                contains: loaded.contains) == .bottom)
    }

    @Test(
        "Jump to latest shows only away from the newest message",
        arguments: [
            (Viewport(top: 400, height: 600, contentHeight: 1_000), true, false),
            (Viewport(top: 200, height: 600, contentHeight: 1_000), true, false),
            (Viewport(top: 99, height: 600, contentHeight: 1_000), true, true),
            (Viewport(top: 390, height: 600, contentHeight: 1_000), false, true),
            (Viewport(top: 400, height: 600, contentHeight: 1_000), false, false),
        ])
    func jumpToLatest(viewport: Viewport, live: Bool, shows: Bool) {
        #expect(Policy.showsJumpToLatest(viewport, live: live) == shows)
    }

    @Test("History loads within three screens of either end")
    func loadsAhead() {
        #expect(Policy.needsOlder(Viewport(top: 1_799, height: 600, contentHeight: 9_000)))
        #expect(!Policy.needsOlder(Viewport(top: 1_800, height: 600, contentHeight: 9_000)))
        #expect(Policy.needsNewer(Viewport(top: 6_601, height: 600, contentHeight: 9_000)))
        #expect(!Policy.needsNewer(Viewport(top: 6_600, height: 600, contentHeight: 9_000)))
    }
}
