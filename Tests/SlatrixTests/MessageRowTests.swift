import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// A message row measured without a window, as the timeline measures it before showing it.
@MainActor
struct MessageRowTests {
    private let m = Metrics(zoom: 1)

    private func message(_ reactions: [String]) -> ChatMessage {
        var message = ChatMessage(
            id: "$row", roomID: "!room:example.org", senderID: "@anna:example.org", senderName: "Anna",
            body: "Staging is green again", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        message.reactions = reactions.map { MessageReaction(key: $0, count: 2, mine: false) }
        return message
    }

    private func height(_ message: ChatMessage, width: CGFloat) -> CGFloat {
        NSHostingView(
            rootView: MessageRow(message: message).frame(width: width).environmentObject(AppearanceStore())
                .environment(\.metrics, m)
        ).fittingSize.height
    }

    /// The row as the timeline builds it, from the message alone.
    private func row(_ message: ChatMessage, hovered: Bool = false, context: TimelineRowContext) -> TimelineRow {
        context.matrix = context.matrix ?? MatrixService.scratch()
        context.appearance = context.appearance ?? AppearanceStore()
        let entry = TimelineEntry(
            id: message.id,
            kind: .message(
                TimelineMessageEntry(
                    message: message, grouped: false, time: "10:00 AM", saved: false, pinned: false,
                    highlighted: false, sendBusy: false)))
        return TimelineRow(entry: entry, hovered: hovered, context: context)
    }

    // capability: message.reactions.show
    @Test("Reactions that don't fit the column wrap onto more lines, and the row grows to hold them")
    func reactionsWrap() {
        let many = ["🔥", "🚀", "👏", "😍", "💯", "🙌", "👀", "✨", "🎯", "📈", "🤯", "❤️", "🥳", "☕️"]
        let one = height(message(["🔥"]), width: 360)
        #expect(height(message(many), width: 360) >= one + 2 * m.sp24)
    }

    // capability: message.reactions.show
    @Test("A pill is its emoji and count however few reacted: knowing the two people changes nothing")
    func pillShowsCount() {
        let emoji = ["🔥", "🚀", "👏", "😍", "💯", "🙌", "👀", "✨", "🎯", "📈", "🤯", "🥳"]
        func width(_ senders: [String], count: Int = 2) -> CGFloat {
            var message = message([])
            message.reactions = emoji.map { MessageReaction(key: $0, count: count, mine: false, senders: senders) }
            return NSHostingView(rootView: row(message, context: TimelineRowContext())).fittingSize.width
        }
        #expect(width(["@a:example.org", "@b:example.org"]) == width([]))
        #expect(width([], count: 22) > width([]), "The count shows")
    }

    @Test("A reaction with a very long key stays inside a narrow thread's column")
    func longReactionKey() async throws {
        let key = String(repeating: "W", count: 80)
        var message = message([])
        message.reactions = [MessageReaction(key: key, count: 2, mine: false)]
        let context = TimelineRowContext()
        context.isThread = true
        var frames: [String: CGRect] = [:]
        context.onReactionFrame = { _, key, frame in frames[key] = frame }
        let width: CGFloat = 280
        let window = offscreenWindow(NSSize(width: width, height: 400))
        defer { window.close() }
        let cell = TimelineCell(identifier: .init("cell"))
        cell.show(row(message, hovered: true, context: context), commands: nil)
        cell.frame = NSRect(x: 0, y: 0, width: width, height: ceil(cell.height(width: width)))
        window.contentView = cell
        #expect(
            await eventually {
                cell.layoutSubtreeIfNeeded()
                return frames[key] != nil
            })
        #expect(try #require(frames[key]).maxX <= width - m.conversationInset(thread: true))
    }

    @Test("A quote takes the same height while its original loads as once it has, at a fractional zoom too")
    func quoteKeepsHeight() async throws {
        let zoom = Metrics(zoom: 1.25)
        func cell(_ state: ChatReplyPreview.State) -> TimelineCell {
            var message = message([])
            message.replyToID = "$quoted"
            message.replyPreview = ChatReplyPreview(
                state: state, eventID: "$quoted", senderID: "@bo:example.org", senderName: "Bo",
                body: "The deploy is out")
            let context = TimelineRowContext()
            context.metrics = zoom
            let cell = TimelineCell(identifier: .init("cell"))
            cell.show(row(message, context: context), commands: nil)
            return cell
        }
        let window = offscreenWindow(NSSize(width: 600, height: 400))
        defer { window.close() }
        let pending = cell(.pending)
        pending.frame = NSRect(x: 0, y: 0, width: 600, height: ceil(pending.height(width: 600)))
        window.contentView = pending
        pending.layoutSubtreeIfNeeded()
        func pixels() -> NSBitmapImageRep? {
            guard let image = pending.bitmapImageRepForCachingDisplay(in: pending.bounds) else { return nil }
            pending.cacheDisplay(in: pending.bounds, to: image)
            return image
        }
        let before = try #require(pixels())
        // The bars, once the loading delay has passed: how wide a span of the row they changed.
        func bars() -> CGFloat {
            guard let after = pixels(), let old = before.bitmapData, let new = after.bitmapData else { return 0 }
            let row = after.bytesPerRow
            var (first, last) = (row, -1)
            for y in 0..<after.pixelsHigh where memcmp(old + y * row, new + y * row, row) != 0 {
                first = min(first, (0..<row).first { old[y * row + $0] != new[y * row + $0] }!)
                last = max(last, (0..<row).last { old[y * row + $0] != new[y * row + $0] }!)
            }
            let pixel = after.bitsPerPixel / 8
            return CGFloat(last / pixel - first / pixel + 1) * pending.bounds.width / CGFloat(after.pixelsWide)
        }
        #expect(await eventually { bars() >= zoom(240) }, "The bars take the column's width, as the quote's lines will")
        #expect(pending.height(width: 600) == cell(.ready).height(width: 600))
    }

    @Test("A skeleton's bars never run past the width they are offered")
    func skeletonFits() async {
        let window = offscreenWindow(NSSize(width: 400, height: 200))
        defer { window.close() }
        let host = NSHostingController(
            rootView: SkeletonLines().environment(\.metrics, m).environmentObject(AppearanceStore()))
        window.contentView = host.view
        let offered = CGSize(width: 150, height: 0)
        // It draws once the loading delay has passed.
        #expect(await eventually { host.sizeThatFits(in: offered).height > 0 })
        #expect(host.sizeThatFits(in: offered).width <= offered.width)
    }

    @Test("Wait-status transitions (sending, reconnecting, blocked, pending edit) never change a row's height")
    func waitStatusesKeepRowHeightStable() {
        let sentHeight = height(message([]), width: 400)
        var sending = message([])
        sending.sendState = "sending"
        for status: SendWaitStatus in [.sending, .waitingToReconnect, .blockedByEarlierFailure] {
            let rowHeight = NSHostingView(
                rootView: MessageRow(message: sending, own: true, sendWaitStatus: status).frame(width: 400)
                    .environmentObject(AppearanceStore()).environment(\.metrics, m)
            ).fittingSize.height
            #expect(rowHeight == sentHeight, "Row height shifted for \(status)")
        }

        let groupedSent = NSHostingView(
            rootView: MessageRow(message: message([]), grouped: true, own: true).frame(width: 400)
                .environmentObject(AppearanceStore()).environment(\.metrics, m)
        ).fittingSize.height
        let groupedBlocked = NSHostingView(
            rootView: MessageRow(message: sending, grouped: true, own: true, sendWaitStatus: .blockedByEarlierFailure)
                .frame(width: 400).environmentObject(AppearanceStore()).environment(\.metrics, m)
        ).fittingSize.height
        #expect(groupedBlocked == groupedSent)

        var editing = message([])
        editing.pendingChange = .editing
        let editingHeight = NSHostingView(
            rootView: MessageRow(message: editing, own: true, sendWaitStatus: .savingEdit).frame(width: 400)
                .environmentObject(AppearanceStore()).environment(\.metrics, m)
        ).fittingSize.height
        #expect(editingHeight == sentHeight)

        // Compact density also keeps row height invariant across wait statuses, even near a wrap boundary.
        let saved = UserDefaults.standard.object(forKey: "appearance.density")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.density") }
        let compactAppearance = AppearanceStore()
        compactAppearance.density = .compact
        let compactSent = ChatMessage(
            id: "$compact-wait", roomID: "!room:example.org", senderID: "@me:example.org", senderName: "Anna",
            body: "Checking whether a compact sending indicator ever narrows this text enough to wrap a word",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        let compactSentHeight = NSHostingView(
            rootView: MessageRow(message: compactSent, own: true, timeLabel: "10:00").frame(width: 340)
                .environmentObject(compactAppearance).environment(\.metrics, m)
        ).fittingSize.height
        var compactPending = compactSent
        compactPending.sendState = "sending"
        for status: SendWaitStatus in [.sending, .waitingToReconnect, .blockedByEarlierFailure, .savingEdit] {
            let h = NSHostingView(
                rootView: MessageRow(
                    message: compactPending, own: true, sendWaitStatus: status, timeLabel: "10:00"
                ).frame(width: 340).environmentObject(compactAppearance).environment(\.metrics, m)
            ).fittingSize.height
            #expect(
                abs(h - compactSentHeight) < 0.5,
                "Compact height shifted for \(status): \(h) vs \(compactSentHeight)")
        }
    }

    @Test("Compact density takes less vertical space than comfortable for both grouped bursts and distinct senders")
    func compactIsShorterThanComfortable() {
        let saved = UserDefaults.standard.object(forKey: "appearance.density")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.density") }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let burst = (0..<5).map { i in
            ChatMessage(
                id: "$b\(i)", roomID: "!room:example.org", senderID: "@anna:example.org", senderName: "Anna",
                body: "Follow-up message number \(i + 1)", timestamp: base.addingTimeInterval(Double(i) * 30))
        }
        let mixed = ["Anna", "Bo", "Cara", "Dan", "Eve"].enumerated().map { i, name in
            ChatMessage(
                id: "$m\(i)", roomID: "!room:example.org", senderID: "@\(name.lowercased()):example.org",
                senderName: name, body: "Short reply from \(name)",
                timestamp: base.addingTimeInterval(Double(i) * 30))
        }
        func totalHeight(_ messages: [ChatMessage], density: MessageDensity, groupedInCompact: Bool) -> CGFloat {
            let appearance = AppearanceStore()
            appearance.density = density
            let rows = TimelineLayout.rows(
                messages, unreadBoundaryEventID: nil, groups: density == .comfortable || groupedInCompact,
                now: base, calendar: .current, locale: .current)
            return rows.reduce(0) { sum, row in
                guard case .message(let msg, let grouped, let time) = row.kind else { return sum }
                let h = NSHostingView(
                    rootView: MessageRow(message: msg, grouped: grouped, timeLabel: time)
                        .frame(width: 600).environmentObject(appearance).environment(\.metrics, m)
                ).fittingSize.height
                return sum + h
            }
        }
        let burstComfortable = totalHeight(burst, density: .comfortable, groupedInCompact: false)
        let burstCompact = totalHeight(burst, density: .compact, groupedInCompact: false)
        #expect(
            burstCompact < burstComfortable,
            "Compact burst (\(burstCompact)) must be shorter than comfortable (\(burstComfortable))")

        let mixedComfortable = totalHeight(mixed, density: .comfortable, groupedInCompact: false)
        let mixedCompact = totalHeight(mixed, density: .compact, groupedInCompact: false)
        #expect(
            mixedCompact < mixedComfortable,
            "Compact mixed (\(mixedCompact)) must be shorter than comfortable (\(mixedComfortable))")
    }

    @Test("Compact mode gives attachments full row width regardless of sender name length")
    func compactAttachmentsKeepFullWidth() {
        let saved = UserDefaults.standard.object(forKey: "appearance.density")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.density") }
        let appearance = AppearanceStore()
        appearance.density = .compact
        let matrix = MatrixService.scratch()
        func rowHeight(senderName: String) -> CGFloat {
            let attachment = MessageAttachment(
                name: "chart.png", url: "mxc://example.org/chart", mimeType: "image/png", width: 800, height: 600)
            let message = ChatMessage(
                id: "$att-\(senderName)", roomID: "!room:example.org", senderID: "@a:example.org",
                senderName: senderName, body: "chart.png", timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                kind: "m.image", attachment: attachment)
            let view = AttachmentView(matrix: matrix, message: message, attachment: attachment)
            return NSHostingView(
                rootView: MessageRow(message: message, grouped: false, timeLabel: "10:00", attachment: view)
                    .frame(width: 420).environmentObject(appearance).environment(\.metrics, m)
            ).fittingSize.height
        }
        let shortName = rowHeight(senderName: "Bo")
        let longName = rowHeight(senderName: "Alexandria Bartholomew-Wellington")
        #expect(
            abs(shortName - longName) < 1,
            "Long sender name squeezed compact attachment: short=\(shortName) long=\(longName)")
    }

    @Test("Bookmarking a compact message does not narrow or rewrap its body text")
    func compactBookmarkDoesNotRewrap() {
        let saved = UserDefaults.standard.object(forKey: "appearance.density")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.density") }
        let appearance = AppearanceStore()
        appearance.density = .compact
        let message = ChatMessage(
            id: "$bm", roomID: "!room:example.org", senderID: "@a:example.org", senderName: "Anna",
            body: "Checking whether saving this compact message ever narrows its body enough to push a word down",
            timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        func height(saved: Bool) -> CGFloat {
            NSHostingView(
                rootView: MessageRow(message: message, grouped: false, isSaved: saved, timeLabel: "10:00")
                    .frame(width: 340).environmentObject(appearance).environment(\.metrics, m)
            ).fittingSize.height
        }
        let unsaved = height(saved: false)
        let bookmarked = height(saved: true)
        #expect(abs(unsaved - bookmarked) < 0.5, "Compact bookmark changed row height: \(unsaved) vs \(bookmarked)")
    }

    @Test("A grouped message immediately after an attachment gets structural breathing room above it")
    func groupedRowAfterAttachmentHasBreathingRoom() {
        let saved = UserDefaults.standard.object(forKey: "appearance.density")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.density") }
        let appearance = AppearanceStore()
        appearance.density = .comfortable
        let regularGrouped = MessageRow.topInset(m, grouped: true, compact: false, followsAttachment: false)
        let afterAttachment = MessageRow.topInset(m, grouped: true, compact: false, followsAttachment: true)
        let newSender = MessageRow.topInset(m, grouped: false, compact: false, followsAttachment: false)
        #expect(afterAttachment > regularGrouped + 4)
        #expect(afterAttachment <= newSender)

        let groupedHeight = NSHostingView(
            rootView: MessageRow(message: message([]), grouped: true, followsAttachment: false)
                .frame(width: 500).environmentObject(appearance).environment(\.metrics, m)
        ).fittingSize.height
        let afterAttachmentHeight = NSHostingView(
            rootView: MessageRow(message: message([]), grouped: true, followsAttachment: true)
                .frame(width: 500).environmentObject(appearance).environment(\.metrics, m)
        ).fittingSize.height
        #expect(afterAttachmentHeight >= groupedHeight + 6)
    }

    @Test("FileCard hugs short filenames at minWidth, caps long filenames at maxWidth, and fits narrow panes")
    func fileCardCompactWidthBounds() {
        let matrix = MatrixService.scratch()
        let appearance = AppearanceStore()
        func cardWidth(name: String, offered: CGFloat) -> CGFloat {
            let attachment = MessageAttachment(
                name: name, url: "mxc://example.org/\(name)", mimeType: "text/plain", size: 1_024)
            let msg = ChatMessage(
                id: "$file-\(name)", roomID: "!room:example.org", senderID: "@a:example.org", senderName: "Anna",
                body: name, timestamp: Date(timeIntervalSince1970: 1_800_000_000), kind: "m.file",
                attachment: attachment)
            let host = NSHostingController(
                rootView: FileCard(matrix: matrix, message: msg, attachment: attachment)
                    .environmentObject(appearance).environment(\.metrics, m))
            return host.sizeThatFits(in: CGSize(width: offered, height: 200)).width
        }
        let short = cardWidth(name: "a.txt", offered: 680)
        let long = cardWidth(
            name: "Q4-2026-Comprehensive-Architecture-Design-Specification-Final-v12.txt", offered: 680)
        let narrow = cardWidth(name: "a.txt", offered: 200)
        #expect(abs(short - FileCard.minWidth) < 1, "Short file card should hug minWidth, got \(short)")
        #expect(short < FileCard.maxWidth - 60)
        #expect(abs(long - FileCard.maxWidth) < 1, "Long file card should cap at maxWidth, got \(long)")
        #expect(narrow <= 200.5, "FileCard must clamp inside narrow panes, got \(narrow)")
    }

    @Test("ThreadRepliesBar fits its content without stretching across wide panes and keeps constant height on hover")
    func threadRepliesBarCompactAndStableHeight() {
        let appearance = AppearanceStore()
        let reply = ThreadReply(
            senderID: "@bo:example.org", senderName: "Bo", timestamp: Date(timeIntervalSince1970: 1_800_000_000))
        func size(hovering: Bool, offered: CGFloat) -> CGSize {
            let host = NSHostingController(
                rootView: ThreadRepliesBar(
                    count: 3, lastReply: reply, avatar: AvatarView(name: "Bo", size: m.avatarSmall),
                    prepare: {}, action: {}, hovering: hovering
                ).environmentObject(appearance).environment(\.metrics, m))
            return host.sizeThatFits(in: CGSize(width: offered, height: 100))
        }
        let rest = size(hovering: false, offered: 700)
        let hovered = size(hovering: true, offered: 700)
        #expect(rest.width <= ThreadRepliesBar.maxWidth + 1)
        #expect(hovered.width <= ThreadRepliesBar.maxWidth + 1)
        #expect(
            hovered.width < 260,
            "Hovered replies bar should fit tightly around View thread + chevron, got \(hovered.width)")
        #expect(abs(rest.height - hovered.height) < 0.5)
    }

    @Test("Hovered MessageRow paints full-bleed opaque rowHover so wallpaper behind it never bleeds through")
    func hoveredMessageRowIsOpaqueFullBleed() throws {
        let savedMode = UserDefaults.standard.object(forKey: "appearance.mode")
        let savedTheme = UserDefaults.standard.object(forKey: "appearance.theme")
        defer {
            UserDefaults.standard.set(savedMode, forKey: "appearance.mode")
            UserDefaults.standard.set(savedTheme, forKey: "appearance.theme")
        }
        let appearance = AppearanceStore()
        appearance.mode = .dark
        appearance.theme = .aubergine
        appearance.systemIsDark = true
        let width: CGFloat = 500
        func sample(hovered: Bool, backdrop: NSColor, x: CGFloat) throws -> NSColor {
            let hosting = NSHostingView(
                rootView: ZStack {
                    Color(nsColor: backdrop)
                    MessageRow(message: message([]), hovered: hovered)
                        .environmentObject(appearance).environment(\.metrics, m)
                }.frame(width: width))
            let height = ceil(hosting.fittingSize.height)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = offscreenWindow(NSSize(width: width, height: height))
            defer {
                window.contentView = nil
                window.close()
            }
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / hosting.bounds.width
            return try #require(rep.colorAt(x: Int(x * scale), y: Int((height / 2) * scale))?.usingColorSpace(.sRGB))
        }
        // Check far-left (x = 2 pt) and far-right (x = width - 2 pt) edges: hovered pixels must be identical over
        // red and blue backdrops (proving full-bleed coverage and 100% opacity), while unhovered lets the backdrop show.
        for x in [CGFloat(2), width - 2] {
            let overRed = try sample(hovered: true, backdrop: .systemRed, x: x)
            let overBlue = try sample(hovered: true, backdrop: .systemBlue, x: x)
            #expect(
                abs(overRed.redComponent - overBlue.redComponent) < 0.005
                    && abs(overRed.greenComponent - overBlue.greenComponent) < 0.005
                    && abs(overRed.blueComponent - overBlue.blueComponent) < 0.005,
                "Backdrop bled through hovered row at x=\(x): red=\(overRed) blue=\(overBlue)")
        }
        let restRed = try sample(hovered: false, backdrop: .systemRed, x: 2)
        let restBlue = try sample(hovered: false, backdrop: .systemBlue, x: 2)
        #expect(abs(restRed.redComponent - restBlue.redComponent) > 0.3)
    }
}
