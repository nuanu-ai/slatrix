import Foundation
import Testing

@testable import Slatrix

struct SidebarLayoutTests {
    @Test(
        "A corrupt or out-of-range stored width restores the default",
        arguments: [Double.nan, .infinity, -.infinity, -1, 0, 219, 421, .greatestFiniteMagnitude])
    func corruptStoredWidth(value: Double) {
        #expect(SidebarLayout.validatedPreferred(value) == 280)
    }

    @Test("A valid stored width is kept exactly", arguments: [220.0, 239.5, 280, 420])
    func validStoredWidth(value: Double) {
        #expect(SidebarLayout.validatedPreferred(value) == CGFloat(value))
    }

    @Test(
        "The sidebar gives up width so the conversation stays readable, never below its minimum",
        arguments: [
            // (preferred, available, inspector, expected)
            (340.0, 1_200.0, 386.0, 256.0),  // a thread beside: the sidebar gives way
            (340, 1_400, 380, 340),  // room to spare: the preference returns
            (420, 978, 0, 420),  // exact boundary keeps the maximum
            (280, 837, 0, 279),  // one point short shrinks by one point
            (280, 400, 380, 220),  // far too small: hold the minimum
            (.nan, 1_400, 0, 280),  // corrupt preference uses the default
            (340, .nan, 0, 220),  // corrupt window width stays finite
            (340, 1_400, .infinity, 220),  // corrupt inspector width cannot widen the sidebar
            (340, 1_400, -380, 340),  // negative inspector width cannot widen the sidebar
        ] as [(CGFloat, CGFloat, CGFloat, CGFloat)])
    func effectiveWidth(preferred: CGFloat, available: CGFloat, inspector: CGFloat, expected: CGFloat) {
        #expect(
            SidebarLayout.effective(preferred: preferred, availableWidth: available, inspectorWidth: inspector)
                == expected)
    }

    @Test(
        "The thread or details pane keeps a dragged width, clamped so the conversation stays readable",
        arguments: [
            // (preferred, ideal, available, expected)
            (0.0, 380.0, 1_440.0, 380.0),  // never dragged: the pane's own width
            (.nan, 336, 1_440, 336),  // corrupt preference uses the pane's own width
            (-50, 336, 1_440, 336),
            (500, 380, 1_440, 500),
            (100, 380, 1_440, 280),  // never narrower than the minimum
            (2_000, 380, 2_400, 720),  // never wider than the maximum
            (600, 380, 1_200, 416),  // gives way to a 480 pt conversation beside the narrowest sidebar
            (600, 380, 1_064, 280),  // exactly the minimum fits
        ] as [(CGFloat, CGFloat, CGFloat, CGFloat)])
    func paneWidth(preferred: CGFloat, ideal: CGFloat, available: CGFloat, expected: CGFloat) {
        #expect(SidebarLayout.paneWidth(preferred: preferred, ideal: ideal, availableWidth: available) == expected)
    }

    @Test(
        "Without room for the minimum pane beside a readable conversation, the pane covers it",
        arguments: [1_063.0, 1_000, .nan])
    func paneCovers(available: CGFloat) {
        #expect(SidebarLayout.paneWidth(preferred: 380, ideal: 380, availableWidth: available) == nil)
    }

    @Test(
        "With the sidebar folded away, the pane covers the conversation only once it would be too narrow alone",
        arguments: [(900.0, 380.0), (774, 280), (773.5, nil)] as [(CGFloat, CGFloat?)])
    func paneBesideCollapsedSidebar(available: CGFloat, expected: CGFloat?) {
        #expect(
            SidebarLayout.paneWidth(preferred: 380, ideal: 380, availableWidth: available, sidebarShown: false)
                == expected)
    }

    @Test("The rail and sidebar leave once the narrowest sidebar no longer fits beside a readable conversation")
    func sidebarCollapses() {
        #expect(!SidebarLayout.collapses(availableWidth: 778))
        #expect(SidebarLayout.collapses(availableWidth: 777.5))
        #expect(SidebarLayout.collapses(availableWidth: .nan))
    }

    @Test("With a pane open, the sidebar leaves first, so the conversation and the pane stay side by side")
    func sidebarCollapsesForPane() {
        #expect(!SidebarLayout.collapses(availableWidth: 1_064, paneOpen: true))
        #expect(SidebarLayout.collapses(availableWidth: 1_063.5, paneOpen: true))
        #expect(SidebarLayout.paneWidth(preferred: 380, ideal: 380, availableWidth: 1_064) == 280)
    }

    @Test("The title bar's search becomes a button in a narrow window")
    func searchField() {
        #expect(SidebarLayout.searchFits(availableWidth: 640))
        #expect(!SidebarLayout.searchFits(availableWidth: 639.5))
    }

    /// Dragging the window's edge back and forth over a threshold must not flicker, so as the width falls each part
    /// gives way exactly once and never returns, with or without a pane open.
    @Test("Each part changes once as the window narrows", arguments: [false, true])
    func noFlipFlop(paneOpen: Bool) {
        let widths = stride(from: 2_000.0, through: 400, by: -0.5).map { CGFloat($0) }
        let states = widths.map { width in
            let collapsed = SidebarLayout.collapses(availableWidth: width, paneOpen: paneOpen)
            return [
                collapsed,
                paneOpen
                    && SidebarLayout.paneWidth(
                        preferred: 380, ideal: 380, availableWidth: width, sidebarShown: !collapsed) == nil,
                !SidebarLayout.searchFits(availableWidth: width),
            ]
        }
        for part in 0..<3 {
            let changes = zip(states, states.dropFirst()).filter { $0[part] != $1[part] }
            #expect(changes.count == (part == 1 && !paneOpen ? 0 : 1), "part \(part)")
        }
    }

    private static let section = [
        ChatRoom(id: "read", name: "read"),
        ChatRoom(id: "open", name: "open"),
        ChatRoom(id: "unread", name: "unread", unreadMessages: 3),
        ChatRoom(id: "mention", name: "mention", mentions: 1),
        ChatRoom(id: "marked", name: "marked", isMarkedUnread: true),
        ChatRoom(id: "dm", name: "dm", isDirect: true, unreadMessages: 2),
        ChatRoom(id: "muted", name: "muted", unreadMessages: 5, muted: true),
        ChatRoom(id: "muted mention", name: "muted mention", mentions: 1, muted: true),
    ]

    @Test("A collapsed section keeps the open conversation and the ones its badge marks unread, in order")
    func collapsedSection() {
        let rooms = SidebarLayout.sectionRooms(Self.section, collapsed: true, selectedID: "open")
        #expect(rooms.map(\.id) == ["open", "unread", "mention", "marked", "dm", "muted mention"])
    }

    @Test("An expanded section lists every conversation")
    func expandedSection() {
        #expect(SidebarLayout.sectionRooms(Self.section, collapsed: false, selectedID: nil) == Self.section)
    }
}
