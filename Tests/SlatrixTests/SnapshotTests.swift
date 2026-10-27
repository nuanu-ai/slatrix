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

/// Renders the sample workspace in-process and writes PNGs to `.build/snapshots/` for a person to look at.
/// Opt in with `SLATRIX_SNAPSHOTS=1 swift test --filter Snapshots`; nothing is compared automatically.
@MainActor
@Suite(.serialized, .tags(.snapshots), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_SNAPSHOTS"] != nil))
struct Snapshots {
    enum Theme: String, CaseIterable { case light, dark }

    @Test("Channel and thread windows", arguments: [1, 1.5, 2], Theme.allCases)
    func window(zoom: Double, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark

        let hosting = NSHostingView(
            rootView: RootView(matrix: matrix).environmentObject(appearance).environment(\.metrics, Metrics(zoom: zoom))
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

    @Test("A message jumped to, in the live conversation and at an older message", arguments: Theme.allCases)
    func jump(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(matrix: matrix).environmentObject(appearance))
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

    @Test("Sidebar", arguments: SidebarPalette.allCases, Theme.allCases)
    func sidebar(palette: SidebarPalette, theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        let savedPalette = UserDefaults.standard.object(forKey: "appearance.palette")
        defer {
            UserDefaults.standard.set(savedMode, forKey: "appearance.mode")
            UserDefaults.standard.set(savedPalette, forKey: "appearance.palette")
        }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        appearance.palette = palette
        let sidebar = SidebarView(
            matrix: matrix, route: .constant(.home), workspaceID: .constant("preview.workspace"),
            search: .constant(""), draftRoomIDs: ["preview.room.3"], onSelect: { _ in }, onCreate: { _ in },
            onPreferences: {}, onProfile: {}, onSignOut: {}, onMarkUnread: { _ in }, onMarkRead: { _ in },
            onInviteWorkspace: { _ in }, onEditWorkspace: { _ in }, onNotifications: { _ in }, onBrowseChannels: {})
        let hosting = NSHostingView(
            rootView: sidebar.frame(width: 68 + 280, height: 760).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 68 + 280, height: 760))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        try write(await settledImage(hosting), "sidebar-\(palette.rawValue)-\(theme.rawValue)")

        // Collapsed sections keep the open conversation and the unread ones. The headers' places from the top:
        // Direct messages under all eight channels, then Channels under the shortcuts and Starred.
        matrix.selectPreviewRoom("preview.room.3")
        for header in [599.0, 307] {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(
                    try #require(
                        NSEvent.mouseEvent(
                            with: type, location: CGPoint(x: 68 + 80, y: 760 - header), modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
            _ = try await settledImage(hosting)
        }
        try write(await settledImage(hosting), "sidebar-collapsed-\(palette.rawValue)-\(theme.rawValue)")
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

    @Test("Mentions in messages and the composer", arguments: [1, 1.25], Theme.allCases)
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
        let matrix = MatrixService()
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
                RootView(matrix: matrix)
                MediaViewer(matrix: matrix, viewer: viewer, onForward: { _ in })
            }, size: CGSize(width: 1440, height: 900), "viewer")
    }

    @Test("Modals and tab bars", arguments: Theme.allCases)
    func modals(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
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
                ModalHost { RootView(matrix: matrix).modal(isPresented: .constant(true)) { modal } }, theme: theme,
                name: name
            ) {
                // The sample workspace can't load members and says so in a toast, which would cover the tabs.
                matrix.errorMessage = nil
            }
        }
        try await render(RootView(matrix: matrix), theme: theme, name: "activity") {
            matrix.errorMessage = nil
            NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": "activity"])
        }
    }

    @Test("Jump to, the search menu, search results and People", arguments: Theme.allCases)
    func search(theme: Theme) async throws {
        _ = NSApplication.shared
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        let matrix = MatrixService()
        matrix.enterPreview()
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: RootView(matrix: matrix).environmentObject(appearance))
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
    }

    /// The window at 1440 × 900 and 100% with `view` as its content, after `prepare`.
    private func render(
        _ view: some View, theme: Theme, name: String, prepare: () -> Void = {}
    ) async throws {
        let appearance = AppearanceStore()
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(savedMode, forKey: "appearance.mode") }
        appearance.mode = theme == .dark ? .dark : .light
        appearance.systemIsDark = theme == .dark
        let hosting = NSHostingView(rootView: view.environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 1440, height: 900))
        window.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        _ = try await settledImage(hosting)
        prepare()
        try write(await settledImage(hosting), "\(name)-\(theme.rawValue)")
    }

    @Test("Files and the composer's attachment tray", arguments: Theme.allCases)
    func files(theme: Theme) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
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
        let matrix = MatrixService()
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

    @Test("The tooltip over a hovered reaction, short and wrapped", arguments: [1, 1.25], Theme.allCases)
    func reactionTooltip(zoom: Double, theme: Theme) async throws {
        try await reactionTooltip(zoom: zoom, theme: theme, long: false)
        try await reactionTooltip(zoom: zoom, theme: theme, long: true)
    }

    private func reactionTooltip(zoom: Double, theme: Theme, long: Bool) async throws {
        let matrix = MatrixService()
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

    @Test(
        "Profiles: someone with a photo and status, someone in a call without one, and you", arguments: Theme.allCases)
    func profiles(theme: Theme) async throws {
        let matrix = MatrixService()
        matrix.enterPreview()
        // Signed in rather than sampled, so the photo draws from the cache.
        matrix.isPreview = false
        matrix.user = ChatUser(id: "@dmitry:harbor.example", name: "Dmitry")
        let photo = "mxc://harbor.example/julia"
        _ = await matrix.avatarImages.image(for: photo + "#large") { try Self.samplePhoto() }
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
