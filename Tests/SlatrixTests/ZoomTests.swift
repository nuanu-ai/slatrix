import Testing

@testable import Slatrix

@MainActor
struct ZoomTests {
    @Test("Zoom in and out are inverse between the ends and stop at 80% and 200%")
    func stepsRoundTripAndClamp() {
        let steps = AppearanceStore.zoomSteps
        for step in steps.dropLast() {
            #expect(AppearanceStore.zoomedOut(AppearanceStore.zoomedIn(step)) == step)
        }
        #expect(AppearanceStore.zoomedIn(2) == 2)
        #expect(AppearanceStore.zoomedOut(0.8) == 0.8)
    }

    @Test("A stored zoom off the steps falls back to 100%", arguments: [0, -1, 1.33, 3, .nan, .infinity])
    func corruptStoredZoom(value: Double) {
        #expect(AppearanceStore.validZoom(value) == 1)
    }
}
