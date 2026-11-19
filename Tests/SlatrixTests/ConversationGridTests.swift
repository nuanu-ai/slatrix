import Foundation
import Testing

@testable import Slatrix

struct ConversationGridTests {
    @Test(
        "The header, the messages and the composer share one column: centered and capped in a wide pane, inset in a narrow one",
        arguments: [
            // (pane width, thread, leading, trailing)
            (1_200.0, false, 248.0, 952.0),  // 744 of rows centered, 20 in from each end
            (600, false, 20, 580),  // narrower than the rows: the column fills the pane
            (1_200, true, 16, 1_184),  // a thread fills its pane, nearer its edges
        ] as [(CGFloat, Bool, CGFloat, CGFloat)])
    func column(width: CGFloat, thread: Bool, leading: CGFloat, trailing: CGFloat) {
        let column = ConversationGrid.column(width: width, thread: thread)
        #expect(column.leading == leading && column.trailing == trailing)
    }

    @Test("The title clears the window buttons and the sidebar's button, and keeps to the column wherever they allow")
    func titleAfterChrome() {
        #expect(ConversationGrid.column(width: 600, thread: false, chrome: 130) == (130, 580))
        #expect(ConversationGrid.column(width: 1_200, thread: false, chrome: 130) == (248, 952))
    }
}
