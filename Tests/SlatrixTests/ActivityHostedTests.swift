import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// Activity in the whole window, offscreen, against SDK fakes; needs an awake display. The test process is never the
/// active app, so nothing in this window is ever on screen to the reader.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ActivityHostedTests {
    // capability: activity.open-item
    @Test(
        "Clicking a thread reply in Activity leaves it unread until its thread is on screen, if it opens at all",
        arguments: [true, false])
    func clickDoesNotOpen(threadOpens: Bool) async throws {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "room.@me:example.org")
        let root = FakeTimelineItem(textEvent("$root", body: "Root"))
        let room = FakeOpenRoom("!activity:example.org", cached: threadOpens ? [root] : [])
        if threadOpens {
            room.threadRoots = ["$reply": "$root"]
            room.threadItems = [root, FakeTimelineItem(textEvent("$reply", body: "Reply"))]
        } else {
            room.focusedError = URLError(.notConnectedToInternet)
        }
        let matrix = MatrixService()
        matrix.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
        matrix.status = .ready
        let hosting = NSHostingView(
            rootView: AnyView(
                RootView(matrix: matrix).environmentObject(AppearanceStore()).environment(\.metrics, Metrics(zoom: 1))))
        let window = offscreenWindow(NSSize(width: 1_200, height: 800))
        window.contentView = hosting
        window.orderFrontRegardless()
        VoiceOver.listen()
        defer {
            VoiceOver.done()
            window.contentView = nil
            window.close()
        }
        matrix.rooms = [ChatRoom(id: room.id(), name: "activity")]
        matrix.roomsLoaded = true
        let body = "Reply \(UUID().uuidString)"
        matrix.activity.record(
            ActivityItem(
                id: "reply", roomID: room.id(), eventID: "$reply", roomName: "activity",
                senderID: "@alice:example.org", senderName: "Alice", body: body, timestamp: Date(), hasMention: false,
                threadRootID: "$root", kind: .message))
        // Once the window listens for it.
        #expect(
            await eventually {
                NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "activity"])
                return !accessible(body, in: hosting).isEmpty
            })
        #expect(accessible(body, in: hosting).contains { $0.accessibilityPerformPress?() == true })
        // The click went to the reply: its thread is open and ready to read, or its conversation failed to load.
        #expect(
            await eventually {
                threadOpens
                    ? matrix.threadReadIdentity?.rootID == "$root"
                    : room.focuses.all.contains { if case .event = $0 { true } else { false } }
            })
        await drainMainActor()
        #expect(ActivityBadge.count(rooms: matrix.rooms, items: matrix.activity.items) == 1)
    }
}
