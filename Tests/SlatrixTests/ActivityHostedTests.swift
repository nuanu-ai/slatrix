import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// Activity in the whole window, offscreen, against SDK fakes; needs an awake display. Only a window that says it is
/// key can be read.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ActivityHostedTests {
    /// Drafts and saved messages, away from the keychain, so threads open ready to read.
    private let local: TemporaryDirectory

    init() throws { local = try TemporaryDirectory() }

    /// The whole window on `room`, with Activity holding `item`; `key` when the reader can read it.
    private func host(_ room: FakeOpenRoom, item: ActivityItem, mentions: Int = 0, key: Bool) -> (
        matrix: MatrixService, hosting: NSHostingView<AnyView>, window: NSWindow
    ) {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: "room.@me:example.org")
        let matrix = MatrixService.scratch()
        matrix.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
        matrix.status = .ready
        let vaultKey: @Sendable (String) async throws -> Data = { _ in Data(repeating: 0x5a, count: 32) }
        let store = ProtectedLocalStateStore(directory: local.url, keyProvider: vaultKey)
        let files = AttachmentDraftStore(
            directory: AttachmentDraftStore.directory(in: local.url), keyProvider: vaultKey)
        let hosting = NSHostingView(
            rootView: AnyView(
                RootView(matrix: matrix, localStore: store, attachmentDrafts: files)
                    .environmentObject(AppearanceStore())
                    .environment(\.metrics, Metrics(zoom: 1))))
        let window = offscreenWindow(NSSize(width: 1_200, height: 800), key: key)
        window.contentView = hosting
        window.orderFrontRegardless()
        var chatRoom = ChatRoom(id: room.id(), name: "activity")
        chatRoom.mentions = mentions
        matrix.rooms = [chatRoom]
        matrix.roomsLoaded = true
        matrix.activity.record(item)
        return (matrix, hosting, window)
    }

    private func item(_ eventID: String, body: String, mention: Bool = false, root: String?) -> ActivityItem {
        ActivityItem(
            id: eventID, roomID: "!activity:example.org", eventID: eventID, roomName: "activity",
            senderID: "@alice:example.org", senderName: "Alice", body: body, timestamp: Date(), hasMention: mention,
            threadRootID: root, kind: .message)
    }

    /// Opens Activity and clicks the row showing `body`.
    private func click(_ body: String, in hosting: NSHostingView<AnyView>) async {
        // Once the window listens for it.
        #expect(
            await eventually {
                NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "activity"])
                return !accessible(body, in: hosting).isEmpty
            })
        #expect(accessible(body, in: hosting).contains { $0.accessibilityPerformPress?() == true })
    }

    // capability: activity.open-item
    @Test(
        "Clicking a thread reply in Activity leaves it unread until its thread is on screen, if it opens at all",
        arguments: [true, false])
    func clickDoesNotOpen(threadOpens: Bool) async throws {
        let root = FakeTimelineItem(textEvent("$root", body: "Root"))
        let room = FakeOpenRoom("!activity:example.org", cached: threadOpens ? [root] : [])
        if threadOpens {
            room.threadRoots = ["$reply": "$root"]
            room.threadItems = [root, FakeTimelineItem(textEvent("$reply", body: "Reply"))]
        } else {
            room.focusedError = URLError(.notConnectedToInternet)
        }
        let body = "Reply \(UUID().uuidString)"
        let (matrix, hosting, window) = host(room, item: item("$reply", body: body, root: "$root"), key: false)
        VoiceOver.listen()
        defer {
            VoiceOver.done()
            window.contentView = nil
            window.close()
        }
        await click(body, in: hosting)
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

    // capability: activity.open-item
    @Test(
        "A reply or mention opened from Activity loses its dot once the reader sees it, with newer messages out of view",
        arguments: [true, false])
    func seenOnceInView(inThread: Bool) async throws {
        let root = FakeTimelineItem(textEvent("$root", body: "Root"))
        let later = (0..<30).map {
            FakeTimelineItem(
                textEvent("$later\($0)", body: String(repeating: "Later words that wrap the line. ", count: 12)))
        }
        let room = FakeOpenRoom("!activity:example.org", cached: [root])
        let target = FakeTimelineItem(textEvent("$target", body: "Target"))
        if inThread {
            room.threadRoots = ["$target": "$root"]
            room.threadItems = [root, target] + later
        } else {
            room.focusedItems = [root, target] + later
        }
        let body = "Target \(UUID().uuidString)"
        let (matrix, hosting, window) = host(
            room, item: item("$target", body: body, mention: !inThread, root: inThread ? "$root" : nil),
            mentions: inThread ? 0 : 1, key: true)
        VoiceOver.listen()
        defer {
            VoiceOver.done()
            window.contentView = nil
            window.close()
        }
        await click(body, in: hosting)
        #expect(
            await eventually {
                matrix.activity.items.allSatisfy { !ActivityBadge.isUnread($0, room: matrix.rooms.first) }
            })
    }

    // capability: activity.open-item
    @Test("An older reply loses its dot when a page of older replies brings it into the open thread")
    func seenOncePaged() async throws {
        let root = FakeTimelineItem(textEvent("$root", body: "Root"))
        let later = (0..<30).map {
            FakeTimelineItem(
                textEvent("$later\($0)", body: String(repeating: "Later words that wrap the line. ", count: 12)))
        }
        let room = FakeOpenRoom("!activity:example.org", cached: [root])
        room.threadRoots = ["$older": "$root", "$newer": "$root"]
        room.threadItems = [root, FakeTimelineItem(textEvent("$newer", body: "Newer"))] + later
        let body = "Newer \(UUID().uuidString)"
        let (matrix, hosting, window) = host(room, item: item("$newer", body: body, root: "$root"), key: true)
        matrix.activity.record(item("$older", body: "Older", root: "$root"))
        VoiceOver.listen()
        defer {
            VoiceOver.done()
            window.contentView = nil
            window.close()
        }
        let unread = { (id: String) in
            matrix.activity.items.contains { $0.id == id && ActivityBadge.isUnread($0, room: matrix.rooms.first) }
        }
        await click(body, in: hosting)
        #expect(await eventually { !unread("$newer") })
        #expect(unread("$older"))
        let thread = try #require(
            room.focuses.all.firstIndex { if case .thread = $0 { true } else { false } }.map { room.timelines.all[$0] })
        thread.emit([.pushFront(value: FakeTimelineItem(textEvent("$older", body: "Older")))])
        #expect(await eventually { !unread("$older") })
    }

    @Test("Mark all as read in Activity clears an unread reply and surfaces a mention-only room")
    func markAllAsReadClearsActivityBadge() async throws {
        let room = FakeOpenRoom("!activity:example.org", cached: [])
        let body = "Unseen \(UUID().uuidString)"
        let (matrix, hosting, window) = host(
            room, item: item("$reply", body: body, root: "$root"), mentions: 1, key: true)
        VoiceOver.listen()
        defer {
            VoiceOver.done()
            window.contentView = nil
            window.close()
        }
        #expect(
            await eventually {
                NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "activity"])
                return !accessible("Mark all as read", in: hosting).isEmpty
            })
        // The mention-only room (unread == 0, mentions == 1) is visible under Unread in Activity's All view.
        #expect(!accessible("1 mention", in: hosting).isEmpty)
        #expect(accessible("Mark all as read", in: hosting).contains { $0.accessibilityPerformPress?() == true })
        #expect(
            await eventually {
                room.markedReceipts.all == [.read, .fullyRead] && room.unreadFlags.all == [false]
                    && matrix.activity.items.allSatisfy { $0.opened }
            })
        // Once the server sync clears room.mentions, Activity's badge reaches zero.
        matrix.rooms[0].mentions = 0
        #expect(ActivityBadge.count(rooms: matrix.rooms, items: matrix.activity.items) == 0)
    }
}
