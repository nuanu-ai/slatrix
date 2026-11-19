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
}
