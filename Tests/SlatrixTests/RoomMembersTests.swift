import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// The SDK's member iterator is synchronous, so it must run off the main thread. This one notes where it ran.
private final class ThreadRecordingMembers: RoomMembersIterator, @unchecked Sendable {
    private let lock = NSLock()
    private var served = false
    private var onMain = false
    var ranOnMain: Bool { lock.withLock { onMain } }
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func nextChunk(chunkSize: UInt32) -> [RoomMember]? {
        lock.withLock {
            onMain = onMain || Thread.isMainThread
            defer { served = true }
            return served ? nil : [roomMember("@alice:example.org", name: "Alice")]
        }
    }
}

@MainActor
struct RoomMembersTests {
    @Test("Loading a room's members never blocks the main thread")
    func membersLoadOffMain() async {
        let members = ThreadRecordingMembers()
        let room = FakeRoom(roomInfo(id: "!large:example.org"))
        room.memberList = members
        let service = MatrixService()
        service.configureMessageActionsForChecks(
            client: FakeClient(rooms: [room]), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        service.selectedRoomID = room.id()
        await service.loadMembers()
        #expect(!members.ranOnMain)
        #expect(service.members.map(\.name) == ["Alice"])
    }

    // capability: conversation.members
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

    @Test("@room is offered and notifies only when your power level allows it", arguments: [false, true])
    func roomNotification(allowed: Bool) async {
        let room = FakeOpenRoom("!team:example.org", cached: [])
        room.memberList = [roomMember("@me:example.org")]
        room.canNotifyRoom = allowed
        let service = MatrixService()
        service.configureMessageActionsForChecks(
            client: FakeClient(rooms: [room]), main: nil, thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        service.user = ChatUser(id: "@me:example.org", name: "Me")
        service.selectedRoomID = room.id()
        await service.loadMembers()
        #expect(service.canMentionRoom == allowed)
        #expect(service.mentions(ComposerFormat.message(draft: "Heads up @room")).room == allowed)
    }
}
