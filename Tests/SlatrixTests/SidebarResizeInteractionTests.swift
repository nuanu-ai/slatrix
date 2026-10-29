import Foundation
import Testing

@testable import Slatrix

struct SidebarResizeInteractionTests {
    @Test("Pointer jitter below three points neither resizes nor commits")
    func jitterDoesNotResizeOrCommit() {
        var interaction = SidebarResizeInteraction()

        let resets = interaction.begin(width: 420, x: 490, clickCount: 1)
        #expect(!resets)
        #expect(interaction.drag(x: 492) == nil)
        #expect(interaction.end(x: 492) == nil)
    }

    @Test("A double-click resets without starting a drag")
    func doubleClickOnlyResets() {
        var interaction = SidebarResizeInteraction()

        let resets = interaction.begin(width: 420, x: 490, clickCount: 2)
        #expect(resets)
        #expect(interaction.drag(x: 510) == nil)
        #expect(interaction.end(x: 510) == nil)
    }

    // capability: app.resize-panes
    @Test("A drag keeps its original anchor and commits the final width once")
    func dragAnchorsAndCommitsFinalWidth() {
        var interaction = SidebarResizeInteraction()

        let resets = interaction.begin(width: 280, x: 350, clickCount: 1)
        #expect(!resets)
        #expect(interaction.drag(x: 353) == 283)
        #expect(interaction.drag(x: 390) == 320)
        #expect(interaction.drag(x: 330) == 260)
        #expect(interaction.end(x: 325) == 255)
        #expect(interaction.end(x: 325) == nil)
    }

    @Test("Each drag captures its own width and leaves clamping to the layout")
    func eachDragCapturesCurrentWidth() {
        var interaction = SidebarResizeInteraction()

        let firstReset = interaction.begin(width: 420, x: 490, clickCount: 1)
        #expect(!firstReset)
        #expect(interaction.drag(x: 510) == 440)
        #expect(interaction.end(x: 510) == 440)

        let secondReset = interaction.begin(width: 420, x: 490, clickCount: 1)
        #expect(!secondReset)
        #expect(interaction.drag(x: 480) == 410)
        #expect(interaction.end(x: 480) == 410)
    }
}
