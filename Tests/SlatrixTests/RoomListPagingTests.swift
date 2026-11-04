import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// The SDK's dynamic room list: once its filter is set, it lists as many rooms as the page size allows.
private final class PagedRoomList: RoomList, @unchecked Sendable {
    private let rooms: [Room]
    init(rooms: [Room]) {
        self.rooms = rooms
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func entriesWithDynamicAdapters(pageSize: UInt32, listener: RoomListEntriesListener)
        -> RoomListEntriesWithDynamicAdaptersResult
    {
        Result(
            Controller {
                listener.onUpdate(roomEntriesUpdate: [.reset(values: Array(self.rooms.prefix(Int(pageSize))))])
            })
    }

    private final class Result: RoomListEntriesWithDynamicAdaptersResult, @unchecked Sendable {
        private let list: Controller
        init(_ list: Controller) {
            self.list = list
            super.init(noHandle: .init())
        }
        required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
        override func controller() -> RoomListDynamicEntriesController { list }
    }
    private final class Controller: RoomListDynamicEntriesController, @unchecked Sendable {
        private let emit: () -> Void
        init(_ emit: @escaping () -> Void) {
            self.emit = emit
            super.init(noHandle: .init())
        }
        required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
        override func setFilter(kind: RoomListEntriesDynamicFilterKind) -> Bool {
            emit()
            return true
        }
    }
}

private final class Collector: RoomListEntriesListener, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    var rooms: [String] { lock.withLock { ids } }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        for case .reset(let values) in roomEntriesUpdate { lock.withLock { ids = values.map { $0.id() } } }
    }
}

struct RoomListPagingTests {
    @Test("A busy account lists every room it has, so an old direct message still reaches the sidebar")
    func listsEveryRoom() throws {
        let rooms = (0..<250).map { FakeRoom(nil, id: "!room\($0):example.org") }
        let collector = Collector()
        let subscription = MatrixService.observeAllRooms(PagedRoomList(rooms: rooms), listener: collector)
        #expect(subscription != nil)
        #expect(collector.rooms.count == rooms.count)
    }
}
