import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class DirectorySearchFake: RoomDirectorySearch, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [RoomDirectorySearchEntriesListener] = []
    private var handles: [FakeCancellableHandle] = []
    private var failSearch = false, failPage = false
    private var lastPage: Bool
    private var initial: [RoomDescription]
    private var page: [RoomDescription] = []
    let subscriptionGate = Gate(), searchGate = Gate(), pageGate = Gate(), metadataGate = Gate()
    let filters = Recorder<String?>()
    let pages = Recorder<Void>()
    var allCancelled: Bool { lock.withLock { !handles.isEmpty && handles.allSatisfy(\.isCancelled) } }

    init(_ values: [RoomDescription] = [], lastPage: Bool = false) {
        initial = values
        self.lastPage = lastPage
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    func setFailures(search: Bool = false, page: Bool = false) {
        lock.withLock {
            failSearch = search
            failPage = page
        }
    }
    func setPage(_ values: [RoomDescription], last: Bool) {
        lock.withLock {
            page = values
            lastPage = last
        }
    }
    override func results(listener: RoomDirectorySearchEntriesListener) async -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        lock.withLock {
            listeners.append(listener)
            handles.append(handle)
        }
        await subscriptionGate.wait()
        return handle
    }
    override func search(filter: String?, batchSize: UInt32, viaServerName: String?) async throws {
        filters.append(filter)
        let (failing, values) = lock.withLock { (failSearch, initial) }
        await searchGate.wait()
        if failing { throw MatrixServiceError.request("Fixture directory search failed") }
        emit([.reset(values: values)])
    }
    override func nextPage() async throws {
        pages.append(())
        let (failing, values) = lock.withLock { (failPage, page) }
        await pageGate.wait()
        if failing { throw MatrixServiceError.request("Fixture directory page failed") }
        emit([.append(values: values)])
    }
    override func isAtLastPage() async throws -> Bool {
        let value = lock.withLock { lastPage }
        await metadataGate.wait()
        return value
    }
    func emit(_ updates: [RoomDirectorySearchEntryUpdate]) {
        for listener in lock.withLock({ listeners }) { listener.onUpdate(roomEntriesUpdate: updates) }
    }
}

private final class DirectoryClient: Client, @unchecked Sendable {
    private let lock = NSLock()
    private var helpers: [DirectorySearchFake]
    let mutations = Recorder<String>()
    init(_ helpers: DirectorySearchFake...) {
        self.helpers = helpers
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    /// Hands out each helper once, in order: every query must ask for a fresh one.
    override func roomDirectorySearch() -> RoomDirectorySearch { lock.withLock { helpers.removeFirst() } }
    override func joinRoomById(roomId: String) async throws -> Room { throw mutation("join") }
    override func joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: [String]) async throws -> Room {
        throw mutation("join")
    }
    override func knock(roomIdOrAlias: String, reason: String?, serverNames: [String]) async throws -> Room {
        throw mutation("knock")
    }
    override func createRoom(request: CreateRoomParameters) async throws -> String { throw mutation("create") }
    private func mutation(_ name: String) -> Error {
        mutations.append(name)
        return MatrixServiceError.request("The directory must not change rooms")
    }
}

private func room(_ local: String, name: String? = nil, rule: PublicRoomJoinRule? = .public) -> RoomDescription {
    RoomDescription(
        roomId: "!\(local):example.org", name: name, topic: "Public directory topic", alias: "#\(local):example.org",
        avatarUrl: nil, joinRule: rule, isWorldReadable: false, joinedMembers: 12)
}

@MainActor
struct PublicRoomDirectoryServiceTests {
    private let service = PublicRoomDirectoryService()
    private let a = room("a", name: "A")
    private let b = room("b")
    private let c = room("c")

    private func ids() -> [String] { service.entries.map(\.id) }

    // capability: home.browse-channels
    @Test("An empty search lists your own server's rooms by room ID, with member count and join rule kept apart")
    func listsOwnServer() async {
        let search = DirectorySearchFake([a, b])
        service.open(client: DirectoryClient(search), validate: {})
        await service.search(query: "   ")
        #expect(search.filters.all == [nil])
        #expect(await eventually { ids() == [a.roomId, b.roomId] })
        #expect(service.hasMore && !service.isLoading)
        let first = service.entries[0]
        #expect(first.canJoin && !first.isWorldReadable && first.joinedMembers == 12)
    }

    @Test("A room listed twice appears once, with its latest details")
    func duplicateUpdatesInPlace() async {
        let search = DirectorySearchFake([a, b])
        service.open(client: DirectoryClient(search), validate: {})
        await service.search(query: "")
        search.emit([.reset(values: [a, b]), .append(values: [room("a", name: "New A", rule: .invite)])])
        #expect(await eventually { service.entries.first?.displayName == "New A" })
        #expect(service.entries.count == 2 && !service.entries[0].canJoin)
    }

    @Test("An inconsistent update clears the list with an error, and that listener is then ignored")
    func inconsistentUpdateStops() async {
        let search = DirectorySearchFake([a, b])
        service.open(client: DirectoryClient(search), validate: {})
        await service.search(query: "")
        search.emit([.set(index: 99, value: a)])
        #expect(await eventually { service.errorMessage != nil })
        #expect(service.entries.isEmpty && search.allCancelled && !service.isLoading)
        search.emit([.reset(values: [c])])
        await drainMainActor()
        #expect(service.entries.isEmpty)
    }

    @Test("The query is trimmed, rooms with malformed IDs are left out, and the last page ends paging")
    func trimsAndFilters() async {
        var descriptions = [room("ok")]
        descriptions.append(
            RoomDescription(
                roomId: "#alias-is-not-id:example.org", name: "Bad ID", topic: nil, alias: nil, avatarUrl: nil,
                joinRule: .public, isWorldReadable: true, joinedMembers: 0))
        descriptions.append(
            RoomDescription(
                roomId: "!bad\n:example.org", name: nil, topic: nil, alias: nil, avatarUrl: nil, joinRule: .public,
                isWorldReadable: true, joinedMembers: 0))
        let search = DirectorySearchFake(descriptions, lastPage: true)
        service.open(client: DirectoryClient(search), validate: {})
        await service.search(query: "  design  ")
        #expect(search.filters.all == ["design"])
        #expect(await eventually { ids() == ["!ok:example.org"] })
        #expect(!service.hasMore)
        await service.loadMore()
        #expect(search.pages.all.isEmpty)
    }

    @Test("Only a public join rule offers joining; a room without details shows its ID")
    func joinRules() async {
        let rules: [PublicRoomJoinRule?] = [.public, .knock, .restricted, .knockRestricted, .invite, nil]
        var descriptions = rules.enumerated().map { room("rule-\($0.offset)", rule: $0.element) }
        descriptions[5].name = nil
        descriptions[5].topic = nil
        descriptions[5].alias = nil
        let search = DirectorySearchFake(descriptions, lastPage: true)
        service.open(client: DirectoryClient(search), validate: {})
        await service.search(query: "rules")
        #expect(await eventually { service.entries.count == 6 })
        #expect(
            service.entries.map(\.joinRule) == [.publicRoom, .knock, .restricted, .knockRestricted, .invite, .unknown])
        #expect(service.entries.map(\.canJoin) == [true, false, false, false, false, false])
        #expect(service.entries.last?.displayName == "!rule-5:example.org")
    }

    @Test("A failed page keeps the rooms already shown and can be retried; a retry in flight is not doubled")
    func pageRetry() async {
        let search = DirectorySearchFake([a])
        service.open(client: DirectoryClient(search), validate: {})
        await service.search(query: "project")
        #expect(await eventually { ids() == [a.roomId] })
        search.setFailures(page: true)
        await service.loadMore()
        #expect(ids() == [a.roomId] && service.hasMore && !service.isLoading && service.errorMessage != nil)
        search.setFailures()
        search.setPage([b], last: true)
        search.pageGate.arm()
        let retry = Task { await service.loadMore() }
        #expect(await eventually { search.pageGate.isWaiting })
        await service.loadMore()
        #expect(search.pages.all.count == 2)
        search.pageGate.release()
        await retry.value
        #expect(await eventually { ids() == [a.roomId, b.roomId] })
        #expect(!service.hasMore && service.errorMessage == nil)
    }

    @Test("A new query uses a fresh search, and the old one's late results cannot overwrite it")
    func newQueryReplacesOld() async {
        let old = DirectorySearchFake([a])
        let fresh = DirectorySearchFake([b], lastPage: true)
        old.searchGate.arm()
        service.open(client: DirectoryClient(old, fresh), validate: {})
        let first = Task { await service.search(query: "old") }
        #expect(await eventually { old.searchGate.isWaiting })
        let firstScope = service.scopeID
        await service.search(query: "new")
        old.searchGate.release()
        await first.value
        #expect(await eventually { ids() == [b.roomId] })
        await drainMainActor()
        #expect(ids() == [b.roomId] && service.scopeID != firstScope && !service.hasMore && old.allCancelled)
    }

    @Test("The old query's late page state cannot change the new query's paging")
    func lateMetadataIgnored() async {
        let old = DirectorySearchFake([a])
        let fresh = DirectorySearchFake([b], lastPage: true)
        old.metadataGate.arm()
        service.open(client: DirectoryClient(old, fresh), validate: {})
        let first = Task { await service.search(query: "old") }
        #expect(await eventually { old.metadataGate.isWaiting })
        await service.search(query: "new")
        old.metadataGate.release()
        await first.value
        #expect(!service.hasMore && !service.isLoading)
        #expect(await eventually { ids() == [b.roomId] })
    }

    @Test("After an account switch, the old account's search never starts and its results never show")
    func accountSwitch() async {
        let late = DirectorySearchFake([a])
        let newer = DirectorySearchFake([c], lastPage: true)
        late.subscriptionGate.arm()
        var current = true
        service.open(client: DirectoryClient(late), validate: { if !current { throw CancellationError() } })
        let old = Task { await service.search(query: "old-account") }
        #expect(await eventually { late.subscriptionGate.isWaiting })
        current = false
        service.open(client: DirectoryClient(newer), validate: {})
        await service.search(query: "new-account")
        late.subscriptionGate.release()
        await old.value
        #expect(await eventually { ids() == [c.roomId] })
        #expect(late.allCancelled && late.filters.all.isEmpty)
        // Two updates, so the old listener's revision overtakes the current one's.
        late.emit([.reset(values: [b])])
        late.emit([.reset(values: [b])])
        await drainMainActor()
        #expect(ids() == [c.roomId])
    }

    @Test("Closing stops the listener and ignores a search that finishes afterwards")
    func closeIgnoresLateCompletion() async {
        let search = DirectorySearchFake([a])
        search.searchGate.arm()
        service.open(client: DirectoryClient(search), validate: {})
        let pending = Task { await service.search(query: "close") }
        #expect(await eventually { search.searchGate.isWaiting })
        service.close()
        search.searchGate.release()
        await pending.value
        await drainMainActor()
        #expect(service.entries.isEmpty && service.errorMessage == nil && !service.isLoading && !service.hasMore)
        #expect(search.allCancelled)
    }

    @Test("A failed search shows a retryable error; retrying starts a fresh search, and browsing never changes rooms")
    func searchRetry() async {
        let failing = DirectorySearchFake([a])
        failing.setFailures(search: true)
        let recovered = DirectorySearchFake([c], lastPage: true)
        let client = DirectoryClient(failing, recovered)
        service.open(client: client, validate: {})
        await service.search(query: "retry")
        #expect(service.errorMessage != nil && !service.isLoading && !service.hasMore && failing.allCancelled)
        await service.search(query: "retry")
        #expect(await eventually { ids() == [c.roomId] })
        #expect(service.errorMessage == nil)
        #expect(client.mutations.all.isEmpty)
    }
}

/// A space's hierarchy, served a page at a time.
private final class SpaceListFake: SpaceRoomList, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [[SpaceRoom]]
    private var loaded: [SpaceRoom] = []
    init(pages: [[SpaceRoom]]) {
        self.pages = pages
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func paginate() async throws { lock.withLock { if !pages.isEmpty { loaded += pages.removeFirst() } } }
    override func paginationState() -> SpaceRoomListPaginationState {
        lock.withLock { .idle(endReached: pages.isEmpty) }
    }
    override func rooms() async -> [SpaceRoom] { lock.withLock { loaded } }
}

private func child(
    _ local: String, name: String, type: RoomType = .room, rule: JoinRule? = .public, members: UInt64 = 5,
    state: Membership? = nil, direct: Bool? = nil
) -> SpaceRoom {
    SpaceRoom(
        roomId: "!\(local):example.org", canonicalAlias: nil, displayName: name, rawName: name,
        topic: "About \(name)", avatarUrl: nil, roomType: type, numJoinedMembers: members, joinRule: rule,
        worldReadable: false, guestCanJoin: false, isDirect: direct, childrenCount: 0, state: state, heroes: nil,
        via: ["example.org"], isDm: direct)
}

extension PublicRoomDirectoryServiceTests {
    // capability: home.browse-channels
    @Test("Browsing a workspace lists its channels from every page, not its nested spaces or direct messages")
    func listsWorkspaceChannels() async {
        let client = FakeClient()
        client.spaces.roomLists["!lab:example.org"] = SpaceListFake(pages: [
            [child("general", name: "General", state: .joined), child("nested", name: "Design", type: .space)],
            [
                child("research", name: "Research", rule: .restricted(rules: []), members: 9),
                child("dm", name: "Alex", direct: true), child("board", name: "Board", rule: .invite),
            ],
        ])
        service.open(client: client, spaceID: "!lab:example.org", validate: {})
        await service.search(query: "")
        #expect(ids() == ["!general:example.org", "!research:example.org", "!board:example.org"])
        let research = service.entries[1]
        #expect(research.joinedMembers == 9 && research.topic == "About Research" && research.via == ["example.org"])
        // Members of the workspace may join its restricted channels; an invite-only one stays closed.
        #expect(service.entries.map(\.canJoin) == [true, true, false])
        #expect(!service.hasMore && !service.isLoading)

        await service.search(query: " rese ")
        #expect(ids() == ["!research:example.org"])
    }
}
