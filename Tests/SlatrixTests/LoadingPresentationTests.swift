import Testing

@testable import Slatrix

struct LoadingPresentationTests {
    @Test(
        "A loading indicator stays hidden through a quick load and over content, and shows only for a long wait",
        arguments: [
            (Duration.milliseconds(0), false, false), (.milliseconds(350), false, false),
            (.milliseconds(450), false, true), (.seconds(5), false, true),
            // Something on screen already tells the reader where they are.
            (.seconds(5), true, false),
        ])
    func indicatorWaits(waited: Duration, hasContent: Bool, shows: Bool) {
        #expect(LoadingPresentation.showsIndicator(waited: waited, hasContent: hasContent) == shows)
    }

    @Test("A wait on the network shows no indicator while offline, where the connection notice already says why")
    func offlineWaitIsQuiet() {
        #expect(!LoadingPresentation.showsIndicator(waited: .seconds(30), hasContent: false, offline: true))
    }
}
