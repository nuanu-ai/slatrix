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
