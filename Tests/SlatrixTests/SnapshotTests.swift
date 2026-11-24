import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

extension Tag {
    @Tag static var snapshots: Tag
}

/// A conversation with nothing older, so the timeline starts at its welcome and asks for no history.
private final class StartOfTimeline: Timeline, @unchecked Sendable {
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool { true }
}

/// Julia has a photo and a status, Sam is in a call, and anyone else has only a name.
private final class ProfileClient: Client, @unchecked Sendable {
    let photo: String
    init(photo: String) {
        self.photo = photo
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getProfile(userId: String) async throws -> UserProfile {
        switch userId {
        case "@julia:harbor.example":
            UserProfile(
                userId: userId, displayName: "Julia Park", avatarUrl: photo,
                status: UserStatus(emoji: "🌴", text: "Out until Monday"), call: nil)
        case "@sam:harbor.example":
            UserProfile(
                userId: userId, displayName: "Sam Ortiz", avatarUrl: nil, status: nil,
                call: UserCall(callJoinedTs: nil))
        default: UserProfile(userId: userId, displayName: "Dmitry", avatarUrl: nil, status: nil, call: nil)
        }
    }
    override func isUserStatusSupported() async throws -> Bool { true }
}

/// Holds a value the view under test binds to, as its parent would.
private struct WithState<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content
    init(_ value: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: value)
        self.content = content
    }
    var body: some View { content($value) }
}

/// Renders the sample workspace in-process and writes PNGs to `.build/snapshots/` for a person to look at.
/// Opt in with `SLATRIX_SNAPSHOTS=1 swift test --filter Snapshots`; nothing is compared automatically.
@MainActor
@Suite(.serialized, .tags(.snapshots), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_SNAPSHOTS"] != nil))
struct Snapshots {
    enum Theme: String, CaseIterable { case light, dark }

    @Test("Channel and thread windows", arguments: [1, 1.5, 2], Theme.allCases)
    func window(zoom: Double, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        let hosting = NSHostingView(
            rootView: RootView(scratch: matrix).environmentObject(appearance).environment(
                \.metrics, Metrics(zoom: zoom))
        )
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Still off screen, but ordered in, so the window server composites it for `settledImage`.
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }

        let name = "\(Int(zoom * 100))-\(theme.rawValue)"
        _ = try await settledImage(hosting)
        for editor in textViews(in: hosting) where editor.isEditable {
            editor.insertText("Drafting a reply with **bold** text", replacementRange: editor.selectedRange())
        }
        try write(await settledImage(hosting), "channel-\(name)")
        // Scrolled up a little, so messages pass under the composer's glass, then back to the newest.
        let timeline = try #require(Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first)
        func scrollTimeline(by delta: CGFloat) {
            timeline.contentView.setBoundsOrigin(NSPoint(x: 0, y: timeline.contentView.bounds.minY + delta))
            timeline.reflectScrolledClipView(timeline.contentView)
        }
        scrollTimeline(by: -160)
        try write(await settledImage(hosting), "channel-scrolled-\(name)")
        scrollTimeline(by: 160)

        // A file dragged over the conversation, then over the thread once it opens: the rightmost pane takes it.
        let drag = FakeDrag(files: [URL(fileURLWithPath: #filePath)], over: window)
        func dropOverlay(_ name: String) async throws {
            let target = try #require(
                Self.views(in: hosting).compactMap { $0 as? UploadDropView }.max {
                    $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
                })
            _ = target.draggingEntered(drag)
            try write(await settledImage(hosting), name)
            target.draggingExited(drag)
        }
        try await dropOverlay("drop-channel-\(name)")

        // Open a thread through the message's own context menu, the same item a right-click shows.
        // The sample workspace answers any thread with the same replies, so use a message that is always on screen.
        let thread = try #require(textViews(in: hosting).last { !$0.isEditable && !$0.string.isEmpty })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(thread.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
        _ = try await settledImage(hosting)
        for editor in textViews(in: hosting) where editor.isEditable && editor.string.isEmpty {
            editor.insertText("Replying in the thread", replacementRange: editor.selectedRange())
        }
        try write(await settledImage(hosting), "thread-\(name)")
        try await dropOverlay("drop-thread-\(name)")

        // The profile card, from the same message's "View profile" item.
        let profile = try #require(thread.menu(for: event)?.items.first { $0.identifier?.rawValue == "profile" })
        _ = profile.target?.perform(profile.action, with: profile)
        try write(await settledImage(hosting), "profile-\(name)")
    }

    @Test("The title bar with the window buttons, and Preferences open under it", arguments: [1, 1.5], Theme.allCases)
    func titleBar(zoom: Double, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(
            rootView: RootView(scratch: matrix).environmentObject(appearance).environment(
                \.metrics, Metrics(zoom: zoom))
        )
        // Titled, as `.hiddenTitleBar` sets up the app's window, so the composite has the window buttons.
        let window = offscreenWindow(
            NSSize(width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        let name = "\(Int(zoom * 100))-\(theme.rawValue)"
        try write(await settledImage(hosting), "titlebar-\(name)")
        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "preferences"])
        try write(await settledImage(hosting), "preferences-\(name)")
    }

    @Test("Every theme, light and dark", arguments: ColorTheme.allCases, Theme.allCases)
    func colorTheme(_ colorTheme: ColorTheme, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let saved = [
            "appearance.mode", "appearance.theme", "appearance.chatWallpaper", "appearance.increaseContrast",
            "appearance.workspaceThemes", "layout.sidebarHidden",
        ].map {
            ($0, UserDefaults.standard.object(forKey: $0))
        }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        appearance.theme = colorTheme
        appearance.chatWallpaper = true
        appearance.increaseContrast = false
        appearance.workspaceThemes = [:]
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(
            NSSize(width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        let name = "theme-\(colorTheme.rawValue)-\(theme.rawValue)"
        try write(await settledImage(hosting), name)
        guard colorTheme.isColored || colorTheme.isTranslucent else { return }
        // Too narrow to dock the sidebar, so it opens as a drawer over the conversation.
        window.setContentSize(NSSize(width: 480, height: 800))
        _ = try await settledImage(hosting)
        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "toggle-sidebar"])
        try write(await settledImage(hosting), name + "-drawer")
    }

    @Test("Window widths, with and without a thread, and the collapsed sidebar's drawer", arguments: Theme.allCases)
    func widths(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        func menu(_ action: String) {
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
        }
        _ = try await settledImage(hosting)
        for width in [1440, 1000, 800, 600, 480] {
            window.setContentSize(NSSize(width: width, height: 900))
            try write(await settledImage(hosting), "width-\(width)-\(theme.rawValue)")
        }
        menu("toggle-sidebar")
        try write(await settledImage(hosting), "width-480-drawer-\(theme.rawValue)")
        menu("dms")
        try write(await settledImage(hosting), "width-480-drawer-dms-\(theme.rawValue)")
        menu("mark-read")

        // The same widths with a thread open, from the newest message's own context menu.
        let message = try #require(textViews(in: hosting).last { !$0.isEditable && !$0.string.isEmpty })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(message.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
        for width in [480, 600, 800, 1000, 1280, 1440] {
            window.setContentSize(NSSize(width: width, height: 900))
            try write(await settledImage(hosting), "width-\(width)-thread-\(theme.rawValue)")
        }
    }

    @Test("A message jumped to, in the live conversation and at an older message", arguments: Theme.allCases)
    func jump(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        let room = try #require(matrix.selectedRoomID)
        matrix.jump = MessageJump(roomID: room, eventID: "preview.share")
        // The highlight fades after a moment; settling would wait it out.
        try await Task.sleep(for: .milliseconds(800))
        try write(Self.image(window), "jump-live-\(theme.rawValue)")
        matrix.focusedEventID = "preview.share"
        matrix.jump = MessageJump(roomID: room, eventID: "preview.share")
        try await Task.sleep(for: .milliseconds(800))
        try write(Self.image(window), "jump-older-\(theme.rawValue)")
    }

    @Test("A channel's header with its facepile, and a direct message's with the person", arguments: Theme.allCases)
    func headers(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "header-channel-\(theme.rawValue)")
        // Planning and Demos is the sample's private channel.
        matrix.selectPreviewRoom("preview.room.5")
        try write(await settledImage(hosting), "header-private-channel-\(theme.rawValue)")
        matrix.selectPreviewRoom("preview.dm.0")
        try write(await settledImage(hosting), "header-dm-\(theme.rawValue)")
    }

    @Test("The line in place of the composer in a channel you may not post in", arguments: Theme.allCases)
    func cannotPost(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let index = try #require(matrix.rooms.firstIndex { $0.id == matrix.selectedRoomID })
        matrix.rooms[index].canPostMessages = false
        try await render(RootView(scratch: matrix), theme: theme, name: "cannot-post")
    }

    @Test("The offline banner, and a toast over the conversation", arguments: Theme.allCases)
    func bannerAndToast(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: false, canRetry: true,
                errorMessage: "You’re offline. Check your connection."
            ))
        // The banner waits out a brief drop first.
        try await Task.sleep(for: LoadingPresentation.connectionNoticeDelay)
        try write(await settledImage(hosting), "banner-offline-\(theme.rawValue)")
        matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))

        let message = try #require(textViews(in: hosting).last { !$0.isEditable && !$0.string.isEmpty })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let save = try #require(message.menu(for: event)?.items.first { $0.identifier?.rawValue == "save" })
        _ = save.target?.perform(save.action, with: save)
        try write(await settledImage(hosting), "toast-\(theme.rawValue)")
    }

    @Test(
        "Sidebar, with a short list, and a long one at its top and at its end", arguments: Theme.allCases,
        [false, true])
    func sidebar(theme: Theme, long: Bool) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        if long {
            matrix.rooms += (0..<30).map {
                ChatRoom(id: "long.\($0)", name: "Channel \($0)", spaceIDs: ["preview.workspace"])
            }
        }
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let sidebar = WithState(Set<String>()) { collapsed in
            SidebarView(
                matrix: matrix, route: .constant(.home), workspaceID: .constant("preview.workspace"),
                directMessageSearch: .constant(""), unreadDirectMessagesOnly: .constant(false),
                draftRoomIDs: ["preview.room.3"], onSelect: { _ in }, onCreate: { _ in },
                onPreferences: {}, onProfile: {}, onSignOut: {}, onMarkUnread: { _ in }, onMarkRead: { _ in },
                onInviteWorkspace: { _ in }, onEditWorkspace: { _ in }, onNotifications: { _ in }, onHide: {},
                onBrowseChannels: {}, collapsed: collapsed)
        }
        let hosting = NSHostingView(
            rootView: sidebar.padding(8).frame(width: 280, height: 760).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 280, height: 760))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        let name = "sidebar-\(long ? "long-" : "")\(theme.rawValue)"
        try write(await settledImage(hosting), name)
        guard long else { return }
        let list = try #require(Self.views(in: hosting).compactMap { $0 as? NSScrollView }.first)
        // Past the end: the list stops scrolling where a reader's would.
        try #require(list.documentView).scroll(NSPoint(x: 0, y: 100_000))
        try write(await settledImage(hosting), "\(name)-end")
    }

    @Test("Component gallery", arguments: Theme.allCases)
    func gallery(theme: Theme) async throws {
        _ = NSApplication.shared
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: ComponentGallery().environmentObject(appearance))
        let window = offscreenWindow(hosting.fittingSize)
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "gallery-\(theme.rawValue)")
    }

    @Test("Mentions and inline code in messages and the composer", arguments: [1, 1.1, 1.25], Theme.allCases)
    func mentions(zoom: Double, theme: Theme) async throws {
        _ = NSApplication.shared
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        func message(_ sender: String, _ body: String, html: String? = nil) -> ChatMessage {
            ChatMessage(
                id: sender + body, roomID: "!room:example.org", senderID: "@\(sender.lowercased()):example.org",
                senderName: sender, body: body, formattedBody: html,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let alice = "<a href=\"https://matrix.to/#/@alice:example.org\">Alice Liddell</a>"
        let me = "<a href=\"https://matrix.to/#/@me:example.org\">Dmitry</a>"
        let view = VStack(alignment: .leading, spacing: 0) {
            MessageRow(message: message("Bob", "-", html: "Hey \(alice), can you review the deck before standup?"))
            MessageRow(message: message("Heidi", "-", html: "\(alice): the numbers are in, \(me), take a look"))
            MessageRow(
                message: message(
                    "Ivan", "-",
                    html: "Set <code>MAX_RETRIES</code> to 5, then run <code>scripts/deploy --region eu-central-1 "
                        + "--dry-run</code>, and check <code>billing.yaml</code>."))
            MessageRow(message: message("Carol", "-", html: "\(me) the build is green, @room please pull"))
            MessageRow(message: message("Dave", "Pinging @carol:example.org and @erin:example.org about it"))
            MessageRow(
                message: message(
                    "Erin", "-",
                    html: "The launch checklist is done and the release notes are written, so \(alice) takes a "
                        + "last look and the release is ready to tag once she and our release manager \(me) agree"))
            // Wraps inside the mention.
            MessageRow(
                message: message(
                    "Grace", "-",
                    html: "The launch checklist is done and the notes are written, so \(alice) can sign off"))
            MessageRow(message: message("Frank", "-", html: "🎉 \(alice) 🙌 shipped it, สวัสดี \(me)!"))
            MessageComposer(
                text: .constant("Thanks <a href=\"https://matrix.to/#/@alice:example.org\">Alice Liddell</a> for this"),
                placeholder: "Message #design", members: [], onSend: { _, _ in }, onTyping: { _ in }
            ).padding(16)
        }
        .frame(width: 560 * zoom).background(appearance.colors.canvas)
        .environment(
            \.mentions,
            MentionContext(me: "@me:example.org", members: [ChatUser(id: "@carol:example.org", name: "Carol Chen")])
        )
        .environment(\.metrics, Metrics(zoom: zoom))
        .environmentObject(appearance)
        let hosting = NSHostingView(rootView: view)
        let window = offscreenWindow(hosting.fittingSize)
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "mentions-\(Int(zoom * 100))-\(theme.rawValue)")
    }

    @Test("The @ list scrolled to its end: an invited person, then @room", arguments: Theme.allCases)
    func mentionList(theme: Theme) async throws {
        let members =
            [
                "Aisha Khan", "AI Agent", "Alex Moreau", "Amelia Hart", "Anders Berg", "Ana Lima", "Arjun Rao",
                "Ava Chen", "Aaron Price", "Abby Lee",
            ].map { ChatUser(id: "@\($0.lowercased().prefix { $0 != " " }):example.org", name: $0) }
            + [ChatUser(id: "@adam:example.org", name: "Adam Invited", membership: "invite")]
        let draft = ComposerHostedTests.Draft()
        let (window, hosting) = try themedWindow(
            MessageComposer(
                text: Binding(get: { draft.text }, set: { draft.text = $0 }), placeholder: "Message #design",
                members: members, onSend: { _, _ in },
                onTyping: { _ in }
            ).padding(16).frame(width: 560, height: 480, alignment: .bottom),
            theme: theme)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let editor = try #require(textViews(in: hosting).first { $0.isEditable })
        window.makeFirstResponder(editor)
        editor.insertText("@", replacementRange: editor.selectedRange())
        _ = try await settledImage(hosting)
        // ↑ from the first row wraps to @room, scrolling the list to its end.
        editor.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{F700}",
                    charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126)))
        try write(await settledImage(hosting), "mention-list-\(theme.rawValue)")
    }

    @Test("Formatting in the composer, the same message sent, and a quote from Element", arguments: Theme.allCases)
    func formatting(theme: Theme) async throws {
        _ = NSApplication.shared
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let html =
            "<strong>Bold</strong>, <em>italic</em>, <del>struck</del> and <code>inline code</code> for "
            + "<a href=\"https://matrix.to/#/@alice:example.org\">Alice Liddell</a>"
            + "<pre><code>let answer = 42\nprint(answer)</code></pre>"
            + "<ul><li>A bullet</li><li>Another one that is long enough to wrap onto a second line in the row</li></ul>"
            + "<ol><li>First</li><li>Second</li></ol><blockquote>A quote with a bar beside it</blockquote>After the quote"
        let sent = ComposerFormat.message(draft: html)
        func message(_ sender: String, _ body: String, html: String?) -> ChatMessage {
            ChatMessage(
                id: sender + body, roomID: "!room:example.org", senderID: "@\(sender.lowercased()):example.org",
                senderName: sender, body: body, formattedBody: html,
                timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        }
        let view = VStack(alignment: .leading, spacing: 0) {
            MessageRow(message: message("Dmitry", sent.body, html: sent.html))
            MessageRow(
                message: message(
                    "Bob", "> Ship it on Friday?\n\nYes, after the review.",
                    html: "<blockquote>\n<p>Ship it on Friday?</p>\n</blockquote>\n<p>Yes, after the review.</p>\n"))
            MessageComposer(
                text: .constant(html), placeholder: "Message #design", members: [], onSend: { _, _ in },
                onTyping: { _ in }
            ).padding(16)
        }
        .frame(width: 560).background(appearance.colors.canvas)
        .environment(\.mentions, MentionContext(me: "@me:example.org"))
        .environmentObject(appearance)
        let hosting = NSHostingView(rootView: view)
        let window = offscreenWindow(hosting.fittingSize)
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "formatting-\(theme.rawValue)")
    }

    @Test("Attachments and the media viewer", arguments: Theme.allCases)
    func attachments(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        func capture(_ view: some View, size: CGSize, _ name: String) async throws {
            let hosting = NSHostingView(
                rootView: view.environmentObject(appearance).environment(\.metrics, Metrics()))
            let window = offscreenWindow(size)
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.contentView = nil
                window.close()
            }
            try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
        }

        let names = [
            "preview.photo": "image", "preview.gif": "gif", "preview.video": "video", "preview.pdf": "pdf",
            "preview.zip": "zip",
        ]
        for message in matrix.messages {
            let row = MessageRow(
                message: message, timeLabel: "10:42 AM", avatar: AvatarView(name: message.senderName),
                attachment: message.attachment.map { AttachmentView(matrix: matrix, message: message, attachment: $0) }
            ).frame(width: 720).fixedSize().background(appearance.colors.canvas)
            let size = NSHostingView(rootView: row.environmentObject(appearance)).fittingSize
            try await capture(row, size: size, "attachment-\(try #require(names[message.id]))")
        }

        let viewer = MediaViewerState()
        viewer.open(matrix.messages[0], surface: .conversation)
        try await capture(
            ZStack {
                RootView(scratch: matrix)
                MediaViewer(matrix: matrix, viewer: viewer, onForward: { _ in })
            }, size: CGSize(width: 1440, height: 900), "viewer")
    }

    @Test("Modals and tab bars", arguments: Theme.allCases)
    func modals(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let room = try #require(matrix.selectedRoom)
        func details(_ tab: RoomInfoView.Tab) -> some View {
            RoomInfoView(
                matrix: matrix, room: room, tab: tab, onClose: {}, onInvite: {}, onRecovery: {},
                onOpenProfile: { _, _ in }, onEditDetails: {}, onNotifications: {})
        }
        let modals: [(String, AnyView)] = [
            (
                "modal-form",
                AnyView(CreationSheet(matrix: matrix, kind: .channel, onCreated: { _, _, _ in }, onClose: {}))
            ),
            (
                "modal-confirm",
                AnyView(
                    ConfirmModal(
                        title: "Leave \(room.name)?", message: "You may need an invitation to rejoin.",
                        action: "Leave", onConfirm: {}, onCancel: {}))
            ),
            ("details-about", AnyView(details(.about))),
            ("details-members", AnyView(details(.members))),
        ]
        for (name, modal) in modals {
            try await render(
                ModalHost { RootView(scratch: matrix).modal(isPresented: .constant(true)) { modal } }, theme: theme,
                name: name
            ) {
                // The sample workspace can't load members and says so in a toast, which would cover the tabs.
                matrix.errorMessage = nil
            }
        }
        try await render(RootView(scratch: matrix), theme: theme, name: "activity") {
            matrix.errorMessage = nil
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "activity"])
        }
    }

    @Test("Later's In progress tab, with a reminder to come and one overdue", arguments: Theme.allCases)
    func later(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let messages = matrix.messages.filter { !$0.body.isEmpty }.suffix(4)
        let now = Date()
        let reminders: [Date?] = [now + 2 * 3_600, now - 600, nil, nil]
        var list = SavedMessages()
        for (message, remindAt) in zip(messages, reminders) {
            list = list.setting(roomID: message.roomID, eventID: message.eventID, saved: true, at: now)
            if let remindAt {
                list = list.reminding(roomID: message.roomID, eventID: message.eventID, at: remindAt, now: now)
            }
        }
        if let done = messages.last {
            list = list.changing(roomID: done.roomID, eventID: done.eventID, to: .completed, at: now)
        }
        matrix.savedMessages.merge(list, accountID: "preview.you")
        try await render(RootView(scratch: matrix), theme: theme, name: "later") {
            matrix.errorMessage = nil
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "later"])
        }
    }

    @Test("The DMs page", arguments: Theme.allCases)
    func directMessages(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let now = Date()
        let samples: [(String, String?, TimeInterval, Bool, Int)] = [
            ("Julia", "Can you look at the launch notes before standup?", 4 * 60, false, 2),
            ("Alex", "Sounds good, I’ll push the fix tonight", 3 * 3_600, true, 0),
            ("Sam", "Here’s the deck from Thursday", 26 * 3_600, false, 0),
            ("Priya Raman", "Thanks!", 4 * 86_400, false, 0),
            ("Marcus Lee", nil, 0, false, 0),
        ]
        matrix.rooms.removeAll(where: \.isDirect)
        matrix.rooms += samples.enumerated().map { index, sample in
            let (name, body, age, own, unread) = sample
            return ChatRoom(
                id: "preview.dm.\(index)", name: name, isDirect: true, unreadMessages: unread,
                latest: body.map { LatestMessage(body: $0, timestamp: now - age, isOwn: own) })
        }
        try await render(RootView(scratch: matrix), theme: theme, name: "dms") {
            matrix.errorMessage = nil
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "dms"])
        }
    }

    @Test("Jump to, the search menu, search results and People", arguments: Theme.allCases)
    func search(theme: Theme) async throws {
        _ = NSApplication.shared
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func press(_ keyCode: UInt16, _ characters: String) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(
                    NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!)
            }
        }
        func search(_ text: String) async throws {
            let bar = try #require(
                views(hosting).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Search Harbor" })
            window.makeFirstResponder(bar)
            (window.firstResponder as? NSTextView)?.selectAll(nil)
            window.firstResponder?.insertText(text)
            _ = try await settledImage(hosting)
        }
        let name = theme.rawValue
        _ = try await settledImage(hosting)

        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "search"])
        try write(await settledImage(hosting), "switcher-empty-\(name)")
        window.firstResponder?.insertText("de")
        try write(await settledImage(hosting), "switcher-query-\(name)")
        press(53, "\u{1b}")
        _ = try await settledImage(hosting)

        try await search("team")
        press(36, "\r")
        try write(await settledImage(hosting), "search-messages-\(name)")
        try await search("te")
        try write(await settledImage(hosting), "search-menu-\(name)")
        try await search("a")
        press(36, "\r")
        _ = try await settledImage(hosting)
        // The People tab, last in the results' tab bar.
        let tab = CGPoint(x: 617, y: 900 - 116)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(
                NSEvent.mouseEvent(
                    with: type, location: tab, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try write(await settledImage(hosting), "search-people-\(name)")

        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "people"])
        _ = try await settledImage(hosting)
        window.firstResponder?.insertText("a")
        try write(await settledImage(hosting), "people-\(name)")

        for message in matrix.messages.suffix(4) {
            matrix.savedMessages.set(roomID: message.roomID, eventID: message.eventID, saved: true)
        }
        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "later"])
        try write(await settledImage(hosting), "later-\(name)")

        NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "browse-channels"])
        try write(await settledImage(hosting), "channels-\(name)")
    }

    @Test("A busy workspace: long posts, links, a bot, an edited message with a thread", arguments: Theme.allCases)
    func realLife(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let channels = [
            "Announcements", "Backend", "Mobile", "QA and Releases", "Customer Feedback", "Hiring", "Office Lisbon",
            "Infra Alerts", "Data and Analytics", "Docs",
        ]
        matrix.rooms += channels.enumerated().map { index, name in
            ChatRoom(
                id: "real.room.\(index)", name: name, unreadMessages: index % 3 == 0 ? 5 : 0, memberCount: 12,
                spaceIDs: ["preview.workspace"])
        }
        matrix.rooms += ["Priya Raman", "Tomás Herrera"].enumerated().map { index, name in
            ChatRoom(id: "real.dm.\(index)", name: name, isDirect: true, isEncrypted: true, memberCount: 2)
        }
        let room = try #require(matrix.selectedRoom)
        let now = Date()
        func message(
            _ id: String, _ sender: String, _ name: String, _ body: String, html: String? = nil, _ minutes: Double
        ) -> ChatMessage {
            ChatMessage(
                id: id, roomID: room.id, senderID: sender, senderName: name, body: body, formattedBody: html,
                timestamp: now.addingTimeInterval(-minutes * 60))
        }
        var edited = message(
            "real.4", "preview.julia", "Julia",
            "Moved the retro to Thursday 15:00 so Lisbon can join. Agenda is in the doc, add anything you want covered.",
            40)
        edited.isEdited = true
        edited.replyCount = 6
        edited.lastReply = ThreadReply(
            senderID: "preview.sam", senderName: "Sam", avatarURL: nil, timestamp: now.addingTimeInterval(-600))
        matrix.messages = [
            message(
                "real.1", "preview.alex", "Alex",
                """
                Quick summary of where the billing migration stands.

                Invoices for March are generated on the new pipeline and match the old totals to the cent. The two \
                accounts that drifted last week had a rounding rule nobody had written down; it's in the runbook now.

                What's left: the tax export, the dunning emails and switching the dashboard to read from the new \
                tables. I'd like to finish all three before the end of the month, so shout if you see something odd.
                """, 180),
            message(
                "real.2", "preview.sam", "Sam",
                "Draft of the release notes is at https://docs.harbor.example/releases/4.2 and the checklist lives at "
                    + "https://harbor.example/wiki/release-checklist. Send copy fixes to support@harbor.example.",
                html: "Draft of the release notes is at <a href=\"https://docs.harbor.example/releases/4.2\">"
                    + "https://docs.harbor.example/releases/4.2</a> and the checklist lives at "
                    + "<a href=\"https://harbor.example/wiki/release-checklist\">the wiki</a>. Send copy fixes to "
                    + "<a href=\"mailto:support@harbor.example\">support@harbor.example</a>.",
                95),
            message(
                "real.3", "preview.deploybot", "Deploy Bot",
                "harbor-web 4.2.0-rc.3 deployed to staging by Sam. 148 tests passed, 0 failed. Rollout 100%.", 60),
            edited,
            message("real.5", "preview.you", "You", "Thanks! I'll bring the numbers from the last two sprints.", 12),
        ]
        try await render(
            RootView(scratch: matrix).environment(\.metrics, Metrics()), theme: theme, name: "real-life")
    }

    @Test(
        "A direct conversation of short messages and one long one, with one row hovered",
        arguments: Theme.allCases)
    func shortMessages(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        matrix.user = ChatUser(id: "preview.you", name: "Dmitry Ukhanov")
        let channels = [
            "Design", "Marketing and Growth", "Planning and Demos", "Platform and Tools", "Releases", "Support",
            "Welcome",
        ]
        let starred = ["Agents", "Team", "Infra PR Reviews"]
        matrix.rooms =
            starred.map { ChatRoom(id: "short.\($0)", name: $0, favorite: true, spaceIDs: ["preview.workspace"]) }
            + channels.map { ChatRoom(id: "short.\($0)", name: $0, spaceIDs: ["preview.workspace"]) }
            + ["deploy agent", "Анна Белова", "Игорь Соколов"].map {
                ChatRoom(id: "short.\($0)", name: $0, isDirect: true, memberCount: 2)
            }
        let room = "short.Анна Белова"
        matrix.selectedRoomID = room
        let you = "preview.you"
        let anna = "preview.anna"
        var serial = 0
        func message(_ sender: String, days: Double, _ hour: Double, _ body: String, reaction: String? = nil)
            -> ChatMessage
        {
            serial += 1
            let day = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-days * 86_400)
            var message = ChatMessage(
                id: "short.\(serial)", roomID: room, senderID: sender,
                senderName: sender == you ? "Dmitry Ukhanov" : "Анна Белова", body: body,
                timestamp: day.addingTimeInterval(hour * 3_600))
            if let reaction {
                message.reactions = [MessageReaction(key: reaction, count: 1, mine: true, senders: [you])]
            }
            return message
        }
        matrix.messages = [
            message(anna, days: 9, 13.25, "Готово", reaction: "🙏"),
            message(anna, days: 8, 10.8, "агент сам ловит PR или нужно создать ему тред?"),
            message(anna, days: 8, 10.81, "Привет!"),
            message(
                you, days: 8, 10.85, "Привет! Сам ловит и PR, и изменения, но сейчас я его переделываю, может глючить"),
            message(
                anna, days: 8, 10.86, "поняла, там 402-й срочный, если получится его протолкнуть, будет супер",
                reaction: "👀"),
            message(
                you, days: 8, 11.07,
                "Я сейчас сделал ручной запуск плана после инцидента безопасности. План запускается в боевой среде, поэтому сначала хочу посмотреть, кто автор PR и что он делает. Как закончу проверку, напишу сюда и в канал Infra PR Reviews."
            ),
            message(anna, days: 8, 11.08, "Принято"),
            message(
                you, days: 1, 10.05, "Привет! А встреча по бюджету когда? Помню, ты говорила, но в календаре не вижу"),
            message(anna, days: 1, 10.33, "в четверг в 15:00, сейчас пришлю приглашение"),
            message(you, days: 0, 9.2, "спасибо!"),
        ]
        try await render(
            RootView(scratch: matrix).environment(\.metrics, Metrics()), theme: theme, name: "short-messages",
            size: NSSize(width: 1_280, height: 800), hovering: "Привет!")
    }

    @Test("Hard cases: real names, replies, mentions, rich text, reactions and a thread", arguments: Theme.allCases)
    func hardCases(theme: Theme) async throws {
        try await hardWindow(theme: theme, zoom: 1.1) { matrix, window, hosting in
            let screens = Self.hardScreens(room: try #require(matrix.selectedRoomID))
            for (index, screen) in screens.enumerated() {
                matrix.messages = screen.messages
                try await hardCapture(matrix, hosting, "hard-\(screen.name)-110-\(theme.rawValue)")
                guard index == 0 else { continue }
                let scroll = try #require(Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first)
                let text = try #require(
                    Self.views(in: hosting).compactMap { $0 as? MessageTextView }.first {
                        $0.string.hasPrefix("I’ll take the postmortem")
                    })
                let frame = text.convert(text.bounds, to: nil)
                scroll.onPointer?(NSPoint(x: frame.midX, y: frame.midY))
                try write(await settledImage(hosting), "hard-\(screen.name)-hover-110-\(theme.rawValue)")
                scroll.onPointer?(nil)
            }
            try await hardThread(matrix, window, hosting, widths: [1438, 1100, 800], zoom: 1.1, theme: theme)
        }
    }

    @Test("Hard cases at 100% and 150%: the names screen and the thread", arguments: [1, 1.5])
    func hardCasesZoomed(zoom: Double) async throws {
        try await hardWindow(theme: .dark, zoom: zoom) { matrix, window, hosting in
            let screen = Self.hardScreens(room: try #require(matrix.selectedRoomID))[0]
            matrix.messages = screen.messages
            try await hardCapture(matrix, hosting, "hard-\(screen.name)-\(Int(zoom * 100))-dark")
            try await hardThread(matrix, window, hosting, widths: [1438], zoom: zoom, theme: .dark)
        }
    }

    private static let hardMe = "@ilya:harbor.example"
    /// Invented people on harbor.example, whose names exercise initials and truncation.
    private static let hardPeople = [
        hardMe: "Илья Громов", "@nikita.claude:harbor.example": "Никита · Claude",
        "@kostya-belyaev:harbor.example": "kostya-belyaev",
        "@evgenia:harbor.example": "Евгения Красносельская-Тихомирова",
        "@max:harbor.example": "Maximilian Hohenzollern-Sigmaringen", "@q:harbor.example": "Q",
        "@lena:harbor.example": "🦊 Лена Морозова", "@tom:harbor.example": "Tom Reyes",
        "@olga:harbor.example": "Ольга Соколова", "@anna:harbor.example": "Anna Kim",
        "@sergey:harbor.example": "Сергей Петров",
    ]

    /// The owner's settings: glass with the window gradient, comfortable density, `zoom`, a 1438 × 936 window with
    /// full-size content, on the sample workspace signed in as Илья.
    private func hardWindow(
        theme: Theme, zoom: Double, _ body: (MatrixService, NSWindow, NSView) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        matrix.user = ChatUser(id: Self.hardMe, name: Self.hardPeople[Self.hardMe]!)
        matrix.members = Self.hardPeople.map { ChatUser(id: $0.key, name: $0.value) }
        let room = try #require(matrix.selectedRoomID)
        let index = try #require(matrix.rooms.firstIndex { $0.id == room })
        matrix.rooms[index].pinnedEventIDs = ["$hard.6.pinned"]
        matrix.savedMessages.set(roomID: room, eventID: "$hard.6.saved", saved: true)
        let appearance = AppearanceStore()
        let keys = [
            "appearance.mode", "appearance.theme", "appearance.chatWallpaper", "appearance.increaseContrast",
            "appearance.workspaceThemes", "appearance.density",
        ]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        appearance.theme = .glass
        appearance.chatWallpaper = true
        appearance.increaseContrast = false
        appearance.workspaceThemes = [:]
        appearance.density = .comfortable
        let hosting = NSHostingView(
            rootView: RootView(scratch: matrix).environmentObject(appearance).environment(
                \.metrics, Metrics(zoom: zoom))
        )
        let window = offscreenWindow(
            NSSize(width: 1438, height: 936),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        try await body(matrix, window, hosting)
    }

    private func hardCapture(_ matrix: MatrixService, _ hosting: NSView, _ name: String) async throws {
        _ = try await settledImage(hosting)
        // A reply the sample workspace can't load says so in a toast, which would cover messages.
        matrix.errorMessage = nil
        try write(await settledImage(hosting), name)
    }

    /// Opens the reactions screen's long message in a thread through its context menu, fills the thread and captures
    /// it at each width.
    private func hardThread(
        _ matrix: MatrixService, _ window: NSWindow, _ hosting: NSView, widths: [CGFloat], zoom: Double, theme: Theme
    ) async throws {
        let room = try #require(matrix.selectedRoomID)
        matrix.messages = try #require(Self.hardScreens(room: room).first { $0.name == "6-reactions" }).messages
        _ = try await settledImage(hosting)
        let root = try #require(matrix.messages.first { ($0.replyCount ?? 0) > 0 })
        let text = try #require(
            Self.views(in: hosting).compactMap { $0 as? MessageTextView }.first {
                $0.string.hasPrefix(String(root.body.prefix(20)))
            })
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let item = try #require(text.menu(for: event)?.items.first { $0.identifier?.rawValue == "thread" })
        _ = item.target?.perform(item.action, with: item)
        _ = try await settledImage(hosting)
        matrix.threadMessages = [root] + Self.hardThreadReplies(root)
        for width in widths {
            window.setContentSize(NSSize(width: width, height: 936))
            try await hardCapture(matrix, hosting, "hard-thread-\(Int(width))-\(Int(zoom * 100))-\(theme.rawValue)")
        }
        window.setContentSize(NSSize(width: 1438, height: 936))
    }

    private static func hardMessage(
        _ id: String, _ sender: String, _ body: String, html: String? = nil, _ time: Date, room: String
    ) -> ChatMessage {
        ChatMessage(
            id: "$hard.\(id)", roomID: room, senderID: sender, senderName: hardPeople[sender] ?? sender, body: body,
            formattedBody: html, timestamp: time)
    }

    private static func ago(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }
    private static func daysAgo(_ days: Double, at hour: Double) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(-days * 86_400 + hour * 3_600)
    }
    private static func mention(_ id: String) -> String {
        "<a href=\"https://matrix.to/#/\(id)\">\(hardPeople[id] ?? id)</a>"
    }

    /// Each screen fits the window, oldest message first.
    private static func hardScreens(room: String) -> [(name: String, messages: [ChatMessage])] {
        func message(_ id: String, _ sender: String, _ body: String, html: String? = nil, _ time: Date)
            -> ChatMessage
        { hardMessage(id, sender, body, html: html, time, room: room) }
        let (me, nikita, kostya, evgenia, max, q, lena, tom, olga, anna, sergey) = (
            hardMe, "@nikita.claude:harbor.example", "@kostya-belyaev:harbor.example", "@evgenia:harbor.example",
            "@max:harbor.example", "@q:harbor.example", "@lena:harbor.example", "@tom:harbor.example",
            "@olga:harbor.example", "@anna:harbor.example", "@sergey:harbor.example"
        )

        let names = [
            message(
                "1.1", nikita,
                "Собрал сводку по вчерашним релизам: три сервиса обновлены, один откатили. Подробности ниже.",
                ago(95)),
            message("1.2", kostya, "откатили billing-api? что там случилось", ago(92)),
            message(
                "1.3", nikita,
                "Да, billing-api 2.14.1. После миграции падал healthcheck, откат занял четыре минуты.", ago(90)),
            message(
                "1.4", evgenia,
                "I’ll take the postmortem. Can someone send me the deploy logs from 14:00 to 14:30?", ago(70)),
            message("1.5", q, "ok", ago(64)),
            message("1.6", lena, "Логи скинула в личку 👆", ago(50)),
            message(
                "1.7", max, "Thanks all. Let’s go through it at the Thursday review, I’ll add it to the agenda.",
                ago(31)),
            message("1.8", me, "Добавил в повестку, спасибо", ago(20)),
            message("1.9", kostya, "👍", ago(12)),
        ]

        let proposal =
            "Proposal for the new onboarding: drop the workspace picker, send people straight to #welcome, and "
            + "ask for a profile photo only after their first message. Numbers from the last test are in the doc."
        var quotedLong = message("2.2", olga, "Согласна, но фото я бы вообще не просила", ago(80))
        quotedLong.replyPreview = ChatReplyPreview(
            state: .ready, eventID: "$hard.2.1", senderID: tom, senderName: hardPeople[tom]!, body: proposal)
        var quotedEmpty = message("2.3", kostya, "+1 к этому", ago(75))
        quotedEmpty.replyPreview = ChatReplyPreview(
            state: .ready, eventID: "$hard.2.1", senderID: tom, senderName: hardPeople[tom]!, body: "")
        var pending = message("2.4", anna, "Let me check the numbers first", ago(60))
        pending.replyPreview = ChatReplyPreview(state: .pending, eventID: "$hard.old.1")
        var unavailable = message("2.5", nikita, "Нашёл старое обсуждение, там то же самое решили", ago(50))
        unavailable.replyPreview = ChatReplyPreview(state: .unavailable, eventID: "$hard.old.2")
        var failed = message("2.6", me, "Это было до редизайна", ago(40))
        failed.replyPreview = ChatReplyPreview(
            state: .failed, eventID: "$hard.old.3", body: "Original message unavailable")
        var deleted = message("2.7", q, "what did it say?", ago(30))
        deleted.replyPreview = ChatReplyPreview(
            state: .ready, eventID: "$hard.old.4", senderID: sergey, senderName: hardPeople[sergey]!,
            body: "This message was deleted.", kind: "m.room.message", isRedacted: true)
        var file = message("2.8", evgenia, "В этой версии уже есть новые экраны?", ago(15))
        file.replyPreview = ChatReplyPreview(
            state: .ready, eventID: "$hard.old.5", senderID: anna, senderName: hardPeople[anna]!,
            body: "onboarding-flow-v3-final.fig", kind: "m.file")
        let replies = [message("2.1", tom, proposal, ago(90)), quotedLong, quotedEmpty, pending, unavailable]

        let url =
            "https://grafana.harbor.example/d/billing-overview/billing-api-latency?orgId=1&from=now-6h&to=now"
            + "&var-cluster=eu-central-1&var-service=billing-api&viewPanel=42"
        let mail = "release-team@harbor.example"
        let mentions = [
            message(
                "3.1", tom, "Ольга Соколова: можешь глянуть PR до обеда?",
                html: "\(mention(olga)): можешь глянуть PR до обеда?", ago(100)),
            message(
                "3.2", anna,
                "Ревьюеры на эту неделю: Сергей Петров, kostya-belyaev, Евгения Красносельская-Тихомирова и "
                    + "Никита · Claude",
                html: "Ревьюеры на эту неделю: \(mention(sergey)), \(mention(kostya)), \(mention(evgenia)) и "
                    + "\(mention(nikita))", ago(90)),
            message(
                "3.3", sergey, "Илья Громов, посмотри, пожалуйста, алерты",
                html: "\(mention(me)), посмотри, пожалуйста, алерты", ago(80)),
            message(
                "3.4", olga, "@room релиз в 18:00, после 17:30 в main не мержим",
                html: "@room релиз в 18:00, после 17:30 в main не мержим", ago(70)),
            message("3.5", nikita, "Латентность выросла после 14:00: \(url)", ago(60)),
            message(
                "3.6", evgenia, "Release notes go to \(mail) by Friday.",
                html: "Release notes go to <a href=\"mailto:\(mail)\">\(mail)</a> by Friday.", ago(50)),
            message("3.7", kostya, "а вопросы тоже на \(mail) писать?", ago(40)),
            message(
                "3.8", lena, "Важно: дежурства на декабрь обновлены, проверьте свои даты",
                html: "<strong>Важно: <a href=\"https://wiki.harbor.example/oncall/december\">дежурства на декабрь"
                    + "</a> обновлены</strong>, проверьте свои даты", ago(25)),
        ]

        let longLine =
            "kubectl -n billing rollout restart deployment/billing-api && kubectl -n billing rollout status "
            + "deployment/billing-api --timeout=300s --watch=true | tee /tmp/rollout-billing-api-2026-11-18.log"
        let rich = [
            message(
                "4.1", sergey, "Поменяй MAX_RETRIES на 5 в config/billing.yaml",
                html: "Поменяй <code>MAX_RETRIES</code> на 5 в <code>config/billing.yaml</code>", ago(120)),
            message(
                "4.2", kostya, "Restart:\n\n\(longLine)",
                html: "<p>Restart:</p><pre><code>\(longLine)</code></pre>", ago(110)),
            message(
                "4.3", anna, "Before the release:",
                html: "<p>Before the release:</p><ul><li>freeze main</li><li>run the regression suite on staging, "
                    + "including the slow payment tests that we usually skip on pull requests</li>"
                    + "<li>update the changelog</li></ul>", ago(100)),
            message(
                "4.4", olga, "Порядок выката:",
                html: "<p>Порядок выката:</p><ol><li>миграции</li><li>billing-api</li><li>веб и мобилка</li></ol>",
                ago(90)),
            message(
                "4.5", tom, "> We never deploy on Fridays.\n\nExcept this Friday, apparently.",
                html: "<blockquote><p>We never deploy on Fridays.</p></blockquote><p>Except this Friday, "
                    + "apparently.</p>", ago(80)),
            message(
                "4.6", evgenia, "Итоги квартала\n\nВсё по плану, детали в отчёте.",
                html: "<h3>Итоги квартала</h3><p>Всё по плану, детали в отчёте.</p>", ago(70)),
            message(
                "4.7", lena, "Не трогайте prod-конфиг руками, а если очень нужно — сначала в тред",
                html: "<strong>Не трогайте <em>prod-конфиг</em> руками</strong>, а <em>если очень нужно — "
                    + "<strong>сначала в тред</strong></em>", ago(60)),
            message(
                "4.8", q,
                "billing_api_invoice_reconciliation_job_timeout_exceeded_after_retrying_three_times_on_eu_central_1 "
                    + "и ещё Превысокомногорассмотрительствующий", ago(50)),
        ]

        let short = [
            message("5.1", tom, "🎉", daysAgo(1, at: 17.5)),
            message("5.2", anna, "👍🔥🚀", daysAgo(1, at: 17.6)),
            message("5.3", olga, "ок", daysAgo(1, at: 17.7)),
            message("5.4", sergey, "Смотрите", ago(10)),
            message("5.5", sergey, "деплой застрял", ago(9.7)),
            message("5.6", sergey, "на шаге миграций", ago(9.3)),
            message("5.7", sergey, "лок на таблице invoices", ago(8.8)),
            message("5.8", sergey, "кто-то держит транзакцию?", ago(8.2)),
            message("5.9", anna, "Это мой скрипт, сейчас остановлю", ago(6)),
        ]

        var one = message("6.1", tom, "Merged, thanks for the quick review", ago(110))
        one.reactions = [MessageReaction(key: "👍", count: 1, mine: false, senders: [anna])]
        var three = message("6.2", anna, "Staging is green again", ago(100))
        three.reactions = [
            MessageReaction(key: "🎉", count: 3, mine: true, senders: [me, tom, olga]),
            MessageReaction(key: "👀", count: 1, mine: false, senders: [sergey]),
            MessageReaction(key: "✅", count: 2, mine: false, senders: [kostya, lena]),
        ]
        var root = message(
            "6.3", olga,
            "Предлагаю с понедельника новый процесс релизов: ветка release/* режется в среду, QA гоняет регресс в "
                + "четверг, в пятницу до обеда выкатываем. Hotfix’ы только через дежурного. Возражения пишите в "
                + "тред до конца недели, в понедельник зафиксирую в вики.", daysAgo(2, at: 16.6))
        root.isEdited = true
        root.replyCount = 8
        root.lastReply = ThreadReply(senderID: evgenia, senderName: hardPeople[evgenia]!, timestamp: ago(15))
        root.reactions = [
            MessageReaction(key: "👍", count: 5, mine: true, senders: [me, tom, anna, sergey, kostya]),
            MessageReaction(key: "🙏", count: 1, mine: false, senders: [lena]),
        ]
        var many = message("6.4", sergey, "Новый дашборд по латентности готов", ago(90))
        many.reactions = ["🔥", "🚀", "👏", "😍", "💯", "🙌", "👀", "✨", "🎯", "📈", "🤯", "❤️", "🥳", "☕️"]
            .enumerated().map { index, key in
                MessageReaction(key: key, count: index % 3 + (index % 4 == 0 ? 4 : 1), mine: index % 4 == 0)
            }
        let pinned = message("6.pinned", tom, "On-call rotation for December is in the wiki, check your dates", ago(60))
        let saved = message(
            "6.saved", nikita, "Чек-лист релиза: https://wiki.harbor.example/releases/checklist", ago(40))
        let reactions = [
            root, one, three, many, pinned, saved, message("6.7", me, "Посмотрю дашборд после созвона", ago(20)),
        ]

        var pdf = message("7.1", anna, "Отчёт за третий квартал", ago(100))
        pdf.kind = "m.file"
        pdf.mediaCaption = "Отчёт за третий квартал, посмотрите раздел про отток до пятницы"
        pdf.body = pdf.mediaCaption!
        pdf.attachment = MessageAttachment(
            name: "Квартальный отчёт Q3.pdf", url: "preview://guidelines.pdf", mimeType: "application/pdf",
            size: 2_400_000)
        let zipName = "harbor-web-release-4.2.0-rc.3-macos-universal-signed-notarized-with-debug-symbols-2026-11-18.zip"
        var zip = message("7.2", tom, zipName, ago(90))
        zip.kind = "m.file"
        zip.attachment = MessageAttachment(
            name: zipName, url: "preview://icons.zip", mimeType: "application/zip", size: 184_300_000)
        var gone = message("7.3", sergey, "", ago(80))
        gone.isRedacted = true
        var sending = message("7.5", me, "Сейчас выложу новую сборку", Date().addingTimeInterval(-30))
        sending.sendState = "sending"
        let files = [
            pdf, zip, gone, message("7.4", olga, "Кто-нибудь видел новые макеты?", ago(30)), sending,
        ]

        let own = [
            message("8.1", anna, "Илья, как там с ревью платёжного модуля?", ago(40)),
            message("8.2", me, "Смотрю", ago(38)),
            message(
                "8.3", me,
                "Пока два замечания: в ретраях нет джиттера, и при таймауте мы не откатываем резерв. Первое мелочь, "
                    + "второе может дать двойное списание, если провайдер ответит после таймаута. Предлагаю добавить "
                    + "идемпотентный ключ и проверку статуса перед повтором. Остальное выглядит хорошо.", ago(37)),
            message("8.4", me, "Через час закончу", ago(36)),
            message("8.5", tom, "Thanks, ping me when it’s merged", ago(30)),
            message("8.6", olga, "И мне, хочу посмотреть на ключ", ago(25)),
        ]

        return [
            ("1-names", names), ("2-replies", replies), ("2b-replies", [failed, deleted, file]),
            ("3-mentions", mentions), ("4-rich-text", rich), ("5-short-emoji", short), ("6-reactions", reactions),
            ("7-files-states", files), ("8-own", own),
        ]
    }

    private static func hardThreadReplies(_ root: ChatMessage) -> [ChatMessage] {
        func reply(_ id: String, _ sender: String, _ body: String, _ time: Date) -> ChatMessage {
            var message = hardMessage("t.\(id)", sender, body, time, room: root.roomID)
            message.threadRootID = root.eventID
            return message
        }
        let (me, tom, anna, sergey, nikita, q, evgenia) = (
            hardMe, "@tom:harbor.example", "@anna:harbor.example", "@sergey:harbor.example",
            "@nikita.claude:harbor.example", "@q:harbor.example", "@evgenia:harbor.example"
        )
        let mobile = "Sounds reasonable. What about mobile? App Store review can take two days."
        var quoted = reply("3", anna, "Поддерживаю, вторник норм", daysAgo(1, at: 10.2))
        quoted.replyPreview = ChatReplyPreview(
            state: .ready, eventID: "$hard.t.1", senderID: tom, senderName: hardPeople[tom]!, body: mobile)
        var reacted = reply(
            "4", sergey,
            "Регресс в четверг не успеем, если ветку режем в среду вечером. Давайте в среду до 12:00.",
            daysAgo(1, at: 11))
        reacted.reactions = [
            MessageReaction(key: "👍", count: 4, mine: true, senders: [me, tom, anna, evgenia]),
            MessageReaction(key: "➕", count: 2, mine: false, senders: [q, nikita]),
        ]
        return [
            reply("1", tom, mobile, daysAgo(2, at: 17)),
            reply("2", me, "Для мобилки отдельный трек, режем во вторник", daysAgo(2, at: 17.2)),
            quoted, reacted,
            reply(
                "5", nikita,
                """
                Свёл предложения в одну схему:

                Вт: режем ветку мобилки, сразу отправляем в ревью App Store. Ср до 12:00: режем release/*, QA \
                начинает регресс. Чт: регресс и фиксы. Пт до обеда: выкат веба и бэкенда, мобилка выходит после \
                одобрения. Hotfix’ы идут через дежурного и не ждут пятницы.
                """, daysAgo(1, at: 15)),
            reply("6", q, "🔥", ago(60)),
            reply("7", me, "Зафиксировал в вики: https://wiki.harbor.example/releases/process", ago(30)),
            reply("8", evgenia, "Thanks! Closing the thread.", ago(15)),
        ]
    }

    /// The window at 100% with `view` as its content, after `prepare`, with the pointer over a message starting `hovering`.
    private func render(
        _ view: some View, theme: Theme, name: String, size: NSSize = NSSize(width: 1440, height: 900),
        hovering: String? = nil, prepare: () -> Void = {}
    ) async throws {
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: view.environmentObject(appearance))
        let window = offscreenWindow(size)
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        prepare()
        if let hovering {
            let scroll = try #require(Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first)
            let text = try #require(
                Self.views(in: hosting).compactMap { $0 as? MessageTextView }.first { $0.string.hasPrefix(hovering) })
            let frame = text.convert(text.bounds, to: nil)
            scroll.onPointer?(NSPoint(x: frame.midX, y: frame.midY))
        }
        try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
    }

    @Test("Files and the composer's attachment tray", arguments: Theme.allCases)
    func files(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        let files = try ["preview.photo", "preview.gif", "preview.pdf"].map { id in
            try #require(matrix.messages.first { $0.id == id }?.attachment.flatMap(PreviewMedia.file))
        }
        let staged = try await ComposerAttachmentImporter.stage(.files(files), existing: [])
        defer { ComposerAttachmentImporter.discard(staged) }
        let views: [(String, CGSize, AnyView)] = [
            (
                "tray", CGSize(width: 600, height: 200),
                AnyView(
                    MessageComposer(
                        text: .constant(""), placeholder: "Message #design", members: [], onSend: { _, _ in },
                        onTyping: { _ in }, queuedFiles: .constant(staged)
                    ).padding(16))
            ),
            (
                "files", CGSize(width: 900, height: 560),
                AnyView(
                    SharedFilesView(
                        matrix: matrix, service: matrix.sharedFiles, workspaceID: "preview.workspace",
                        onOpen: { _ in }, onOpenMedia: { _, _ in }))
            ),
        ]
        for (name, size, view) in views {
            let hosting = NSHostingView(
                rootView: view.frame(width: size.width).background(appearance.colors.canvas)
                    .environmentObject(appearance))
            let window = offscreenWindow(size)
            window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            defer {
                window.contentView = nil
                window.close()
            }
            try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
        }
    }

    @Test("A channel's files beside its messages", arguments: Theme.allCases)
    func filesPane(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        matrix.selectPreviewRoom(PreviewMedia.roomID)
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(scratch: matrix).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        // Pressed by what it is: a synthetic mouse-down that lands in a text field waits there for a real mouse-up.
        VoiceOver.listen()
        let pressed = accessible("Files and links", in: hosting).contains { $0.accessibilityPerformPress?() == true }
        VoiceOver.done()
        try #require(pressed)
        try write(await settledImage(hosting), "files-pane-\(theme.rawValue)")
    }

    @Test("Emoji picker, empty and searching", arguments: Theme.allCases)
    func emojiPicker(theme: Theme) async throws {
        let (window, hosting) = try themedWindow(
            PopoverSurface { EmojiPicker(recent: ["👍", "🎉", "✅", "👀", "🙌", "🔥", "🚀", "❤️", "😂", "🙏"]) { _ in } }
                .padding(24),
            theme: theme)
        defer { window.close() }
        try write(await settledImage(hosting), "emoji-picker-\(theme.rawValue)")
        let field = try #require(Self.views(in: hosting).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(field)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.insertText("heart", replacementRange: editor.selectedRange())
        try write(await settledImage(hosting), "emoji-search-\(theme.rawValue)")
    }

    @Test("A hovered message's toolbar, reactions, replies and (edited)", arguments: Theme.allCases)
    func hoveredRow(theme: Theme) async throws {
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let room = try #require(matrix.selectedRoom)
        // Signed in rather than sampled, so the toolbar offers reactions.
        matrix.isPreview = false
        matrix.configureMessageActionsForChecks(
            client: FakeClient(rooms: [FakeRoom(roomInfo(id: room.id))]), main: StartOfTimeline(), thread: nil,
            rootID: nil,
            sessionID: UUID(), selectionID: UUID(), threadID: UUID())
        matrix.messages = matrix.messages.map {
            var message = $0
            message.id = "$" + message.id
            return message
        }
        let (window, hosting) = try themedWindow(
            TimelineView(
                matrix: matrix, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                onSave: { _ in }, onForward: { _ in }
            ).environment(Popovers()).frame(width: 760, height: 720),
            theme: theme)
        defer { window.close() }
        _ = try await settledImage(hosting)
        let scroll = try #require(Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first)
        let text = try #require(
            Self.views(in: hosting).compactMap { $0 as? MessageTextView }.first { $0.string.hasPrefix("The details") })
        let frame = text.convert(text.bounds, to: nil)
        scroll.onPointer?(NSPoint(x: frame.midX, y: frame.midY))
        try write(await settledImage(hosting), "hovered-row-\(theme.rawValue)")
    }

    @Test("A thread reply also sent to the channel, under its thread's first message", arguments: Theme.allCases)
    func channelCopy(theme: Theme) async throws {
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let room = try #require(matrix.selectedRoom)
        let threads = FakeOpenRoom(room.id, cached: [])
        threads.threadRoots = ["$reply": "$root"]
        matrix.isPreview = false
        matrix.configureMessageActionsForChecks(
            client: FakeClient(rooms: [threads]), main: StartOfTimeline(), thread: nil,
            rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
        let now = Date()
        var root = ChatMessage(
            id: "$root", roomID: room.id, senderID: "preview.julia", senderName: "Julia",
            body: "Can we ship the release notes on Friday?", timestamp: now.addingTimeInterval(-600))
        root.replyCount = 2
        root.lastReply = ThreadReply(
            senderID: "preview.alex", senderName: "Alex", timestamp: now.addingTimeInterval(-60))
        var copy = ChatMessage(
            id: "$copy", roomID: room.id, senderID: "preview.alex", senderName: "Alex",
            body: "Yes, they're ready. I'll post them at noon.", timestamp: now.addingTimeInterval(-60))
        copy.replyToID = "$reply"
        copy.repliedToThread = true
        copy.replyPreview = ChatReplyPreview(
            state: .ready, eventID: "$reply", senderID: "preview.alex", senderName: "Alex", body: copy.body)
        matrix.messages = [root, copy]
        let (window, hosting) = try themedWindow(
            TimelineView(
                matrix: matrix, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                onSave: { _ in }
            ).environment(Popovers()).frame(width: 760, height: 480),
            theme: theme)
        defer { window.close() }
        try write(await settledImage(hosting), "channel-copy-\(theme.rawValue)")
    }

    @Test("A channel with no messages, at its intro", arguments: Theme.allCases)
    func emptyChannel(theme: Theme) async throws {
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        let room = try #require(matrix.selectedRoom)
        // Signed in, with older history still to load, as a channel of only joins opens.
        matrix.isPreview = false
        matrix.configureMessageActionsForChecks(
            client: FakeClient(rooms: [FakeRoom(roomInfo(id: room.id))]), main: StartOfTimeline(), thread: nil,
            rootID: nil, sessionID: UUID(), selectionID: UUID(), threadID: UUID())
        matrix.messages = []
        let (window, hosting) = try themedWindow(
            TimelineView(
                matrix: matrix, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                onSave: { _ in }
            ).environment(Popovers()).frame(width: 760, height: 480),
            theme: theme)
        defer { window.close() }
        try write(await settledImage(hosting), "empty-channel-\(theme.rawValue)")
    }

    @Test("The tooltip over a hovered reaction, short and wrapped", arguments: [1, 1.25], Theme.allCases)
    func reactionTooltip(zoom: Double, theme: Theme) async throws {
        try await reactionTooltip(zoom: zoom, theme: theme, long: false)
        try await reactionTooltip(zoom: zoom, theme: theme, long: true)
    }

    private func reactionTooltip(zoom: Double, theme: Theme, long: Bool) async throws {
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        if long {
            let names = ["preview.alex": "Alexandra Konstantinopoulou", "preview.julia": "Julia von Fürstenberg"]
            matrix.members = matrix.members.map { ChatUser(id: $0.id, name: names[$0.id] ?? $0.name) }
        }
        let room = try #require(matrix.selectedRoom)
        matrix.messages = matrix.messages.map {
            var message = $0
            if message.body.hasPrefix("The details") {
                message.reactions = [
                    MessageReaction(
                        key: "🎉", count: 3, mine: true, senders: ["preview.alex", "preview.you", "preview.julia"]),
                    MessageReaction(key: "👀", count: 1, mine: false, senders: ["preview.sam"]),
                ]
            }
            return message
        }
        let (window, hosting) = try themedWindow(
            TimelineView(
                matrix: matrix, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                onSave: { _ in }
            ).environment(Popovers()).environment(\.metrics, Metrics(zoom: zoom)).frame(width: 760, height: 720),
            theme: theme)
        defer { window.close() }
        _ = try await settledImage(hosting)
        let scroll = try #require(Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first)
        let text = try #require(
            Self.views(in: hosting).compactMap { $0 as? MessageTextView }.first { $0.string.hasPrefix("The details") })
        var cell: NSView? = text
        while let view = cell, !(view is TimelineCell) { cell = view.superview }
        let row = try #require(cell).convert(try #require(cell).bounds, to: nil)
        scroll.onPointer?(NSPoint(x: row.midX, y: row.midY))
        _ = try await settledImage(hosting)
        // The reactions are the row's last line, over its bottom padding.
        let m = Metrics(zoom: zoom)
        let chip = NSPoint(x: text.convert(text.bounds, to: nil).minX + m.sp8, y: row.minY + m.sp4 + m.sp24 / 2)
        scroll.onPointer?(chip)
        _ = await eventually { window.childWindows?.isEmpty == false }
        try write(
            await settledImage(hosting), "reaction-tooltip-\(long ? "long-" : "")\(Int(zoom * 100))-\(theme.rawValue)")
    }

    @Test("The New line over the first unread message", arguments: Theme.allCases)
    func newLine(theme: Theme) async throws {
        let appearance = AppearanceStore()
        let context = TimelineRowContext()
        context.appearance = appearance
        let message = ChatMessage(
            id: "$new", roomID: "!room:example.org", senderID: "@julia:example.org", senderName: "Julia",
            body: "Pushed the new build, give it a spin", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        let (window, hosting) = try themedWindow(
            VStack(spacing: 0) {
                TimelineRow(entry: TimelineEntry(id: "unread", kind: .unread), hovered: false, context: context)
                MessageRow(message: message, timeLabel: "10:42 AM")
            }.frame(width: 560),
            theme: theme, appearance: appearance)
        defer { window.close() }
        try write(await settledImage(hosting), "new-line-\(theme.rawValue)")
    }

    @Test("Your messages sending, sending slowly and not delivered", arguments: Theme.allCases)
    func sendStates(theme: Theme) async throws {
        func message(_ body: String, sentAgo: TimeInterval, state: String = "sending") -> ChatMessage {
            var message = ChatMessage(
                id: body, roomID: "!room:example.org", senderID: "@me:example.org", senderName: "Dmitry", body: body,
                timestamp: Date().addingTimeInterval(-sentAgo))
            message.sendState = state
            return message
        }
        let network = MessageSendFailure(kind: .recoverable, message: "Couldn’t send. Retry to resume.")
        let verify = MessageSendFailure(kind: .verification, message: "Verify the device or person, then retry.")
        let (window, hosting) = try themedWindow(
            VStack(spacing: 0) {
                MessageRow(message: message("Heading out now", sentAgo: 10), own: true, timeLabel: "10:42 AM")
                MessageRow(message: message("On my way", sentAgo: 0), grouped: true, own: true)
                MessageRow(message: message("Grabbing coffee first", sentAgo: 10), grouped: true, own: true)
                MessageRow(
                    message: message("Running late", sentAgo: 10, state: "failed"), grouped: true, own: true,
                    sendFailure: network)
                MessageRow(
                    message: message("See you there", sentAgo: 10, state: "failed"), grouped: true, own: true,
                    sendFailure: verify)
            }.frame(width: 560),
            theme: theme)
        defer { window.close() }
        try write(await settledImage(hosting), "send-states-\(theme.rawValue)")
    }

    @Test(
        "Profiles: someone with a photo and status, someone in a call without one, you, and editing yours",
        arguments: Theme.allCases)
    func profiles(theme: Theme) async throws {
        let matrix = MatrixService.scratch()
        matrix.enterPreview()
        // Signed in rather than sampled, so the photo draws from the cache.
        matrix.isPreview = false
        matrix.user = ChatUser(id: "@dmitry:harbor.example", name: "Dmitry")
        let photo = "mxc://harbor.example/julia"
        _ = await matrix.avatarImages.image(for: photo + "#large", pixels: 512) { try Self.samplePhoto() }
        let people = PeopleService()
        people.attach(ProfileClient(photo: photo))
        for (id, name) in [
            ("@julia:harbor.example", "julia"), ("@sam:harbor.example", "sam"), ("@dmitry:harbor.example", "you"),
        ] {
            let (window, hosting) = try themedWindow(
                ProfilePane(
                    matrix: matrix, people: people, userID: id, onOpenConversation: { _ in }, onEditProfile: {},
                    onClose: {}
                ).frame(width: 380, height: 720),
                theme: theme)
            defer { window.close() }
            try write(await settledImage(hosting), "profile-pane-\(name)-\(theme.rawValue)")
        }
        matrix.user?.avatarURL = photo
        let (window, hosting) = try themedWindow(
            ModalHost {
                Color.clear.frame(width: 900, height: 560).modal(isPresented: .constant(true)) {
                    ProfileEditor(matrix: matrix, onClose: {})
                }
            }, theme: theme)
        defer { window.close() }
        try write(await settledImage(hosting), "profile-editor-\(theme.rawValue)")

        let source = try #require(CGImageSourceCreateWithData(try Self.samplePhoto() as CFData, nil))
        let landscape = try #require(
            CGImageSourceCreateImageAtIndex(source, 0, nil)?.cropping(to: CGRect(x: 0, y: 96, width: 512, height: 320)))
        let (cropWindow, cropHosting) = try themedWindow(
            ModalHost {
                Color.clear.frame(width: 900, height: 640).modal(isPresented: .constant(true)) {
                    PhotoCropper(image: landscape, onCancel: {}, onSave: { _ in })
                }
            }, theme: theme)
        defer { cropWindow.close() }
        try write(await settledImage(cropHosting), "profile-crop-\(theme.rawValue)")
    }

    /// A soft gradient standing in for someone's photo.
    private static func samplePhoto() throws -> Data {
        let side = 512
        let context = try #require(
            CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let colors = [
            CGColor(red: 0.95, green: 0.62, blue: 0.45, alpha: 1), CGColor(red: 0.36, green: 0.3, blue: 0.62, alpha: 1),
        ]
        let gradient = try #require(
            CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        context.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.8, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: 176, y: 220, width: 160, height: 160))
        context.fillEllipse(in: CGRect(x: 96, y: -120, width: 320, height: 300))
        let image = try #require(context.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    /// `view` on the canvas in an offscreen window that the window server composites.
    private func themedWindow(_ view: some View, theme: Theme, appearance: AppearanceStore = AppearanceStore())
        throws -> (NSWindow, NSView)
    {
        _ = NSApplication.shared
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        UserDefaults.standard.set(savedMode, forKey: "appearance.mode")
        let hosting = NSHostingView(
            rootView: view.background(appearance.colors.canvas).environmentObject(appearance)
                .environment(\.colorScheme, theme == .dark ? .dark : .light))
        let window = offscreenWindow(hosting.fittingSize)
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        return (window, hosting)
    }

    private static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    /// Captures until the frame stops changing for 300 ms, so async text, symbols and layout have arrived.
    ///
    /// The window server's composite, not `cacheDisplay`: that draws through `CALayer.render(in:)`, which skips layer
    /// filters, and SwiftUI tints some symbols (the composer's emoji, list and code icons) with a `multiplyColor`
    /// filter over a white glyph, so they vanished on light backgrounds.
    private func settledImage(_ view: NSView) async throws -> Data {
        let window = try #require(view.window)
        var previous = Data()
        var unchanged = 0
        for _ in 0..<400 {
            view.layoutSubtreeIfNeeded()
            let png = Self.image(window)
            unchanged = png == previous ? unchanged + 1 : 0
            if unchanged == 6 && !png.isEmpty { return png }
            previous = png
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Rendering never settled")
        return previous
    }

    /// The window, with its child windows such as a tooltip over it, as the window server composites them now;
    /// empty until it has the window's first frame.
    private static func image(_ window: NSWindow) -> Data {
        // Front to back. Options: ignore framing (1) and best resolution (8).
        var ids = ((window.childWindows ?? []) + [window]).map { UnsafeRawPointer(bitPattern: $0.windowNumber) }
        let list = ids.withUnsafeMutableBufferPointer { CFArrayCreate(nil, $0.baseAddress, $0.count, nil) }
        let image = list.flatMap { windowsImage(.null, $0, 1 | 8)?.takeRetainedValue() }
        return image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) } ?? Data()
    }

    /// `CGWindowListCreateImageFromArray`, unavailable in the SDK but still in the OS; reading the process's own
    /// windows needs no screen recording permission, which ScreenCaptureKit would.
    private static let windowsImage = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImageFromArray"),
        to: (@convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?).self)

    private func write(_ png: Data, _ name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }
}
