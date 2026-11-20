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
        #expect(Policy.position(of: viewport, live: live, visibleRows: [row]) == expected)
    }

    @Test(
        "Under a header and a composer of glass, the reader sees only the clip between them",
        arguments: [(60.0, 110.0, false), (160, 210, true)])
    func glassCoversEnds(clipTop: CGFloat, top: CGFloat, atBottom: Bool) {
        // A 600-point clip over 660 points of rows, a 50-point header over its top and a 100-point composer over its
        // bottom: the newest row is at the bottom only once it sits above the composer.
        let viewport = Viewport(
            clip: CGRect(x: 0, y: clipTop, width: 400, height: 600), covered: (top: 50, bottom: 100),
            contentHeight: 660)
        #expect(viewport.top == top && viewport.height == 450)
        #expect(viewport.isAtBottom == atBottom)
    }

    @Test("Older messages arriving above keep the anchored row at the same point on screen")
    func prependIsPixelStable() {
        let before = Viewport(top: 300, height: 600, contentHeight: 1_000)
        let position = Policy.position(
            of: before, live: true, visibleRows: [Policy.RowFrame(id: "row", top: 280, height: 50)])
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

    @Test(
        "A change the reader didn't make counts as a jump when it moves their row or takes them off the newest message",
        arguments: [
            (Policy.Position.bottom, Viewport(top: 400, height: 600, contentHeight: 1_000), CGFloat?.none),
            (.bottom, Viewport(top: 400, height: 600, contentHeight: 1_195), 195),
            (.anchored(rowID: "row", offset: -20), Viewport(top: 120, height: 600, contentHeight: 1_000), nil),
            (.anchored(rowID: "row", offset: -20), Viewport(top: 7, height: 600, contentHeight: 1_000), 113),
        ])
    func jumps(before: Policy.Position, after: Viewport, moved: CGFloat?) {
        let row = Policy.RowFrame(id: "row", top: 100, height: 50)
        #expect(Policy.jump(from: before, to: after) { $0 == row.id ? row : nil } == moved)
    }

    /// The reader is 800 points into a 1,000-point message, with the next two 200 and 250 points below the top of the
    /// screen.
    private static let reading = Policy.position(
        of: Viewport(top: 2_800, height: 600, contentHeight: 10_000), live: true,
        visibleRows: [
            Policy.RowFrame(id: "long", top: 2_000, height: 1_000), Policy.RowFrame(id: "next", top: 3_000, height: 50),
            Policy.RowFrame(id: "third", top: 3_050, height: 50),
        ])

    @Test(
        "After a change the row the reader was looking at stays where it was on screen, or the next one they saw does",
        arguments: [
            // The long message shrinks, but the top of the screen still falls inside it.
            (
                [Policy.RowFrame(id: "long", top: 2_000, height: 900), .init(id: "next", top: 2_900, height: 50)],
                CGFloat(2_800)
            ),
            // Deleted down to a short row ending above that point: the next message keeps its place.
            ([.init(id: "long", top: 2_000, height: 40), .init(id: "next", top: 2_040, height: 50)], 1_840),
            // Gone, with a page of older history arriving above the next message.
            ([.init(id: "next", top: 3_640, height: 50), .init(id: "third", top: 3_690, height: 50)], 3_440),
            // Both gone: the third keeps its own place.
            ([.init(id: "third", top: 3_700, height: 50)], 3_450),
        ])
    func survivingRowStaysStill(after: [Policy.RowFrame], top: CGFloat) {
        let restored = Policy.top(for: Self.reading, contentHeight: 10_000, viewportHeight: 600) { id in
            after.first { $0.id == id }
        }
        #expect(restored == top)
    }

    @Test(
        "A shrunk or deleted row no longer hides how far the rows the reader saw moved",
        arguments: [
            (
                [Policy.RowFrame(id: "long", top: 2_000, height: 40), .init(id: "next", top: 2_040, height: 50)],
                CGFloat(-960)
            ),
            ([.init(id: "next", top: 3_640, height: 50)], 640),
        ])
    func jumpsOfSurvivingRows(after: [Policy.RowFrame], moved: CGFloat) {
        // The view stayed where the long message's old offset put it.
        let viewport = Viewport(top: 2_800, height: 600, contentHeight: 10_000)
        #expect(Policy.jump(from: Self.reading, to: viewport) { id in after.first { $0.id == id } } == moved)
    }

    @Test("A row that would land below a shorter screen doesn't stand in, so the old offset holds")
    func standInMustShow() {
        // 970 points into a 1,600-point message, the next one 630 points down a 900-point screen.
        let position = Policy.position(
            of: Viewport(top: 2_970, height: 900, contentHeight: 10_000), live: true,
            visibleRows: [.init(id: "long", top: 2_000, height: 1_600), .init(id: "next", top: 3_600, height: 200)])
        // Wider and shorter: the message wraps to 870 points and the screen is 550 high.
        let after = [Policy.RowFrame(id: "long", top: 2_000, height: 870), .init(id: "next", top: 2_870, height: 200)]
        let top = Policy.top(for: position, contentHeight: 10_000, viewportHeight: 550) { id in
            after.first { $0.id == id }
        }
        #expect(top == 2_970)
    }

    @Test("A position whose row is gone restores nothing")
    func missingRow() {
        #expect(
            Policy.top(
                for: .anchored(rowID: "gone", offset: 0), contentHeight: 1_000, viewportHeight: 600, frame: { _ in nil }
            ) == nil)
    }

    // capability: conversation.unread-line
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

    // capability: conversation.jump-to-newest
    @Test(
        "Jump to recent shows once the reader scrolls more than two screens from the newest message themselves",
        arguments: [
            (Viewport(top: 5_400, height: 600, contentHeight: 6_000), true, false),
            (Viewport(top: 4_200, height: 600, contentHeight: 6_000), true, false),
            (Viewport(top: 4_199, height: 600, contentHeight: 6_000), true, true),
            // Where the app put the view, at the unread line or a linked message, the reader needs no way out.
            (Viewport(top: 0, height: 600, contentHeight: 6_000), false, false),
        ])
    func jumpToRecentLive(viewport: Viewport, scrolledByReader: Bool, shows: Bool) {
        #expect(Policy.showsJumpToLatest(viewport, live: true, scrolledByReader: scrolledByReader) == shows)
    }

    @Test("Jump to recent always shows in a timeline opened at an older message, which never shows new ones")
    func jumpToRecentFocused() {
        for top: CGFloat in [0, 5_400] {
            let viewport = Viewport(top: top, height: 600, contentHeight: 6_000)
            #expect(Policy.showsJumpToLatest(viewport, live: false, scrolledByReader: false))
        }
    }

    @Test(
        "A timeline opened at an older message turns live at its newest, unless more is to load or an edit is open",
        arguments: [
            (true, false, false, false, true),
            // Scrolled up, already live, newer history still to load, or editing a message only it may hold.
            (false, false, false, false, false), (true, true, false, false, false), (true, false, true, false, false),
            (true, false, false, true, false),
        ])
    func turnsLive(atBottom: Bool, live: Bool, hasNewer: Bool, editing: Bool, turns: Bool) {
        #expect(Policy.turnsLive(atBottom: atBottom, live: live, hasNewer: hasNewer, editing: editing) == turns)
    }

    // capability: conversation.history
    @Test("History loads within three screens of either end")
    func loadsAhead() {
        #expect(Policy.needsOlder(Viewport(top: 1_799, height: 600, contentHeight: 9_000)))
        #expect(!Policy.needsOlder(Viewport(top: 1_800, height: 600, contentHeight: 9_000)))
        #expect(Policy.needsNewer(Viewport(top: 6_601, height: 600, contentHeight: 9_000)))
        #expect(!Policy.needsNewer(Viewport(top: 6_600, height: 600, contentHeight: 9_000)))
    }
}
