import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct RoomListRefresherTests {
    @Test("A room whose details fail to load does not hide the other rooms")
    func failingRoomDoesNotAbort() async {
        let client = FakeClient(rooms: [
            FakeRoom(nil), FakeRoom(roomInfo(id: "!a:example.org")), FakeRoom(roomInfo(id: "!b:example.org")),
        ])
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.map(\.id) == ["!a:example.org", "!b:example.org"] })
    }
}

extension RoomListRefresherTests {
    @Test("A busy account whose rooms keep changing still sees its room list update")
    func updatesUnderContinuousChanges() async {
        let busy = FakeRoom(roomInfo(id: "!busy:example.org"))
        let client = FakeClient(rooms: [busy, FakeRoom(roomInfo(id: "!quiet:example.org"))])
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 2 })
        busy.changesOnEveryRead = true
        busy.info = roomInfo(id: "!busy:example.org", unread: 4)
        busy.notifyInfoChanged()
        #expect(await eventually { refresher.rooms.first?.unread == 4 })
        busy.changesOnEveryRead = false
    }
}

extension RoomListRefresherTests {
    @Test("Leaving a room or losing it from the client stops listening to it")
    func prunesLeftRooms() async {
        let left = FakeRoom(roomInfo(id: "!left:example.org"))
        let gone = FakeRoom(roomInfo(id: "!gone:example.org"))
        let kept = FakeRoom(roomInfo(id: "!kept:example.org"))
        let client = FakeClient(rooms: [left, gone, kept])
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 3 })
        left.info = roomInfo(id: "!left:example.org", membership: .left)
        client.roomList = [left, kept]
        refresher.request()
        #expect(await eventually { refresher.rooms.map(\.id) == ["!kept:example.org"] })
        let stale = left.handles + gone.handles
        #expect(!stale.isEmpty && stale.allSatisfy { $0.isCancelled })
        #expect(kept.handles.allSatisfy { !$0.isCancelled })
    }
}

extension RoomListRefresherTests {
    @Test("A refresh that finds nothing new does not republish the room list")
    func publishesOnlyChanges() async {
        let room = FakeRoom(roomInfo(id: "!room:example.org"))
        let refresher = RoomListRefresher()
        var publications: [[ChatRoom]] = []
        refresher.onChange = { publications.append(refresher.rooms) }
        refresher.attach(FakeClient(rooms: [room]))
        refresher.request()
        #expect(await eventually { publications.count == 1 })
        refresher.request()
        #expect(await eventually { room.infoReads == 2 })
        room.info = roomInfo(id: "!room:example.org", unread: 1)
        refresher.request()
        #expect(await eventually { refresher.rooms.first?.unread == 1 })
        #expect(publications.map { $0.map(\.unread) } == [[0], [1]])
    }
}

extension RoomListRefresherTests {
    @Test("A space listed inside another joined space is not a top-level workspace")
    func nestedSpaceIsNotTopLevel() async {
        let client = FakeClient(rooms: [
            FakeRoom(roomInfo(id: "!lab:example.org", isSpace: true)),
            FakeRoom(roomInfo(id: "!design:example.org", isSpace: true)),
        ])
        client.spaces.parents["!design:example.org"] = ["!lab:example.org"]
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.workspaces.count == 2 })
        #expect(refresher.workspaces.filter(\.isTopLevel).map(\.id) == ["!lab:example.org"])
    }
}

extension RoomListRefresherTests {
    @Test("SDK room calls run off the main thread")
    func roomCallsLeaveMainThreadFree() async {
        let client = FakeClient(rooms: [FakeRoom(roomInfo(id: "!room:example.org"))])
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 1 })
        #expect(!client.roomsOnMainThread.all.contains(true))
    }
}

extension RoomListRefresherTests {
    @Test("A slow room does not hold up loading the others")
    func roomsLoadConcurrently() async {
        let slow = FakeRoom(roomInfo(id: "!slow:example.org"))
        let other = FakeRoom(roomInfo(id: "!other:example.org"))
        slow.infoGate.arm()
        let refresher = RoomListRefresher()
        refresher.attach(FakeClient(rooms: [slow, other]))
        refresher.request()
        #expect(await eventually { slow.infoGate.isWaiting && other.infoReads > 0 })
        slow.infoGate.release()
        #expect(await eventually { refresher.rooms.count == 2 })
    }
}

extension RoomListRefresherTests {
    @Test("A change to one room reads only that room")
    func roomChangeReadsOnlyThatRoom() async {
        let busy = FakeRoom(roomInfo(id: "!busy:example.org"))
        let quiet = FakeRoom(roomInfo(id: "!quiet:example.org"))
        let client = FakeClient(rooms: [busy, quiet, FakeRoom(roomInfo(id: "!lab:example.org", isSpace: true))])
        client.spaces.parents = ["!busy:example.org": ["!lab:example.org"], "!quiet:example.org": ["!lab:example.org"]]
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 2 })
        let quietReads = quiet.infoReads
        let lookups = client.spaces.lookups.all.count
        busy.info = roomInfo(id: "!busy:example.org", unread: 4)
        busy.notifyInfoChanged()
        #expect(await eventually { refresher.rooms.first?.unread == 4 })
        #expect(refresher.rooms.first?.spaceIDs == ["!lab:example.org"])
        #expect(quiet.infoReads == quietReads)
        #expect(client.spaces.lookups.all.count == lookups)
    }
}

extension RoomListRefresherTests {
    @Test("A room added to a workspace elsewhere moves under it")
    func spaceChangeMovesRooms() async {
        let lab = FakeRoom(roomInfo(id: "!lab:example.org", isSpace: true))
        let client = FakeClient(rooms: [lab, FakeRoom(roomInfo(id: "!room:example.org"))])
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 1 && refresher.workspaces.count == 1 })
        client.spaces.parents["!room:example.org"] = ["!lab:example.org"]
        lab.notifyInfoChanged()
        #expect(await eventually { refresher.rooms.first?.spaceIDs == ["!lab:example.org"] })
    }
}

extension RoomListRefresherTests {
    @Test("A room the room list adds appears without rereading the others")
    func addedRoomReadsOnlyThatRoom() async {
        let quiet = FakeRoom(roomInfo(id: "!quiet:example.org"))
        let client = FakeClient(rooms: [quiet])
        let refresher = RoomListRefresher()
        refresher.attach(client)
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 1 })
        let quietReads = quiet.infoReads
        let fresh = FakeRoom(roomInfo(id: "!fresh:example.org"))
        client.roomList = [quiet, fresh]
        // A listed room's own info updates already report what moved it.
        refresher.request([.set(index: 0, value: quiet), .append(values: [fresh])])
        #expect(await eventually { refresher.rooms.map(\.id) == ["!quiet:example.org", "!fresh:example.org"] })
        #expect(quiet.infoReads == quietReads)
    }
}

private final class PostingPowers: RoomPowerLevels, @unchecked Sendable {
    let canPost: Bool
    init(canPost: Bool) {
        self.canPost = canPost
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func canOwnUserSendMessage(message: MessageLikeEventType) -> Bool { canPost || message != .roomMessage }
    override func canOwnUserPinUnpin() -> Bool { true }
    override func canOwnUserInvite() -> Bool { true }
}

extension RoomListRefresherTests {
    // capability: channel.read-only
    @Test("Whether you may post follows the room's power levels, and stays unknown without them")
    func postingPermission() async {
        let room = FakeRoom(roomInfo(id: "!news:example.org"))
        let refresher = RoomListRefresher()
        refresher.attach(FakeClient(rooms: [room]))
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 1 })
        #expect(refresher.rooms.first?.canPostMessages == nil)
        var info = roomInfo(id: "!news:example.org")
        info.powerLevels = PostingPowers(canPost: false)
        room.info = info
        room.notifyInfoChanged()
        #expect(await eventually { refresher.rooms.first?.canPostMessages == false })
        info.powerLevels = PostingPowers(canPost: true)
        room.info = info
        room.notifyInfoChanged()
        #expect(await eventually { refresher.rooms.first?.canPostMessages == true })
    }
}
