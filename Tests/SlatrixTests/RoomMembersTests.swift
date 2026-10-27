import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// The SDK's member iterator is synchronous. This one stalls its first chunk until the main actor answers.
private final class StallingMembers: RoomMembersIterator, @unchecked Sendable {
    private let lock = NSLock()
    private let answered = DispatchSemaphore(value: 0)
    private var stalled = false
    private var served = false
    private var mainWasBlocked = false
    var isStalled: Bool { lock.withLock { stalled } }
    var blockedMain: Bool { lock.withLock { mainWasBlocked } }
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    func answer() { answered.signal() }
    override func nextChunk(chunkSize: UInt32) -> [RoomMember]? {
        guard lock.withLock({ !served }) else { return nil }
        lock.withLock { stalled = true }
        let timedOut = answered.wait(timeout: .now() + 2) == .timedOut
        lock.withLock {
            mainWasBlocked = timedOut
            served = true
        }
        return [roomMember("@alice:example.org", name: "Alice")]
    }
}

@MainActor
struct RoomMembersTests {
    @Test("Loading a room's members never blocks the main thread")
    func membersLoadOffMain() async {
        let members = StallingMembers()
        let room = FakeRoom(roomInfo(id: "!large:example.org"))
        room.memberList = members
        let service = MatrixService()
        service.configureMessageActionsForChecks(
            client: FakeClient(rooms: [room]), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        service.selectedRoomID = room.id()
        let load = Task { await service.loadMembers() }
        if await eventually({ members.isStalled }) { members.answer() }
        await load.value
        #expect(!members.blockedMain)
        #expect(service.members.map(\.name) == ["Alice"])
    }

    @Test("Members keep whether they joined, were invited, left or were banned")
    func membership() async {
        let room = FakeOpenRoom("!team:example.org", cached: [])
        room.memberList = [
            roomMember("@al:example.org", membership: .join), roomMember("@bo:example.org", membership: .invite),
            roomMember("@cy:example.org", membership: .leave), roomMember("@di:example.org", membership: .ban),
        ]
        let service = MatrixService()
        service.configureMessageActionsForChecks(
            client: FakeClient(rooms: [room]), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        service.selectedRoomID = room.id()
        await service.loadMembers()
        #expect(service.members.map(\.membership) == ["join", "invite", "leave", "ban"])
    }
}
