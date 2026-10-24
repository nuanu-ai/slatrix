import Foundation
import Testing

@testable import Slatrix

private struct WriteFailure: Error {}

@MainActor
struct ReadStateDeliveryTests {
    let delivery = ReadStateDelivery()
    let log = Recorder<String>()

    /// Completes a write in an unrelated room. The main actor runs jobs in order, so every write
    /// submitted before this has had its turn to start (or to queue) by the time it returns.
    private func settle() async throws { try await delivery.perform(roomID: "!unrelated:example.org") {} }

    private func gatedWrite(_ room: String, _ gate: Gate, name: String) -> Task<Void, Error> {
        gate.arm()
        return Task {
            try await delivery.perform(roomID: room) {
                log.append("\(name)-start")
                await gate.wait()
                log.append("\(name)-end")
            }
        }
    }

    @Test("A write waits for the room's in-flight write and lands after it")
    func sameRoomWritesAreOrdered() async throws {
        let gate = Gate()
        let read = gatedWrite("!one:example.org", gate, name: "read")
        #expect(await eventually { gate.isWaiting })
        let unread = Task { try await delivery.perform(roomID: "!one:example.org") { log.append("unread") } }
        try await settle()
        #expect(log.all == ["read-start"])
        gate.release()
        try await read.value
        try await unread.value
        #expect(log.all == ["read-start", "read-end", "unread"])
    }

    @Test("A failed write fails only its own caller and does not block the next write")
    func failureDoesNotPoison() async throws {
        let gate = Gate()
        gate.arm()
        let failing = Task {
            try await delivery.perform(roomID: "!one:example.org") {
                await gate.wait()
                throw WriteFailure()
            }
        }
        #expect(await eventually { gate.isWaiting })
        let next = Task { try await delivery.perform(roomID: "!one:example.org") { log.append("next") } }
        try await settle()
        #expect(log.all.isEmpty)
        gate.release()
        await #expect(throws: WriteFailure.self) { try await failing.value }
        try await next.value
        #expect(log.all == ["next"])
    }

    @Test("Cancelling a queued write skips it, and a later write still waits for the in-flight one")
    func cancelledQueuedWriteIsSkipped() async throws {
        let gate = Gate()
        let blocker = gatedWrite("!one:example.org", gate, name: "blocker")
        #expect(await eventually { gate.isWaiting })
        let queued = Task { try await delivery.perform(roomID: "!one:example.org") { log.append("queued") } }
        try await settle()
        queued.cancel()
        let following = Task { try await delivery.perform(roomID: "!one:example.org") { log.append("following") } }
        try await settle()
        #expect(log.all == ["blocker-start"])
        gate.release()
        try await blocker.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        try await following.value
        #expect(log.all == ["blocker-start", "blocker-end", "following"])
    }

    @Test("Cancelling a started write lets its SDK call finish before the room's next write starts")
    func cancelledStartedWriteFinishesFirst() async throws {
        let gate = Gate()
        let active = gatedWrite("!one:example.org", gate, name: "active")
        #expect(await eventually { gate.isWaiting })
        active.cancel()
        let after = Task { try await delivery.perform(roomID: "!one:example.org") { log.append("after") } }
        try await settle()
        #expect(log.all == ["active-start"] && gate.isWaiting)
        gate.release()
        await #expect(throws: CancellationError.self) { try await active.value }
        try await after.value
        #expect(log.all == ["active-start", "active-end", "after"])
    }

    @Test("Reset cancels the previous account's writes and never starts its queued ones")
    func resetDropsPreviousAccount() async throws {
        let oldGate = Gate()
        let old = gatedWrite("!same:example.org", oldGate, name: "old")
        #expect(await eventually { oldGate.isWaiting })
        let stale = Task { try await delivery.perform(roomID: "!same:example.org") { log.append("stale") } }
        try await settle()
        delivery.reset()
        let newGate = Gate()
        let current = gatedWrite("!same:example.org", newGate, name: "new")
        #expect(await eventually { newGate.isWaiting })
        oldGate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        await #expect(throws: CancellationError.self) { try await stale.value }
        newGate.release()
        try await current.value
        #expect(log.all == ["old-start", "new-start", "old-end", "new-end"])
    }

    @Test("Writes to different rooms do not wait for each other")
    func roomsAreIndependent() async throws {
        let gate = Gate()
        let slow = gatedWrite("!slow:example.org", gate, name: "slow")
        #expect(await eventually { gate.isWaiting })
        try await delivery.perform(roomID: "!other:example.org") { log.append("other") }
        #expect(log.all == ["slow-start", "other"])
        gate.release()
        try await slow.value
    }
}
