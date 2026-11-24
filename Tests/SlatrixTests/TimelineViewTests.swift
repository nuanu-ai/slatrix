import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
struct TimelineViewTests {
    @Test(
        "Clicking Jump to recent in a thread pane scrolls to the bottom even when the main channel is focused on an older message"
    )
    func threadJumpToRecentScrollsWithoutWipingThread() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }

        let room = ChatRoom(id: "!thread-jump:example.org", name: "general")
        let replies = (0..<40).map { i in
            var message = ChatMessage(
                id: "$r\(i)", roomID: room.id, senderID: "@alice:example.org", senderName: "Alice",
                body: "Thread reply \(i) with enough text to occupy vertical space in the pane",
                timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60))
            if i > 0 { message.threadRootID = "$r0" }
            return message
        }
        let service = MatrixService.scratch()
        service.rooms = [room]
        service.selectedRoomID = room.id
        // Main channel is focused on an older message while a thread pane is open.
        service.focusedEventID = "$older-main"
        service.threadMessages = replies

        let hosting = NSHostingView(
            rootView: TimelineView(
                matrix: service, room: room, thread: true, threadRootID: "$r0", savedIDs: [],
                onThread: { _ in }, onReply: { _ in }, onEdit: { _ in }, onSave: { _ in },
                insets: EdgeInsets(top: 40, leading: 0, bottom: 60, trailing: 0)
            )
            .environmentObject(AppearanceStore())
            .environment(\.metrics, Metrics(zoom: 1)))
        let window = offscreenWindow(NSSize(width: 480, height: 320))
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        try #require(
            await eventually(timeout: .seconds(5)) {
                hosting.layoutSubtreeIfNeeded()
                guard let scroll = views(hosting).compactMap({ $0 as? TimelineScrollView }).first else { return false }
                return scroll.contentView.bounds.minY > 400
            })

        let scroll = try #require(views(hosting).compactMap { $0 as? TimelineScrollView }.first)
        let clip = scroll.contentView
        let bottomY = clip.bounds.minY
        clip.setBoundsOrigin(.zero)
        scroll.reflectScrolledClipView(clip)
        hosting.layoutSubtreeIfNeeded()

        try #require(await eventually(timeout: .seconds(5)) { !accessible("Jump to recent", in: hosting).isEmpty })
        let jumpButton = try #require(accessible("Jump to recent", in: hosting).first)
        #expect(jumpButton.accessibilityPerformPress?() == true)

        // Must scroll the thread back down without calling selectRoom or wiping threadMessages.
        #expect(
            await eventually(timeout: .seconds(5)) {
                hosting.layoutSubtreeIfNeeded()
                return clip.bounds.minY >= bottomY - 40
            })
        #expect(service.threadMessages.count == replies.count)
        #expect(service.focusedEventID == "$older-main")
    }

    @Test("Clicking Jump to recent in a main channel focused on an older message invokes onJumpToLatest")
    func mainChannelJumpToRecentInvokesLatestHandler() async throws {
        _ = NSApplication.shared
        VoiceOver.listen()
        defer { VoiceOver.done() }

        let room = ChatRoom(id: "!main-jump:example.org", name: "general")
        let messages = (0..<6).map { i in
            ChatMessage(
                id: "$m\(i)", roomID: room.id, senderID: "@alice:example.org", senderName: "Alice",
                body: "Message \(i)", timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 60))
        }
        let service = MatrixService.scratch()
        service.rooms = [room]
        service.selectedRoomID = room.id
        service.messages = messages
        service.focusedEventID = messages.first?.id
        var jumpedToLatest = 0

        let hosting = NSHostingView(
            rootView: TimelineView(
                matrix: service, room: room, savedIDs: [],
                onThread: { _ in }, onReply: { _ in }, onEdit: { _ in }, onSave: { _ in },
                onJumpToLatest: { jumpedToLatest += 1 },
                insets: EdgeInsets(top: 40, leading: 0, bottom: 60, trailing: 0)
            )
            .environmentObject(AppearanceStore())
            .environment(\.metrics, Metrics(zoom: 1)))
        let window = offscreenWindow(NSSize(width: 480, height: 320))
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        try #require(await eventually(timeout: .seconds(5)) { !accessible("Jump to recent", in: hosting).isEmpty })
        let jumpButton = try #require(accessible("Jump to recent", in: hosting).first)
        #expect(jumpButton.accessibilityPerformPress?() == true)
        #expect(jumpedToLatest == 1)
    }

    @Test(
        "Messages inside a thread pane omit Reply in thread from context menus and VoiceOver, while main channel messages keep it",
        arguments: [true, false])
    func replyInThreadMenuPresenceMatchesPaneKind(isThread: Bool) async throws {
        _ = NSApplication.shared
        let room = ChatRoom(id: "!menu-pane:example.org", name: "general")
        let message = ChatMessage(
            id: "$m1", roomID: room.id, senderID: "@alice:example.org", senderName: "Alice",
            body: "Hello pane", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        let service = MatrixService.scratch()
        service.rooms = [room]
        service.selectedRoomID = room.id
        if isThread {
            service.threadMessages = [message]
        } else {
            service.messages = [message]
        }

        let hosting = NSHostingView(
            rootView: TimelineView(
                matrix: service, room: room, thread: isThread, threadRootID: isThread ? "$m1" : nil, savedIDs: [],
                onThread: { _ in }, onReply: { _ in }, onEdit: { _ in }, onSave: { _ in },
                insets: EdgeInsets(top: 40, leading: 0, bottom: 60, trailing: 0)
            )
            .environmentObject(AppearanceStore())
            .environment(\.metrics, Metrics(zoom: 1)))
        let window = offscreenWindow(NSSize(width: 480, height: 320))
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        try #require(
            await eventually(timeout: .seconds(5)) {
                hosting.layoutSubtreeIfNeeded()
                return views(hosting).compactMap { $0 as? MessageTextView }.contains { $0.string == "Hello pane" }
            })
        let text = try #require(
            views(hosting).compactMap { $0 as? MessageTextView }.first { $0.string == "Hello pane" })
        var ancestor: NSView? = text
        while let current = ancestor, !(current is TimelineCell) { ancestor = current.superview }
        let cell = try #require(ancestor as? TimelineCell)
        let frame = cell.convert(cell.bounds, to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: frame.maxX - 40, y: frame.midY), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))

        let rowMenuTitles = try #require(cell.menu(for: event)).items.map(\.title)
        let textMenuTitles = try #require(text.menu(for: event)).items.map(\.title)
        let voiceOverNames = try #require(cell.accessibilityCustomActions()).map(\.name)

        let expected = !isThread
        #expect(rowMenuTitles.contains("Reply in thread") == expected, "Row menu: \(rowMenuTitles)")
        #expect(textMenuTitles.contains("Reply in thread") == expected, "Text menu: \(textMenuTitles)")
        #expect(voiceOverNames.contains("Reply in thread") == expected, "VoiceOver: \(voiceOverNames)")
        #expect(rowMenuTitles.contains("Reply"))
        #expect(voiceOverNames.contains("Save for later"))
    }
}
