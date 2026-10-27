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
        "The sidebar gives up width so the conversation stays usable, never below its minimum",
        arguments: [
            // (preferred, available, inspector, expected)
            (340.0, 1_060.0, 380.0, 239.0),  // smallest window with a thread open
            (340, 1_400, 380, 340),  // room to spare: the preference returns
            (420, 861, 0, 420),  // exact boundary keeps the maximum
            (280, 720, 0, 279),  // one point short shrinks by one point
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
        "The thread or details pane keeps a dragged width, clamped so the conversation stays usable",
        arguments: [
            // (preferred, ideal, available, expected)
            (0.0, 380.0, 1_440.0, 380.0),  // never dragged: the pane's own width
            (.nan, 336, 1_440, 336),  // corrupt preference uses the pane's own width
            (-50, 336, 1_440, 336),
            (500, 380, 1_440, 500),
            (100, 380, 1_440, 280),  // never narrower than the minimum
            (2_000, 380, 2_400, 720),  // never wider than the maximum
            (600, 380, 1_200, 533),  // gives way to a 360 pt conversation beside the narrowest sidebar
            (600, 380, 947, 280),  // exactly the minimum fits
        ] as [(CGFloat, CGFloat, CGFloat, CGFloat)])
    func paneWidth(preferred: CGFloat, ideal: CGFloat, available: CGFloat, expected: CGFloat) {
        #expect(SidebarLayout.paneWidth(preferred: preferred, ideal: ideal, availableWidth: available) == expected)
    }

    @Test("Without room for the minimum pane beside the conversation, the pane covers it", arguments: [946.0, .nan])
    func paneCovers(available: CGFloat) {
        #expect(SidebarLayout.paneWidth(preferred: 380, ideal: 380, availableWidth: available) == nil)
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
