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
    let reactions = Recorder<String>()
    var onPage: (@MainActor () -> Bool)?
    override func toggleReaction(itemId: EventOrTransactionId, key: String) async throws -> Bool {
        reactions.append("\(key) \(MatrixMapping.identifier(itemId))")
        return true
    }
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
        let popovers: Popovers
        let atBottom: (Bool) -> Void
        var zoom: CGFloat = 1
        /// A new timeline of the same conversation, as the app opens one at an older message and back.
        var timeline = 0
        var body: some View {
            TimelineView(
                matrix: service, room: room, savedIDs: [], onThread: { _ in },
                onReply: { _ in }, onEdit: { _ in }, onSave: { _ in }, onBottomVisibilityChange: atBottom
            )
            .id("\(room.id):\(timeline)")
            .environmentObject(appearance).environment(\.metrics, Metrics(zoom: zoom)).environment(popovers)
        }
    }

    @MainActor private final class Harness {
        let service = MatrixService()
        let timeline = HistoryTimeline(noHandle: .init())
        let appearance = AppearanceStore()
        let client: FakeClient
        let popovers = Popovers()
        let window: NSWindow
        let hosting: NSHostingView<Fixture>
        var bottomReports: [Bool] = []

        init(messages: [ChatMessage], room: ChatRoom = TimelineHostedTests.room, height: CGFloat = 400) {
            client = FakeClient(rooms: [FakeRoom(roomInfo(id: room.id))])
            service.user = ChatUser(id: TimelineHostedTests.user, name: "Reader")
            service.rooms = [room]
            service.selectedRoomID = room.id
            service.configureMessageActionsForChecks(
                client: client, main: timeline, thread: nil,
                rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
            service.messages = messages
            window = offscreenWindow(NSSize(width: 620, height: height))
            hosting = NSHostingView(
                rootView: Fixture(
                    service: service, room: room, appearance: appearance, popovers: popovers, atBottom: { _ in }))
            hosting.rootView = fixture(room)
            window.contentView = hosting
        }

        func fixture(_ room: ChatRoom) -> Fixture {
            Fixture(
                service: service, room: room, appearance: appearance, popovers: popovers,
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

        /// The on-screen row of the message with this event or transaction ID.
        func cell(showing eventID: String) -> TimelineCell? {
            Self.views(in: hosting).compactMap { $0 as? TimelineCell }.first { cell in
                guard cell.window != nil, case .message(let entry) = cell.entry?.kind else { return false }
                return entry.message.eventID == eventID
            }
        }
        var showsImage: Bool { Self.views(in: hosting).contains { ($0 as? NSImageView)?.image != nil } }
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

    @Test("An image's row keeps the height it reserved when the image arrives, so nothing around it moves")
    func imageArrivalKeepsLayout() async throws {
        let harness = Harness(messages: [], height: 800)
        defer { harness.close() }
        harness.client.thumbnail = try pngData()
        harness.client.thumbnails.arm()
        harness.service.projectMediaCaptionForChecks(
            [
                FakeTimelineItem(textEvent("$before", body: "Before the photo")),
                FakeTimelineItem(try imageEvent("$photo", width: 1_600, height: 900)),
                FakeTimelineItem(textEvent("$after", body: "After the photo")),
            ], roomID: Self.room.id, inThread: false)
        await settle(harness) { harness.top(of: "After the photo") != nil && harness.client.thumbnails.isWaiting }
        let before = try #require(harness.top(of: "Before the photo"))
        let after = try #require(harness.top(of: "After the photo"))
        harness.client.thumbnails.release()
        #expect(
            await eventually {
                harness.layout()
                return harness.showsImage
            })
        harness.layout()
        // The row's content still measures the height the table gave it before the image came.
        let row = try #require(harness.cell(showing: "$photo"))
        #expect(ceil(row.height(width: row.frame.width)) == row.frame.height)
        #expect(try #require(harness.top(of: "Before the photo")) == before)
        #expect(try #require(harness.top(of: "After the photo")) == after)
    }

    @Test("Your own image appears once the server confirms it, without reopening the conversation")
    func sentImageAppearsWhenConfirmed() async throws {
        let harness = Harness(messages: [], height: 800)
        defer { harness.close() }
        harness.client.thumbnail = try pngData()
        let url = "mxc://example.org/photo"
        func show(_ event: EventTimelineItem) {
            harness.service.projectMediaCaptionForChecks(
                [FakeTimelineItem(event, uniqueID: "photo")], roomID: Self.room.id, inThread: false)
        }
        show(try imageEvent("photo-transaction", width: 1_600, height: 900, url: url, sending: true))
        await settle(harness) { harness.cell(showing: "photo-transaction") != nil }
        show(try imageEvent("$photo", width: 1_600, height: 900, url: url))
        #expect(
            await eventually {
                harness.layout()
                return harness.cell(showing: "$photo") != nil && harness.showsImage
            })
    }

    @Test("Your own image shows from the copy being sent and stays on screen as the server confirms it")
    func sendingImageStaysWhenConfirmed() async throws {
        let harness = Harness(messages: [], height: 800)
        defer { harness.close() }
        harness.client.stored = try pngData()
        // The server's thumbnail never comes, so a picture after the confirmation is the one shown while sending.
        harness.client.thumbnails.arm()
        defer { harness.client.thumbnails.release() }
        let url = "mxc://example.org/photo"
        func show(_ event: EventTimelineItem) {
            harness.service.projectMediaCaptionForChecks(
                [FakeTimelineItem(event, uniqueID: "photo")], roomID: Self.room.id, inThread: false)
        }
        show(try imageEvent("photo-transaction", width: 1_600, height: 900, url: url, sending: true))
        #expect(
            await eventually {
                harness.layout()
                return harness.showsImage
            })
        show(try imageEvent("$photo", width: 1_600, height: 900, url: url))
        await settle(harness) { harness.cell(showing: "$photo") != nil }
        #expect(harness.showsImage)
    }

    @Test(
        "Your message keeps its height and place as the server confirms it, with no sending line coming and going",
        arguments: [true, false])
    func confirmedSendKeepsLayout(grouped: Bool) async throws {
        let earlier = Self.messages(0..<10)
        // The fixture's messages are long past, so this one has been sending long enough to show the slow clock.
        var echo = ChatMessage(
            id: "mine", roomID: Self.room.id, senderID: Self.user, senderName: "Reader", body: "On my way",
            timestamp: earlier[9].timestamp.addingTimeInterval(grouped ? 60 : 3_600))
        echo.timelineEventID = "mine-transaction"
        echo.sendState = "sending"
        let harness = Harness(messages: earlier)
        defer { harness.close() }
        await settle(harness) { harness.top(of: "Message 9") != nil }
        harness.service.messages = earlier + [echo]
        await settle(harness) { harness.cell(showing: "mine-transaction") != nil }
        let sending = try #require(harness.cell(showing: "mine-transaction"))
        let frame = sending.convert(sending.bounds, to: nil)
        let above = try #require(harness.top(of: "Message 9"))

        var confirmed = echo
        confirmed.timelineEventID = "$mine"
        confirmed.sendState = "sent"
        harness.service.messages = earlier + [confirmed]
        await settle(harness) { harness.cell(showing: "$mine") != nil }
        let sent = try #require(harness.cell(showing: "$mine"))
        #expect(sent.convert(sent.bounds, to: nil) == frame)
        #expect(harness.top(of: "Message 9") == above)
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

    @Test("Leaving an older message for the newest ones lands at the newest, wherever the reader had been")
    func returnFromOlderLandsAtNewest() async throws {
        let harness = Harness(messages: Self.messages(0..<40))
        defer { harness.close() }
        await settle(harness)
        harness.scroll(toTop: harness.clip.bounds.minY - 700)
        var fixture = harness.fixture(Self.room)
        fixture.timeline = 1
        harness.service.focusedEventID = "Message-5"
        harness.hosting.rootView = fixture
        await settle(harness) { harness.top(of: "Message 5") != nil }
        fixture.timeline = 2
        harness.service.focusedEventID = nil
        harness.hosting.rootView = fixture
        await settle(harness) { harness.top(of: "Message 39") != nil }
        #expect(harness.distanceFromBottom <= TimelineScrollPolicy.bottomTolerance)
    }

    @Test("Jumping to a loaded message scrolls it into view in the same table and highlights it at its own height")
    func jumpToLoaded() async throws {
        let harness = Harness(messages: Self.messages(0..<80))
        defer { harness.close() }
        await settle(harness)
        let scrollView = try #require(harness.scrollView)
        #expect(harness.top(of: "Message 10") == nil)
        harness.service.jump = MessageJump(roomID: Self.room.id, eventID: "Message-10")
        // In the layout that takes the jump, before the highlight changes any row.
        harness.layout()
        #expect(harness.top(of: "Message 10") != nil)
        await settle(harness)
        #expect(harness.scrollView === scrollView)
        let row = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? TimelineCell }.first { cell in
                guard cell.window != nil, case .message(let entry) = cell.entry?.kind else { return false }
                return entry.message.eventID == "Message-10"
            })
        guard case .message(let entry) = row.entry?.kind else { return }
        #expect(entry.highlighted)
        #expect(ceil(row.height(width: row.frame.width)) == row.frame.height)
        // Jumping to it again while it is still highlighted, after scrolling away, comes back to it.
        harness.scroll(toTop: harness.clip.bounds.minY + 4_000)
        #expect(harness.top(of: "Message 10") == nil)
        harness.service.jump = MessageJump(roomID: Self.room.id, eventID: "Message-10")
        harness.layout()
        #expect(harness.top(of: "Message 10") != nil)
    }

    @Test("A message at rest offers its whole menu, its VoiceOver actions and the emoji picker")
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
        let reaction = try #require(menu.items.first { $0.title == "Add reaction…" })
        _ = reaction.target?.perform(reaction.action, with: reaction)
        guard case .emoji(let pick) = harness.popovers.current?.kind else {
            Issue.record("No emoji picker")
            return
        }
        pick.action("🎉")
        #expect(await eventually { harness.timeline.reactions.all == ["🎉 $Message-4"] })
    }
}

extension TimelineHostedTests {
    private static func actionable(_ range: Range<Int>) -> [ChatMessage] {
        messages(range).map {
            var message = $0
            message.id = "$" + message.id
            return message
        }
    }

    /// Hovers the middle of a message's text, as the pointer would, and returns the text view.
    private func hover(_ harness: Harness, _ body: String) throws -> MessageTextView {
        let text = try #require(
            Harness.views(in: harness.hosting).compactMap { $0 as? MessageTextView }.first {
                $0.string.hasPrefix(body) && $0.window != nil
            })
        let frame = text.convert(text.bounds, to: nil)
        harness.scrollView?.onPointer?(NSPoint(x: frame.midX, y: frame.midY))
        harness.layout()
        return text
    }

    private func toolbar(_ harness: Harness) -> NSView? {
        harness.scrollView?.subviews.first { $0 is TimelineToolbarView && !$0.isHidden }
    }

    @Test("Hovering a message floats the toolbar over its top edge, and no row moves or changes height")
    func hoverKeepsRowsStill() async throws {
        var messages = Self.actionable(0..<30)
        messages[27].reactions = [MessageReaction(key: "👍", count: 2, mine: true, senders: [Self.user, "@b:x"])]
        messages[27].replyCount = 3
        messages[28].isEdited = true
        let harness = Harness(messages: messages)
        defer { harness.close() }
        await settle(harness) { harness.top(of: "Message 29") != nil }
        let table = try #require(harness.scrollView?.documentView as? NSTableView)
        // The newest rows, on screen and so measured.
        func heights() -> [CGFloat] {
            (table.numberOfRows - 7..<table.numberOfRows).map { table.rect(ofRow: $0).height }
        }
        let bodies = ["Message 27", "Message 28", "Message 29"]
        let before = heights()
        let tops = bodies.map(harness.top)
        for body in bodies {
            var cell: NSView? = try hover(harness, body)
            while let view = cell, !(view is TimelineCell) { cell = view.superview }
            let row = try #require(cell as? TimelineCell)
            let frame = row.convert(row.bounds, to: nil)
            let shown = try #require(toolbar(harness))
            let bar = shown.convert(shown.bounds, to: nil)
            #expect(abs(bar.midY - frame.maxY) < 1, "\(body)")
            #expect(bar.maxX < frame.maxX && bar.height >= MessageToolbar.button)
            // The hovered row lays out at the height it was measured at without hover.
            #expect(abs(row.height(width: row.bounds.width) - row.bounds.height) < 0.5, "\(body)")
        }
        await drainMainActor()
        harness.layout()
        #expect(heights() == before)
        #expect(bodies.map(harness.top) == tops)
        // Leaving the timeline takes the toolbar with it.
        harness.scrollView?.onPointer?(nil)
        #expect(toolbar(harness) == nil)
    }

    @Test("The pointer is an I-beam over message text and an arrow over the hover toolbar on top of it")
    func toolbarCursor() async throws {
        var messages = Self.actionable(0..<6)
        // Grouped under the message before it, so the toolbar over its top edge covers its first line of text.
        messages[5].timestamp = messages[4].timestamp.addingTimeInterval(30)
        messages[5].body = String(repeating: "word ", count: 60)
        let harness = Harness(messages: messages)
        defer { harness.close() }
        await settle(harness) { harness.top(of: messages[5].body) != nil }
        let text = try hover(harness, "word word")
        let frame = text.convert(text.bounds, to: nil)
        let shown = try #require(toolbar(harness))
        let bar = shown.convert(shown.bounds, to: nil)
        let overToolbar = NSPoint(x: bar.midX, y: bar.minY + 3)
        let body = NSPoint(x: frame.minX + 10, y: frame.minY + 6)
        #expect(frame.contains(overToolbar))
        // The toolbar never takes the click that would drag the window.
        #expect(!shown.mouseDownCanMoveWindow)
        let window = harness.window

        // AppKit sends the text view these for its whole visible rect, wherever the pointer enters or moves.
        func entered(at point: NSPoint) throws -> NSCursor {
            NSCursor.crosshair.set()
            text.cursorUpdate(
                with: try #require(
                    NSEvent.enterExitEvent(
                        with: .cursorUpdate, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
                        userData: nil)))
            return NSCursor.current
        }
        func moved(to point: NSPoint) throws -> NSCursor {
            text.mouseMoved(
                with: try #require(
                    NSEvent.mouseEvent(
                        with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
            return NSCursor.current
        }
        #expect(try entered(at: body) == .iBeam)
        #expect(try entered(at: overToolbar) == .arrow)
        #expect(try moved(to: body) == .iBeam)
        #expect(try moved(to: overToolbar) == .arrow)
        #expect(try moved(to: body) == .iBeam)
    }

    private func tooltip(_ harness: Harness) -> TooltipView? {
        harness.window.childWindows?.lazy.compactMap { $0.contentView as? TooltipView }.first
    }

    @Test("Hovering a reaction shows who reacted above it after a short delay, moving no row, and leaving hides it")
    func reactionTooltip() async throws {
        // Few enough to fit on screen, so no row is measured ahead of the reader (which follows the real pointer).
        var messages = Self.actionable(0..<4)
        messages[3].reactions = [MessageReaction(key: "👍", count: 2, mine: true, senders: ["@bea:x", Self.user])]
        let harness = Harness(messages: messages)
        harness.service.members = [ChatUser(id: "@bea:x", name: "Bea")]
        // History stays loading, so no page lands while the test points.
        harness.timeline.gate.arm()
        defer { harness.close() }
        await settle(harness) { harness.top(of: "Message 3") != nil }
        let table = try #require(harness.scrollView?.documentView as? NSTableView)
        func heights() -> [CGFloat] { (0..<table.numberOfRows).map { table.rect(ofRow: $0).height } }
        let text = try hover(harness, "Message 3")
        var cell: NSView? = text
        while let view = cell, !(view is TimelineCell) { cell = view.superview }
        let row = try #require(cell).convert(try #require(cell).bounds, to: nil)
        harness.layout()
        await drainMainActor()
        let before = heights()
        let top = harness.top(of: "Message 3")

        // The reaction is the row's last line: a 24 pt chip over the row's 4 pt bottom padding, under the text.
        let m = Metrics()
        let chip = NSPoint(x: text.convert(text.bounds, to: nil).minX + m.sp8, y: row.minY + m.sp4 + m.sp24 / 2)
        harness.scrollView?.onPointer?(chip)
        let start = ContinuousClock.now
        #expect(tooltip(harness) == nil, "Nothing shows at once")
        _ = await eventually { tooltip(harness) != nil }
        let shown = try #require(tooltip(harness))
        #expect(ContinuousClock.now - start >= .milliseconds(250))
        #expect(shown.text == "You and Bea reacted with :+1:")
        let frame = harness.window.convertFromScreen(try #require(shown.window).frame)
        #expect(frame.minY >= chip.y && frame.minX <= chip.x && chip.x <= frame.maxX)
        // Inside the window, but for room the shadow takes.
        #expect(harness.hosting.bounds.insetBy(dx: -m.sp12, dy: -m.sp12).contains(frame))
        harness.layout()
        #expect(heights() == before)
        #expect(harness.top(of: "Message 3") == top)

        harness.scrollView?.onPointer?(nil)
        #expect(tooltip(harness) == nil)
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
        "Hovering a message shows its time and add-reaction chip without changing its height",
        arguments: [CGFloat(360), 800], [MessageDensity.comfortable, .compact])
    func hoverKeepsHeight(width: CGFloat, density: MessageDensity) throws {
        let appearance = AppearanceStore()
        let saved = appearance.density
        defer { appearance.density = saved }
        appearance.density = density
        var message = ChatMessage(
            id: "$one", roomID: "!timeline:example.org", senderID: "@reader:example.org", senderName: "Reader",
            body: "One line", timestamp: Date(timeIntervalSince1970: 0))
        func height(hovered: Bool) -> CGFloat {
            let row = MessageRow(message: message, grouped: true, own: true, hovered: hovered, timeLabel: "12:00 AM")
                .environmentObject(appearance)
            return NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: width, height: 10_000)).height
        }
        let resting = height(hovered: false)
        #expect(height(hovered: true) == resting)
        // A comfortable one-line row stays under 36 pt.
        if density == .comfortable { #expect(resting < 36) }
        message.isEdited = true
        #expect(height(hovered: false) == resting, "(edited) sits on the last line")
        message.reactions = [MessageReaction(key: "👍", count: 1, mine: true)]
        message.replyCount = 2
        message.lastReply = ThreadReply(
            senderID: "@julia:example.org", senderName: "Julia", timestamp: Date(timeIntervalSince1970: 0))
        let decorated = height(hovered: false)
        #expect(height(hovered: true) == decorated)
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
