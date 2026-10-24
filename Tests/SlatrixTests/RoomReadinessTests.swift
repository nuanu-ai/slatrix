import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class Powers: RoomPowerLevels, @unchecked Sendable {}

/// A freshly created room whose state the test syncs piece by piece.
private final class SyncingRoom: Room, @unchecked Sendable {
    let seedGate = Gate()
    let memberGate = Gate()
    let handle = FakeCancellableHandle(noHandle: .init())
    let seedReads = Recorder<Void>()
    let memberReads = Recorder<Void>()
    var joined = true
    var creators = false
    var powers = false
    var members = false
    var listener: RoomInfoListener?

    func syncEverything() {
        creators = true
        powers = true
        members = true
    }
    override func id() -> String { "!created:example.org" }
    override func membership() -> Membership { joined ? .joined : .left }
    override func subscribeToRoomInfoUpdates(listener: RoomInfoListener) -> TaskHandle {
        self.listener = listener
        return handle
    }
    override func roomInfo() async throws -> RoomInfo {
        seedReads.append(())
        let value = info()
        await seedGate.wait()
        return value
    }
    override func activeHumanMemberIdsNoSync() async throws -> [String] {
        memberReads.append(())
        await memberGate.wait()
        return members ? ["@owner:example.org"] : []
    }
    func emit() { listener?.call(roomInfo: info()) }
    private func info() -> RoomInfo {
        var info = SlatrixTests.roomInfo(id: id(), membership: joined ? .joined : .left)
        info.creators = creators ? ["@owner:example.org"] : nil
        info.powerLevels = powers ? Powers(noHandle: .init()) : nil
        return info
    }
}

@MainActor private final class Session { var isCurrent = true }

@MainActor
struct RoomReadinessTests {
    private let room = SyncingRoom(noHandle: .init())

    private func wait(timeout: Duration = .seconds(15), validate: @escaping @MainActor () throws -> Void = {})
        -> Task<Void, Error>
    {
        Task {
            try await RoomReadiness.waitUntilReady(
                room: room, ownUserID: "@owner:example.org", timeout: timeout, validate: validate)
        }
    }

    @Test("A created room becomes ready only once its own member has synced, then stops listening")
    func readyAfterOwnMember() async throws {
        room.creators = true
        room.powers = true
        let pending = wait()
        #expect(await eventually { !room.memberReads.all.isEmpty })
        #expect(!room.handle.isCancelled)
        room.members = true
        room.emit()
        try await pending.value
        #expect(room.handle.isCancelled)
    }

    @Test(
        "A room missing its creators or power levels is not ready yet",
        arguments: [(false, true), (true, false)])
    func partialStateTimesOut(creators: Bool, powers: Bool) async {
        room.syncEverything()
        room.creators = creators
        room.powers = powers
        await #expect(throws: RoomReadinessError.timedOut) { try await wait(timeout: .milliseconds(50)).value }
    }

    @Test("State that synced before the wait started is picked up without another update")
    func alreadyReady() async throws {
        room.syncEverything()
        try await wait().value
        #expect(room.handle.isCancelled)
    }

    @Test("A room update completes the wait even while the initial read hangs")
    func updateBeatsSlowSeed() async throws {
        room.seedGate.arm()
        let pending = wait()
        #expect(await eventually { room.seedGate.isWaiting })
        room.syncEverything()
        room.emit()
        try await pending.value
        #expect(room.seedGate.isWaiting)
        room.seedGate.release()
    }

    @Test("The deadline fails the wait and stops listening while the initial read hangs")
    func deadline() async {
        room.seedGate.arm()
        await #expect(throws: RoomReadinessError.timedOut) { try await wait(timeout: .milliseconds(10)).value }
        #expect(room.handle.isCancelled && room.seedGate.isWaiting)
        room.seedGate.release()
    }

    @Test("Cancelling the wait does not wait for a hanging member lookup")
    func cancelDuringMemberLookup() async {
        room.syncEverything()
        room.memberGate.arm()
        let pending = wait()
        #expect(await eventually { room.memberGate.isWaiting })
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(room.handle.isCancelled && room.memberGate.isWaiting)
        room.memberGate.release()
    }

    @Test("A wait cancelled before it starts neither subscribes nor reads the room")
    func cancelledBeforeStart() async {
        let pending = wait()
        pending.cancel()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(room.listener == nil && room.seedReads.all.isEmpty)
    }

    @Test("An update arriving after the session changed is rejected and stops listening")
    func staleSession() async {
        let session = Session()
        let pending = wait { if !session.isCurrent { throw CancellationError() } }
        #expect(await eventually { !room.seedReads.all.isEmpty })
        session.isCurrent = false
        room.syncEverything()
        room.emit()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(room.handle.isCancelled)
    }

    @Test("Leaving the room while waiting fails with no longer joined")
    func leftWhileWaiting() async {
        let pending = wait()
        #expect(await eventually { !room.seedReads.all.isEmpty })
        room.joined = false
        room.emit()
        await #expect(throws: RoomReadinessError.noLongerJoined) { try await pending.value }
    }
}
