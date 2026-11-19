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
        context.matrix = context.matrix ?? MatrixService()
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
        func width(_ senders: [String]) -> CGFloat {
            var message = message([])
            message.reactions = emoji.map { MessageReaction(key: $0, count: 2, mine: false, senders: senders) }
            return NSHostingView(rootView: row(message, context: TimelineRowContext())).fittingSize.width
        }
        #expect(width(["@a:example.org", "@b:example.org"]) == width([]))
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
    func quoteKeepsHeight() async {
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
        // A skeleton started after the quote's draws after it, so once it shows, the quote's bars are in the row.
        let later = NSHostingController(
            rootView: SkeletonLines().environment(\.metrics, zoom).environmentObject(AppearanceStore()))
        pending.addSubview(later.view)
        #expect(await eventually { later.sizeThatFits(in: CGSize(width: 400, height: 0)).height > 0 })
        later.view.removeFromSuperview()
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
}
