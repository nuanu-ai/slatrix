import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// Desktop alerts for the conversation on screen, in the whole window, offscreen, against SDK fakes and a recording
/// notification transport; needs an awake display. The window says it is key, so it can read.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct NotificationGateHostedTests {
    /// The OS notification center, which allows alerts and records the events it was handed.
    @MainActor final class Transport: DesktopNotificationTransport {
        private(set) var asked = 0
        private(set) var added: [String?] = []
        func isAuthorized() async throws -> Bool {
            asked += 1
            return true
        }
        func add(_ request: DesktopNotificationRequest) async throws { added.append(request.message.target.eventID) }
        func remove(_ identifier: String) {}
        func clear() {}
        func deliveredIdentifiers() async -> [String] { [] }
    }

    @MainActor final class Harness {
        let room: FakeOpenRoom
        let matrix = MatrixService()
        let appearance = AppearanceStore()
        let transport = Transport()
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        /// Drafts and attachment drafts of its own, away from the development build's.
        private let local: TemporaryDirectory

        init(_ cached: [TimelineItem]) throws {
            _ = NSApplication.shared
            local = try TemporaryDirectory()
            let key: @Sendable (String) async throws -> Data = { _ in Data(repeating: 0x5a, count: 32) }
            UserDefaults.standard.removeObject(forKey: "room.@me:example.org")
            room = FakeOpenRoom("!gate:example.org", cached: cached)
            matrix.configureRoomOpenForChecks(
                client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
                user: ChatUser(id: "@me:example.org", name: "Me"))
            matrix.status = .ready
            appearance.notifications = true
            let delivery = DesktopNotificationDelivery(transport: transport)
            delivery.useAccount("@me:example.org")
            hosting = NSHostingView(
                rootView: AnyView(
                    RootView(
                        matrix: matrix,
                        localStore: ProtectedLocalStateStore(
                            directory: ProtectedLocalStateStore.directory(in: local.url), keyProvider: key),
                        attachmentDrafts: AttachmentDraftStore(
                            directory: AttachmentDraftStore.directory(in: local.url), keyProvider: key),
                        notifications: delivery
                    ).environmentObject(appearance)
                        .environment(\.metrics, Metrics(zoom: 1))))
            window = offscreenWindow(NSSize(width: 1_200, height: 800), key: true)
            window.contentView = hosting
            window.orderFrontRegardless()
            matrix.rooms = [ChatRoom(id: room.id(), name: "gate")]
            matrix.roomsLoaded = true
        }

        func close() {
            UserDefaults.standard.removeObject(forKey: "notifications.enabled")
            window.contentView = nil
            window.close()
        }

        private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        private var scrollView: TimelineScrollView? {
            Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first { $0.window != nil }
        }

        /// Whether any part of the message's row shows between the conversation's header and its composer.
        func shows(_ eventID: String) -> Bool {
            guard let scrollView else { return false }
            let column = scrollView.convert(scrollView.bounds, to: nil)
            let insets = scrollView.contentInsets
            let pane = NSRect(
                x: column.minX, y: column.minY + insets.bottom, width: column.width,
                height: column.height - insets.top - insets.bottom)
            return Self.views(in: scrollView).contains { view in
                guard let cell = view as? TimelineCell, case .message(let entry) = cell.entry?.kind,
                    entry.message.eventID == eventID, !cell.isHiddenOrHasHiddenAncestor
                else { return false }
                return cell.convert(cell.bounds, to: nil).intersects(pane)
            }
        }

        /// Opens the conversation, once the window listens for the menu, and waits for it to show `eventID`.
        func open(showing eventID: String) async -> Bool {
            await eventually {
                if matrix.selectedRoomID == nil {
                    NotificationCenter.default.post(
                        name: .menuAction, object: nil, userInfo: ["action": "next-conversation"])
                }
                return shows(eventID) && matrix.notificationHandler != nil
            }
        }

        /// Scrolls the conversation by `points`, up when negative.
        func scroll(by points: CGFloat) {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.minY + points))
            scrollView.reflectScrolledClipView(clip)
            hosting.layoutSubtreeIfNeeded()
        }

        /// Sync's alert for the message, which may come before the timeline has it.
        func alert(_ eventID: String) throws {
            let target = try #require(
                MatrixNotificationTarget(accountID: "@me:example.org", roomID: room.id(), eventID: eventID))
            let handler = try #require(matrix.notificationHandler)
            handler(DesktopMessageNotification(target: target, title: "gate", body: "New", playSound: false))
        }

        func arrive(_ eventID: String, body: String = "New") throws {
            let timeline = try #require(room.timelines.all.first)
            timeline.emit([.pushBack(value: FakeTimelineItem(textEvent(eventID, body: body)))])
        }
    }

    private static func messages(_ count: Int) -> [TimelineItem] {
        (0..<count).map { FakeTimelineItem(textEvent("$m\($0)", body: "Message \($0)")) }
    }

    // capability: notifications.alert
    @Test("A message that lands at the newest rows of a window the reader can read is never announced")
    func seenIsNotAnnounced() async throws {
        let harness = try Harness(Self.messages(5))
        defer { harness.close() }
        #expect(await harness.open(showing: "$m4"))
        try harness.alert("$new")
        try harness.arrive("$new")
        // Asked last, after the OS allows alerts.
        #expect(await eventually { harness.shows("$new") && harness.transport.asked == 1 })
        await drainMainActor()
        #expect(harness.transport.added.isEmpty)
    }

    // capability: notifications.alert
    @Test("A message that lands below a reader scrolled up inside a message taller than the pane is announced at once")
    func belowTallMessageIsAnnounced() async throws {
        let tall = String(repeating: "A long line of words that wraps across the conversation pane. ", count: 200)
        let harness = try Harness([
            FakeTimelineItem(textEvent("$first", body: "First")), FakeTimelineItem(textEvent("$tall", body: tall)),
        ])
        defer { harness.close() }
        #expect(await harness.open(showing: "$tall"))
        // Up from its end, so the tall message still fills the pane.
        harness.scroll(by: -300)
        let start = ContinuousClock.now
        try harness.alert("$new")
        try harness.arrive("$new")
        #expect(await eventually { harness.transport.added == ["$new"] })
        #expect(ContinuousClock.now - start < ReadStatePolicy.layoutDeadline, "It went without waiting out the pane")
        #expect(!harness.shows("$new"))
    }
}
