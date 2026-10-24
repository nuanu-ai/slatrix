import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

extension Tag {
    @Tag static var hosted: Tag
}

/// A history page that waits for the test, then lands older messages above the current ones.
private final class HistoryTimeline: Timeline, @unchecked Sendable {
    let gate = Gate()
    var onPage: (@MainActor () -> Void)?
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        await gate.wait()
        await onPage?()
        return false
    }
}

/// The production timeline in a real offscreen window. These need an unlocked, awake display, so they run only
/// with `SLATRIX_HOSTED_UI_CHECKS=1`.
@MainActor
@Suite(
    .serialized, .tags(.hosted),
    .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct TimelineHostedTests {
    private static let room = ChatRoom(id: "!timeline:example.org", name: "Timeline")
    private static let user = "@reader:example.org"

    private struct Fixture: View {
        @ObservedObject var service: MatrixService
        let room: ChatRoom
        let appearance: AppearanceStore
        let previews: AttachmentPreviewController
        let atBottom: (Bool) -> Void
        var body: some View {
            TimelineView(
                matrix: service, room: room, messages: service.messages, savedIDs: [], onThread: { _ in },
                onReply: { _ in }, onEdit: { _ in }, onSave: { _ in }, onBottomVisibilityChange: atBottom
            )
            .id(room.id)
            .environmentObject(appearance).environmentObject(previews)
        }
    }

    @MainActor private final class Harness {
        let service = MatrixService()
        let timeline = HistoryTimeline(noHandle: .init())
        let appearance = AppearanceStore()
        let previews = AttachmentPreviewController()
        let window: NSWindow
        let hosting: NSHostingView<Fixture>
        var bottomReports: [Bool] = []

        init(messages: [ChatMessage], room: ChatRoom = TimelineHostedTests.room) {
            service.user = ChatUser(id: TimelineHostedTests.user, name: "Reader")
            service.rooms = [room]
            service.selectedRoomID = room.id
            service.configureMessageActionsForChecks(
                client: FakeClient(rooms: [FakeRoom(roomInfo(id: room.id))]), main: timeline, thread: nil,
                rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
            service.messages = messages
            window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 620, height: 400), styleMask: .borderless,
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            hosting = NSHostingView(
                rootView: Fixture(
                    service: service, room: room, appearance: appearance, previews: previews, atBottom: { _ in }))
            hosting.rootView = fixture(room)
            window.contentView = hosting
        }

        func fixture(_ room: ChatRoom) -> Fixture {
            Fixture(
                service: service, room: room, appearance: appearance, previews: previews,
                atBottom: { [weak self] in self?.bottomReports.append($0) })
        }

        func close() {
            timeline.gate.release()
            window.contentView = nil
            window.close()
        }

        var scrollView: TimelineScrollView? { Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first }
        var clip: NSClipView { scrollView!.contentView }
        var distanceFromBottom: CGFloat {
            let document = scrollView!.documentView!
            return document.frame.height - clip.bounds.maxY
        }

        /// A message's top edge in window coordinates, while its row is on screen.
        func top(of body: String) -> CGFloat? {
            guard
                let text = Self.views(in: hosting).compactMap({ $0 as? MessageTextView }).first(where: {
                    $0.string == body && $0.window != nil
                })
            else { return nil }
            let frame = text.convert(text.bounds, to: nil)
            return frame.maxY
        }

        func layout() { hosting.layoutSubtreeIfNeeded() }
        var rowCount: Int { (scrollView?.documentView as? NSTableView)?.numberOfRows ?? 0 }

        /// The body of the first message whose text is on screen.
        var firstVisibleBody: String? {
            let visible = clip.convert(clip.bounds, to: nil)
            return Self.views(in: hosting).compactMap { $0 as? MessageTextView }
                .filter { $0.window != nil && visible.contains($0.convert($0.bounds, to: nil)) }
                .min { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }?.string
        }

        func scroll(toTop top: CGFloat) {
            clip.setBoundsOrigin(NSPoint(x: 0, y: top))
            scrollView!.reflectScrolledClipView(clip)
            layout()
        }

        static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    }

    private static func messages(_ range: Range<Int>, prefix: String = "Message") -> [ChatMessage] {
        range.map { index in
            ChatMessage(
                id: "\(prefix)-\(index)", roomID: room.id, senderID: index % 3 == 0 ? user : "@other:example.org",
                senderName: index % 3 == 0 ? "Reader" : "Other", body: "\(prefix) \(index)",
                timestamp: Date(timeIntervalSince1970: 1_761_192_000 + Double(index) * 400))
        }
    }

    private func settle(_ harness: Harness, until condition: () -> Bool = { true }) async {
        _ = await eventually {
            harness.layout()
            return harness.scrollView != nil && condition()
        }
    }

    @Test("A conversation opens at its newest message in its first layout")
    func opensAtBottom() async throws {
        let harness = Harness(messages: Self.messages(0..<40))
        defer { harness.close() }
        harness.layout()
        #expect(harness.scrollView != nil)
        #expect(harness.distanceFromBottom <= TimelineScrollPolicy.bottomTolerance)
        #expect(harness.top(of: "Message 39") != nil)
        await settle(harness) { !harness.bottomReports.isEmpty }
        #expect(harness.bottomReports == [true])
    }

    @Test("A new message keeps a conversation at its newest message")
    func staysPinned() async throws {
        let harness = Harness(messages: Self.messages(0..<40))
        defer { harness.close() }
        await settle(harness)
        harness.service.messages += Self.messages(40..<41)
        await settle(harness) { harness.top(of: "Message 40") != nil }
        #expect(harness.distanceFromBottom <= TimelineScrollPolicy.bottomTolerance)
    }

    @Test("Opening a side pane narrows the conversation without losing its newest message")
    func staysPinnedThroughResize() async throws {
        let harness = Harness(
            messages: Self.messages(0..<40).map { message in
                var message = message
                message.body += " — long enough to wrap once the conversation gets narrower than it was."
                return message
            })
        defer { harness.close() }
        await settle(harness)
        harness.window.setContentSize(NSSize(width: 380, height: 400))
        harness.layout()
        #expect(harness.distanceFromBottom <= TimelineScrollPolicy.bottomTolerance)
        await settle(harness)
        #expect(harness.distanceFromBottom <= TimelineScrollPolicy.bottomTolerance)
    }

    @Test("New messages do not move what you are reading further up")
    func readingStaysStill() async throws {
        let harness = Harness(messages: Self.messages(0..<40))
        defer { harness.close() }
        await settle(harness)
        harness.scroll(toTop: harness.clip.bounds.minY - 900)
        let reading = try #require(harness.firstVisibleBody)
        let before = try #require(harness.top(of: reading))
        let rows = harness.rowCount
        harness.service.messages += Self.messages(40..<45)
        await settle(harness) { harness.rowCount >= rows + 5 }
        #expect(abs(try #require(harness.top(of: reading)) - before) < 0.5)
        #expect(harness.distanceFromBottom > 900)
    }

    @Test("Older history arrives without moving a pixel of what you are reading")
    func prependIsPixelStable() async throws {
        let current = Self.messages(0..<30)
        let older = Self.messages(0..<30, prefix: "Older")
        let harness = Harness(messages: current)
        defer { harness.close() }
        harness.timeline.gate.arm()
        harness.timeline.onPage = { harness.service.messages = older + current }
        await settle(harness)
        // Near the top, the timeline asks for the page before the reader gets there.
        harness.scroll(toTop: 120)
        #expect(await eventually { harness.timeline.gate.isWaiting })
        let before = try #require(harness.top(of: "Message 2"))
        harness.timeline.gate.release()
        // The first layout that contains the older rows must already show the reader's row where it was.
        var after: CGFloat?
        _ = await eventually {
            harness.layout()
            guard harness.top(of: "Older 29") != nil || harness.service.messages.count == 60 else { return false }
            after = harness.top(of: "Message 2")
            return true
        }
        #expect(abs(try #require(after) - before) < 0.5)
    }

    @Test("Leaving a conversation and coming back returns to where you were reading")
    func restoresPosition() async throws {
        let messages = Self.messages(0..<40)
        let harness = Harness(messages: messages)
        defer { harness.close() }
        await settle(harness)
        harness.scroll(toTop: harness.clip.bounds.minY - 700)
        let reading = try #require(harness.firstVisibleBody)
        let before = try #require(harness.top(of: reading))
        let other = ChatRoom(id: "!other:example.org", name: "Other")
        harness.hosting.rootView = harness.fixture(other)
        await settle(harness)
        harness.hosting.rootView = harness.fixture(Self.room)
        await settle(harness) { harness.top(of: reading) != nil }
        #expect(abs(try #require(harness.top(of: reading)) - before) < 0.5)
    }
}

/// Rows on their own: no window needed.
@MainActor
struct MessageRowLayoutTests {
    @Test(
        "Hovering a one-line message shows its time and toolbar without changing its height",
        arguments: [CGFloat(360), 800], [MessageDensity.comfortable, .compact])
    func toolbarOverlays(width: CGFloat, density: MessageDensity) throws {
        let appearance = AppearanceStore()
        let saved = appearance.density
        defer { appearance.density = saved }
        appearance.density = density
        let matrix = MatrixService()
        matrix.user = ChatUser(id: "@reader:example.org", name: "Reader")
        let message = ChatMessage(
            id: "$one", roomID: "!timeline:example.org", senderID: "@reader:example.org", senderName: "Reader",
            body: "One line", timestamp: Date(timeIntervalSince1970: 0))
        func height(hovered: Bool) -> CGFloat {
            let row = MessageRow(
                matrix: matrix, message: message, grouped: true, onThread: {}, onReply: {}, onEdit: {}, onSave: {},
                onDelete: {}, hovered: hovered, timeLabel: "12:00 AM"
            ).environmentObject(appearance)
            return NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        }
        let resting = height(hovered: false)
        #expect(height(hovered: true) == resting)
        // The toolbar fits inside the row, and a comfortable row stays under 36 pt.
        #expect(resting >= MessageRow.toolbarButton)
        if density == .comfortable { #expect(resting < 36) }
    }
}
