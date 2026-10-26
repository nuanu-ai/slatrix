import Foundation
import Testing

@testable import Slatrix

@MainActor
private final class FakeIndexing {
    var finished = false
    var cancellations = 0
    var handle: SearchIndexingController.Handle {
        .init(cancel: { self.cancellations += 1 }, isFinished: { self.finished })
    }
}

/// Stands in for the polling delay; `resumed` counts waits that have returned to the controller.
@MainActor
private final class PollClock {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var resumed = 0
    var waiting: Int { waiters.count }
    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
        resumed += 1
    }
    func tick() {
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
struct SearchIndexingControllerTests {
    private let clock = PollClock()
    private let controller: SearchIndexingController
    init() { controller = SearchIndexingController(wait: { [clock] in await clock.wait() }) }

    private func start(_ indexing: FakeIndexing, into states: Recorder<SearchIndexingState>) {
        controller.start(makeHandle: { indexing.handle }, onUpdate: { states.append($0) })
    }

    @Test("Starting publishes running, and a second start while busy creates no second operation")
    func startOnce() async {
        let states = Recorder<SearchIndexingState>()
        let first = FakeIndexing()
        start(first, into: states)
        #expect(await eventually { clock.waiting == 1 })
        var madeAnother = false
        controller.start(
            makeHandle: {
                madeAnother = true
                return FakeIndexing().handle
            }, onUpdate: { _ in })
        #expect(controller.state == .running && states.all == [.running])
        #expect(!madeAnother)
    }

    @Test("Stop stays busy until the SDK confirms, then reports stopped; a new sweep cannot start meanwhile")
    func stopWaitsForSDK() async {
        let states = Recorder<SearchIndexingState>()
        let sweep = FakeIndexing()
        start(sweep, into: states)
        #expect(await eventually { clock.waiting == 1 })
        controller.cancel()
        controller.cancel()
        #expect(sweep.cancellations == 1 && controller.state == .stopping && controller.state.isBusy)
        var madeAnother = false
        controller.start(
            makeHandle: {
                madeAnother = true
                return FakeIndexing().handle
            }, onUpdate: { _ in })
        #expect(!madeAnother)
        clock.tick()
        #expect(await eventually { clock.resumed == 1 && clock.waiting == 1 })
        #expect(controller.state == .stopping)
        sweep.finished = true
        clock.tick()
        #expect(await eventually { controller.state == .stopped })
        #expect(states.all == [.running, .stopping, .stopped] && !controller.state.isBusy)
    }

    @Test("A sweep that finishes on its own reports completed, not stopped")
    func naturalCompletion() async {
        let states = Recorder<SearchIndexingState>()
        let sweep = FakeIndexing()
        start(sweep, into: states)
        #expect(await eventually { clock.waiting == 1 })
        sweep.finished = true
        clock.tick()
        #expect(await eventually { controller.state == .completed })
        #expect(states.all == [.running, .completed])
    }

    @Test("A sweep that is already finished still reports completed, and a later stop leaves it alone")
    func alreadyFinished() async {
        let states = Recorder<SearchIndexingState>()
        let sweep = FakeIndexing()
        sweep.finished = true
        start(sweep, into: states)
        #expect(await eventually { controller.state == .completed })
        #expect(states.all == [.running, .completed])
        controller.cancel()
        #expect(sweep.cancellations == 0)
    }

    @Test("Signing out cancels the sweep, and its late completion never reaches the next account's sweep")
    func resetIsolatesSessions() async {
        let oldStates = Recorder<SearchIndexingState>()
        let newStates = Recorder<SearchIndexingState>()
        let old = FakeIndexing()
        let new = FakeIndexing()
        start(old, into: oldStates)
        #expect(await eventually { clock.waiting == 1 })
        controller.reset()
        #expect(old.cancellations == 1 && controller.state == .idle)
        start(new, into: newStates)
        #expect(await eventually { clock.waiting == 2 })
        old.finished = true
        clock.tick()
        #expect(await eventually { clock.resumed == 2 && clock.waiting == 1 })
        #expect(oldStates.all == [.running] && newStates.all == [.running] && controller.state == .running)
        new.finished = true
        clock.tick()
        #expect(await eventually { controller.state == .completed })
        #expect(newStates.all == [.running, .completed])
    }

    @Test("Signing out while a stop is pending suppresses the late stopped report")
    func resetWhileStopping() async {
        let states = Recorder<SearchIndexingState>()
        let sweep = FakeIndexing()
        start(sweep, into: states)
        #expect(await eventually { clock.waiting == 1 })
        controller.cancel()
        controller.reset()
        sweep.finished = true
        clock.tick()
        #expect(await eventually { clock.resumed == 1 })
        #expect(states.all == [.running, .stopping] && controller.state == .idle)
    }
}
