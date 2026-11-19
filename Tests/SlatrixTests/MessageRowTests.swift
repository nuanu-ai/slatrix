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

    // capability: message.reactions.show
    @Test("Reactions that don't fit the column wrap onto more lines, and the row grows to hold them")
    func reactionsWrap() {
        let many = ["🔥", "🚀", "👏", "😍", "💯", "🙌", "👀", "✨", "🎯", "📈", "🤯", "❤️", "🥳", "☕️"]
        let one = height(message(["🔥"]), width: 360)
        #expect(height(message(many), width: 360) >= one + 2 * m.sp24)
    }
}
