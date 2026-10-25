import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

extension Tag {
    @Tag static var hosted: Tag
}

/// A history page that waits for the test, then lands older messages above the current ones. `onPage` returns
/// whether that was the oldest page.
private final class HistoryTimeline: Timeline, @unchecked Sendable {
    let gate = Gate()
    var onPage: (@MainActor () -> Bool)?
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        await gate.wait()
        return await onPage?() ?? false
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
        let service: MatrixService
        let room: ChatRoom
        let appearance: AppearanceStore
        let previews: AttachmentPreviewController
        let atBottom: (Bool) -> Void
        var zoom: CGFloat = 1
        var body: some View {
            TimelineView(
                matrix: service, room: room, messages: service.messages, savedIDs: [], onThread: { _ in },
                onReply: { _ in }, onEdit: { _ in }, onSave: { _ in }, onBottomVisibilityChange: atBottom
            )
            .id(room.id)
            .environmentObject(appearance).environmentObject(previews).environment(\.metrics, Metrics(zoom: zoom))
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

        var scrollView: TimelineScrollView? {
            if let found, found.window != nil { return found }
            found = Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first
            return found
        }
        private var found: TimelineScrollView?
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
        harness.timeline.onPage = {
            harness.service.messages = older + current
            return false
        }
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

    @Test("A row the reader is looking at that the table cannot hold still is logged as a jump")
    func logsJumps() async throws {
        let harness = Harness(messages: Self.messages(0..<40))
        defer { harness.close() }
        await settle(harness)
        harness.scroll(toTop: harness.clip.bounds.minY - 120)
        let since = Date()
        // The last rows go, taller together than the reader is scrolled up: the view has to move to stay on content.
        harness.service.messages = Self.messages(0..<36)
        await settle(harness) { harness.rowCount < 40 }
        let jump = await Task.detached {
            await firstPerformanceMessage(since: since) { $0.hasPrefix("event=timeline.jump ") }
        }.value
        #expect(jump != nil)
    }

    @Test("Zooming in redraws the rows already on screen at the new size")
    func zoomRedrawsRows() async throws {
        let harness = Harness(messages: Self.messages(0..<40))
        defer { harness.close() }
        await settle(harness) { harness.top(of: "Message 39") != nil }
        func lineHeight() -> CGFloat? {
            Harness.views(in: harness.hosting).compactMap { $0 as? MessageTextView }
                .first { $0.string == "Message 39" && $0.window != nil }?.frame.height
        }
        let before = try #require(lineHeight())
        var zoomed = harness.fixture(Self.room)
        zoomed.zoom = 1.5
        harness.hosting.rootView = zoomed
        await settle(harness) { (lineHeight() ?? 0) > before * 1.3 }
        #expect(try #require(lineHeight()) > before * 1.3)
        #expect(harness.distanceFromBottom <= TimelineScrollPolicy.bottomTolerance)
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

    @Test("A message at rest offers its whole menu, its VoiceOver actions and the reaction picker")
    func restingRowActions() async throws {
        let harness = Harness(
            messages: Self.messages(0..<5).map {
                var message = $0
                message.id = "$" + message.id
                return message
            })
        defer { harness.close() }
        await settle(harness) { harness.top(of: "Message 4") != nil }
        let text = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? MessageTextView }.first { $0.string == "Message 4" })
        var row: NSView? = text
        while let view = row, !(view is TimelineCell) { row = view.superview }
        let host = try #require(row)
        let frame = host.convert(host.bounds, to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: frame.maxX - 40, y: frame.midY), modifierFlags: [],
                timestamp: 0,
                windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try #require(host.menu(for: event))
        #expect(
            menu.items.map(\.title).filter { !$0.isEmpty } == [
                "Add reaction…", "Reply in thread", "Reply", "Save for later", "Copy text", "Copy link",
            ])
        #expect(
            host.accessibilityCustomActions()?.map(\.name) == ["Reply in thread", "Add reaction", "Save for later"])
        // The text's own menu carries the same commands under its copy item.
        #expect(text.menu(for: event)?.items.map(\.title).contains("Reply in thread") == true)
        // A popover shows only from a window on screen.
        harness.window.orderFrontRegardless()
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let reaction = try #require(menu.items.first { $0.title == "Add reaction…" })
        _ = reaction.target?.perform(reaction.action, with: reaction)
        #expect(
            await eventually {
                NSApp.windows.contains { !windows.contains(ObjectIdentifier($0)) && $0.isVisible }
            })
    }
}

/// Budgets for the table at the scale of a busy room; see `PerformanceBudgetTests`.
extension TimelineHostedTests {
    /// Lays out until `body` is on screen and returns how long that took.
    private func timeUntilShown(_ body: String, in harness: Harness, after change: () -> Void) async -> Duration {
        let start = ContinuousClock.now
        change()
        _ = await eventually(timeout: .seconds(20)) {
            harness.layout()
            return harness.top(of: body) != nil
        }
        return .now - start
    }

    @Test(
        "A room's 1,000 messages arrive and its newest rows are on screen within budget", .tags(.budget),
        .enabled(if: budgetsEnabled))
    func openBudget() async {
        let time = await fastest {
            let harness = Harness(messages: [])
            defer { harness.close() }
            await settle(harness)
            let messages = busyConversation(1_000, roomID: Self.room.id, tag: UUID().uuidString)
            return await timeUntilShown(messages[999].body, in: harness) { harness.service.messages = messages }
        }
        #expect(time < .milliseconds(350), "\(time)")
    }

    @Test(
        "Switching between two 1,000-message rooms shows the other's newest rows within budget", .tags(.budget),
        .enabled(if: budgetsEnabled))
    func switchBudget() async {
        let other = ChatRoom(id: "!other:example.org", name: "Other")
        let time = await fastest {
            let harness = Harness(messages: busyConversation(1_000, roomID: Self.room.id, tag: UUID().uuidString))
            defer { harness.close() }
            await settle(harness)
            let messages = busyConversation(1_000, roomID: other.id, tag: UUID().uuidString)
            return await timeUntilShown(messages[999].body, in: harness) {
                harness.service.messages = messages
                harness.hosting.rootView = harness.fixture(other)
            }
        }
        #expect(time < .milliseconds(260), "\(time)")
    }

    /// Scrolls up `step` points at a time from the newest message, laying out and drawing each step as a frame
    /// would, until the oldest message is on screen; `each` runs after every step.
    private func scrollToTop(
        _ harness: Harness, step: CGFloat = 40, each: (Duration) async -> Void = { _ in }
    ) async {
        for _ in 0..<20_000 {
            let top = harness.clip.bounds.minY
            if top <= 0 && !harness.service.hasMoreHistory { return }
            let start = ContinuousClock.now
            harness.scroll(toTop: max(0, top - step))
            harness.hosting.displayIfNeeded()
            // Work the step queued for after the frame, like a history request, runs before the next one.
            await Task.yield()
            await each(.now - start)
        }
        Issue.record("Never reached the oldest message")
    }

    @Test(
        "Scrolling a 1,000-message room up to its first message keeps its slowest step within budget", .tags(.budget),
        .enabled(if: budgetsEnabled))
    func scrollBudget() async {
        var steps = 0
        let worst = await fastest {
            let harness = Harness(messages: busyConversation(1_000, roomID: Self.room.id, tag: UUID().uuidString))
            defer { harness.close() }
            harness.timeline.onPage = { true }
            harness.window.setContentSize(NSSize(width: 760, height: 900))
            harness.window.orderFrontRegardless()
            await settle(harness)
            var worst = Duration.zero
            steps = 0
            await scrollToTop(harness) {
                worst = max(worst, $0)
                steps += 1
            }
            return worst
        }
        #expect(steps > 1_000)
        #expect(worst < .milliseconds(300), "\(worst)")
    }

    @Test("Scrolling up through history at a reading pace never reaches the loading row")
    func historyArrivesAhead() async throws {
        let all = busyConversation(400, roomID: Self.room.id, tag: UUID().uuidString)
        let harness = Harness(messages: Array(all.suffix(100)))
        defer { harness.close() }
        harness.timeline.gate.arm()
        harness.timeline.onPage = {
            let loaded = harness.service.messages.count + 100
            harness.service.messages = Array(all.suffix(loaded))
            return loaded >= all.count
        }
        await settle(harness)
        let table = try #require(harness.scrollView?.documentView as? NSTableView)
        var waited = 0
        var stalls = 0
        // While older history exists, the row under the top spacer is its loading row.
        // 40 points a frame; each page takes 20 frames, a third of a second at 60 Hz, to arrive.
        await scrollToTop(harness) { _ in
            if harness.timeline.gate.isWaiting {
                waited += 1
                if waited == 20 {
                    waited = 0
                    harness.timeline.gate.release()
                    harness.timeline.gate.arm()
                }
            }
            if harness.service.hasMoreHistory && harness.clip.bounds.minY < table.rect(ofRow: 1).maxY { stalls += 1 }
        }
        #expect(harness.service.messages.count == all.count)
        #expect(stalls == 0)
    }

    @Test(
        "50 new messages land on a 1,000-message room's newest rows within budget", .tags(.budget),
        .enabled(if: budgetsEnabled))
    func appendBudget() async {
        let time = await fastest {
            let tag = UUID().uuidString
            let messages = busyConversation(1_050, roomID: Self.room.id, tag: tag)
            let harness = Harness(messages: Array(messages.prefix(1_000)))
            defer { harness.close() }
            await settle(harness)
            return await timeUntilShown(messages[1_049].body, in: harness) { harness.service.messages = messages }
        }
        #expect(time < .milliseconds(300), "\(time)")
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
        let message = ChatMessage(
            id: "$one", roomID: "!timeline:example.org", senderID: "@reader:example.org", senderName: "Reader",
            body: "One line", timestamp: Date(timeIntervalSince1970: 0))
        func height(hovered: Bool) -> CGFloat {
            let row = MessageRow(message: message, grouped: true, own: true, hovered: hovered, timeLabel: "12:00 AM")
                .environmentObject(appearance)
            return NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        }
        let resting = height(hovered: false)
        #expect(height(hovered: true) == resting)
        // The toolbar fits inside the row, and a comfortable row stays under 36 pt.
        #expect(resting >= MessageRow.toolbarButton)
        if density == .comfortable { #expect(resting < 36) }
    }
}

@MainActor
struct ReplyPreviewLayoutTests {
    @Test(
        "A reply keeps its height while its original loads, arrives or fails",
        arguments: [CGFloat(320), 800])
    func heightHolds(width: CGFloat) {
        let matrix = MatrixService()
        let appearance = AppearanceStore()
        let message = ChatMessage(
            id: "$reply", roomID: "!room:example.org", senderID: "@reader:example.org", senderName: "Reader",
            body: "Agreed", timestamp: Date(timeIntervalSince1970: 0))
        func height(_ preview: ChatReplyPreview) -> CGFloat {
            let view = ReplyPreviewView(matrix: matrix, message: message, preview: preview, origin: nil)
                .environmentObject(appearance)
            return NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        }
        let loading = height(ChatReplyPreview(state: .pending, eventID: "$original"))
        let original = String(repeating: "The original message runs long enough to wrap at any width. ", count: 4)
        let loaded = ChatReplyPreview(
            state: .ready, eventID: "$original", senderID: "@alice:example.org", senderName: "Alice", body: original)
        #expect(height(loaded) == loading)
        #expect(height(ChatReplyPreview(state: .failed, eventID: "$original")) == loading)
        #expect(height(ChatReplyPreview(state: .unavailable, eventID: "$original")) == loading)
    }
}
