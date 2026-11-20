import Testing

@testable import Slatrix

struct CoverageTests {
    @Test(
        "Escape closes what lies over the conversation, nearest first, and marks it read only with nothing over it",
        arguments: [
            (Coverage(), false, true, Coverage.Escape.markRead),
            (Coverage(), false, false, .nothing),
            (Coverage(pane: true, drawer: true), true, true, .closeDrawer),
            (Coverage(), true, true, .closePane),
            (Coverage(), true, false, .closePane),
            (Coverage(pane: true), false, true, .closePane),
            // Each closes itself before Escape reaches the conversation.
            (Coverage(viewer: true), false, true, .nothing),
            (Coverage(dialog: true), false, true, .nothing),
            // "Confirm it's you" answers to its own buttons.
            (Coverage(identity: true), false, true, .nothing),
        ])
    func escape(coverage: Coverage, profile: Bool, inConversation: Bool, expected: Coverage.Escape) {
        #expect(coverage.escape(profile: profile, inConversation: inConversation) == expected)
    }

    @Test("The identity prompt lies over the conversation and its thread")
    func identityPromptCovers() {
        let coverage = Coverage(identity: true)
        #expect(coverage.conversation && coverage.thread)
    }
}
