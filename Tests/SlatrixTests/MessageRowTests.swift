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
                    message: message, grouped: false, time: "10:00 AM", saved: false, pinned: false, canPin: false,
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
}
