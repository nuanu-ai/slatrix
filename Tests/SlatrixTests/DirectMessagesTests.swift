import AppKit
import SwiftUI
import Testing

@testable import Slatrix

struct DirectMessagesTests {
    // capability: home.dms
    @Test("The DMs page lists the newest conversation first and marks the latest message when it is yours")
    func newestFirst() {
        let rooms = [
            ChatRoom(id: "!team:example.org", name: "Team"),
            ChatRoom(
                id: "!avery:example.org", name: "Avery", isDirect: true,
                latest: LatestMessage(
                    body: "See you at noon", timestamp: Date(timeIntervalSince1970: 1_000), isOwn: false)),
            ChatRoom(id: "!casey:example.org", name: "Casey", isDirect: true),
            ChatRoom(
                id: "!blake:example.org", name: "Blake", isDirect: true,
                latest: LatestMessage(body: "Shipped it", timestamp: Date(timeIntervalSince1970: 2_000), isOwn: true)),
        ]
        let direct = ChatRoom.directMessages(rooms)
        #expect(direct.map(\.name) == ["Blake", "Avery", "Casey"])
        #expect(direct.map { $0.latest?.preview } == ["You: Shipped it", "See you at noon", nil])
    }

    @Test("DMs opens the direct message read last beside its list, else the newest")
    func opensLastRead() {
        let rooms = [
            ChatRoom(id: "!team:example.org", name: "Team"),
            ChatRoom(
                id: "!avery:example.org", name: "Avery", isDirect: true,
                latest: LatestMessage(body: "Hi", timestamp: Date(timeIntervalSince1970: 2_000), isOwn: false)),
            ChatRoom(id: "!blake:example.org", name: "Blake", isDirect: true),
        ]
        #expect(
            ChatRoom.directMessageToOpen(rooms, visited: ["!blake:example.org", "!team:example.org"])
                == "!blake:example.org")
        #expect(ChatRoom.directMessageToOpen(rooms, visited: ["!team:example.org"]) == "!avery:example.org")
    }

    @Test("Find a DM narrows the list by name, and Unreads to unread conversations and the one open")
    func filters() {
        let rooms = [
            ChatRoom(id: "!avery:example.org", name: "Avery Stone", isDirect: true, unreadMessages: 1),
            ChatRoom(id: "!blake:example.org", name: "Blake", isDirect: true),
            ChatRoom(id: "!casey:example.org", name: "Casey Stone", isDirect: true),
        ]
        #expect(ChatRoom.directMessages(rooms, matching: "stone").map(\.name) == ["Avery Stone", "Casey Stone"])
        #expect(
            ChatRoom.directMessages(rooms, unreadOnly: true, keeping: "!blake:example.org").map(\.name) == [
                "Avery Stone", "Blake",
            ])
    }

    @Test(
        "A latest message shows its time today, Yesterday the day before, and its date before that",
        arguments: [
            ("2026-10-30T09:41:00Z", "9:41 AM"), ("2026-10-29T23:59:00Z", "Yesterday"),
            ("2026-10-03T12:00:00Z", "Oct 3"), ("2025-12-24T12:00:00Z", "Dec 24, 2025"),
        ])
    func time(sent: String, shown: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let latest = LatestMessage(body: nil, timestamp: try Date(sent, strategy: .iso8601), isOwn: false)
        let label = latest.time(now: try Date("2026-10-30T15:00:00Z", strategy: .iso8601), calendar: calendar)
        #expect(label.replacingOccurrences(of: "\u{202F}", with: " ") == shown)
    }

    @MainActor
    @Test("A direct message's row keeps its height when its latest message arrives")
    func rowKeepsHeight() {
        func height(_ room: ChatRoom) -> CGFloat {
            NSHostingView(
                rootView: DirectMessageRow(room: room).frame(width: 600).environmentObject(AppearanceStore())
                    .environment(\.metrics, Metrics(zoom: 1))
            ).fittingSize.height
        }
        var room = ChatRoom(id: "!avery:example.org", name: "Avery", isDirect: true)
        let waiting = height(room)
        room.latest = LatestMessage(body: "See you at noon", timestamp: Date(), isOwn: false)
        #expect(height(room) == waiting)
    }

    // capability: home.dms
    @MainActor
    @Test("Direct Messages sidebar offers a clickable Back to channels button that returns to the channels sidebar")
    func directMessagesBackButtonReturnsToChannels() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }

        let matrix = MatrixService.scratch()
        matrix.rooms = [
            ChatRoom(id: "!general:example.org", name: "general"),
            ChatRoom(id: "!avery:example.org", name: "Avery", isDirect: true),
        ]
        var currentRoute = AppRoute.directMessages
        let m = Metrics(zoom: 1)
        let appearance = AppearanceStore()

        struct Host: View {
            let matrix: MatrixService
            @State var route: AppRoute = .directMessages
            let onChange: (AppRoute) -> Void
            var body: some View {
                SidebarView(
                    matrix: matrix,
                    route: Binding(
                        get: { route },
                        set: {
                            route = $0
                            onChange($0)
                        }),
                    workspaceID: .constant(nil), directMessageSearch: .constant(""),
                    unreadDirectMessagesOnly: .constant(false), draftRoomIDs: [],
                    onSelect: { _ in }, onCreate: { _ in }, onPreferences: {}, onProfile: {}, onSignOut: {},
                    onMarkUnread: { _ in }, onMarkRead: { _ in }, onInviteWorkspace: { _ in },
                    onEditWorkspace: { _ in }, onNotifications: { _ in }, onHide: {}, onBrowseChannels: {},
                    collapsed: .constant([])
                )
            }
        }

        let hosting = NSHostingView(
            rootView: Host(matrix: matrix, onChange: { currentRoute = $0 })
                .frame(width: SidebarLayout.minimumWidth, height: 600)
                .environmentObject(appearance).environment(\.metrics, m))
        let window = offscreenWindow(NSSize(width: SidebarLayout.minimumWidth, height: 600))
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        try #require(await eventually(timeout: .seconds(5)) { !accessible("Back to channels", in: hosting).isEmpty })
        let back = try #require(accessible("Back to channels", in: hosting).first)
        let compose = try #require(accessible("New message", in: hosting).first)
        let composeFrame = compose.accessibilityFrame?() ?? .zero
        #expect(composeFrame.maxX <= window.frame.maxX - m.sp4, "New message clipped at minimum sidebar width")

        #expect(back.accessibilityPerformPress?() == true)
        #expect(
            await eventually(timeout: .seconds(5)) {
                currentRoute == .home && !accessible("Channels", in: hosting).isEmpty
            })
        #expect(accessible("Back to channels", in: hosting).isEmpty)
    }
}
