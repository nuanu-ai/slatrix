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

    @Test(
        "What lies over the conversation and what lies over its thread",
        arguments: [
            (Coverage(), false, false),
            (Coverage(pane: true), true, false),
            (Coverage(viewer: true), true, true),
            (Coverage(dialog: true), true, true),
            (Coverage(drawer: true), true, true),
            (Coverage(identity: true), true, true),
            // A profile takes the thread's place beside the conversation.
            (Coverage(profile: true), false, true),
        ])
    func covers(coverage: Coverage, conversation: Bool, thread: Bool) {
        #expect(coverage.conversation == conversation && coverage.thread == thread)
    }
}
