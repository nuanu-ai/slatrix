import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class ChannelPowers: RoomPowerLevels, @unchecked Sendable {
    let allowed: Bool
    init(_ allowed: Bool) {
        self.allowed = allowed
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func canOwnUserSendState(stateEvent: StateEventType) -> Bool { allowed && stateEvent == .spaceChild }
}

private final class ManagedRoom: Room, @unchecked Sendable {
    private let lock = NSLock()
    private var isJoined = true
    var space = true
    var permitted = true
    var failsPowerLookup = false
    var failsLeave = false
    let powerGate = Gate()
    let leaveGate = Gate()
    let leaves = Recorder<Void>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    var joined: Bool {
        get { lock.withLock { isJoined } }
        set { lock.withLock { isJoined = newValue } }
    }
    override func id() -> String { "!joined:example.org" }
    override func membership() -> Membership { joined ? .joined : .left }
    override func isSpace() -> Bool { space }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        await powerGate.wait()
        if failsPowerLookup { throw MatrixServiceError.request("Fixture permission lookup failed") }
        return ChannelPowers(permitted)
    }
    override func leave() async throws {
        leaves.append(())
        await leaveGate.wait()
        if failsLeave { throw MatrixServiceError.request("Fixture leave failed") }
    }
}

private final class ManagingClient: Client, @unchecked Sendable {
    let joinedRoom = ManagedRoom()
    let joinGate = Gate()
    let creations = Recorder<CreateRoomParameters>()
    let joins = Recorder<String>()
    var failsJoin = false
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func createRoom(request: CreateRoomParameters) async throws -> String {
        creations.append(request)
        return "!created:example.org"
    }
    override func joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: [String]) async throws -> Room {
        joins.append(roomIdOrAlias)
        await joinGate.wait()
        if failsJoin { throw MatrixServiceError.request("Fixture join failed") }
        return joinedRoom
    }
}

@MainActor
struct RoomManagementTests {
    private func create(
        _ client: ManagingClient, in workspace: Room?, isCurrent: @escaping () -> Bool = { true },
        link: (String) async throws -> Void = { _ in }
    ) async throws -> String {
        try await RoomManagementActions.createRoom(
            client: client, name: "Private", topic: "Topic", workspace: workspace,
            validate: { guard isCurrent() else { throw CancellationError() } }, link: link)
    }

    enum Refusal: String, CaseIterable, CustomTestStringConvertible {
        case noPermission, notJoined, notAWorkspace, permissionLookupFailed
        var testDescription: String { rawValue }
    }

    @Test("A channel is never created in a workspace that cannot take it", arguments: Refusal.allCases)
    func refusesWorkspace(reason: Refusal) async throws {
        let client = ManagingClient()
        let workspace = ManagedRoom()
        switch reason {
        case .noPermission: workspace.permitted = false
        case .notJoined: workspace.joined = false
        case .notAWorkspace: workspace.space = false
        case .permissionLookupFailed: workspace.failsPowerLookup = true
        }
        var linked = false
        await #expect(throws: MatrixServiceError.self) {
            try await create(client, in: workspace, link: { _ in linked = true })
        }
        #expect(client.creations.all.isEmpty && !linked)
    }

    @Test("Switching account during the permission lookup cancels the creation")
    func accountChangeCancelsCreation() async throws {
        let client = ManagingClient()
        let workspace = ManagedRoom()
        workspace.powerGate.arm()
        var current = true
        let pending = Task { try await create(client, in: workspace) { current } }
        #expect(await eventually { workspace.powerGate.isWaiting })
        current = false
        workspace.powerGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(client.creations.all.isEmpty)
    }

    @Test("Leaving the workspace during the permission lookup prevents the creation")
    func leavingWorkspacePreventsCreation() async throws {
        let client = ManagingClient()
        let workspace = ManagedRoom()
        workspace.powerGate.arm()
        let pending = Task { try await create(client, in: workspace) }
        #expect(await eventually { workspace.powerGate.isWaiting })
        workspace.joined = false
        workspace.powerGate.release()
        await #expect(throws: MatrixServiceError.self) { try await pending.value }
        #expect(client.creations.all.isEmpty)
    }

    // capability: home.create-channel
    @Test("Creating a channel in a workspace creates one encrypted private room and links that room")
    func createsAndLinks() async throws {
        let client = ManagingClient()
        var linked: [String] = []
        let id = try await create(client, in: ManagedRoom(), link: { linked.append($0) })
        #expect(id == "!created:example.org" && linked == [id])
        let request = try #require(client.creations.all.first)
        #expect(request.isEncrypted && request.name == "Private")
        #expect(request.visibility == .private && request.preset == .privateChat)
    }

    @Test("A room created outside a workspace is not linked anywhere")
    func standaloneIsNotLinked() async throws {
        let client = ManagingClient()
        var linked = false
        _ = try await create(client, in: nil, link: { _ in linked = true })
        #expect(client.creations.all.count == 1 && !linked)
    }

    @Test("When linking fails, the error names the room that was created and says it exists")
    func linkFailureKeepsCreatedRoom() async throws {
        let client = ManagingClient()
        do {
            _ = try await create(client, in: ManagedRoom(), link: { _ in throw MatrixServiceError.request("denied") })
            Issue.record("a failed link must be reported")
        } catch let partial as RoomCreationPartialFailure {
            #expect(partial.roomID == "!created:example.org")
            #expect(MatrixService.safeError(partial) == partial.errorDescription)
        }
        #expect(client.creations.all.count == 1)
    }

    @Test("A link failure after switching account is quiet instead of reporting the old account's room")
    func staleLinkFailureIsQuiet() async throws {
        let client = ManagingClient()
        let linkGate = Gate()
        linkGate.arm()
        var current = true
        let pending = Task {
            try await create(
                client, in: ManagedRoom(), isCurrent: { current },
                link: { _ in
                    await linkGate.wait()
                    throw MatrixServiceError.request("Fixture link failed")
                })
        }
        #expect(await eventually { linkGate.isWaiting })
        current = false
        linkGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
    }

    @Test("A join that completes after switching account returns no destination")
    func staleJoinReturnsNothing() async throws {
        let client = ManagingClient()
        client.joinGate.arm()
        var current = true
        let pending = Task {
            try await RoomManagementActions.joinRoom(client: client, address: "#room:example.org") {
                guard current else { throw CancellationError() }
            }
        }
        #expect(await eventually { client.joinGate.isWaiting })
        current = false
        client.joinGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(client.joins.all == ["#room:example.org"])
    }

    @Test("A failed join reaches the caller")
    func joinFailurePropagates() async throws {
        let client = ManagingClient()
        client.failsJoin = true
        await #expect(throws: MatrixServiceError.self) {
            try await RoomManagementActions.joinRoom(client: client, address: "#room:example.org") {}
        }
    }

    @Test("A leave that fails after switching account is quiet and not retried")
    func staleLeaveFailureIsQuiet() async throws {
        let room = ManagedRoom()
        room.leaveGate.arm()
        var current = true
        let pending = Task {
            try await RoomManagementActions.leaveRoom(room: room) { guard current else { throw CancellationError() } }
        }
        #expect(await eventually { room.leaveGate.isWaiting })
        current = false
        room.failsLeave = true
        room.leaveGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(room.leaves.all.count == 1)
    }

    @Test("Leaving from a stale context sends no leave")
    func staleLeaveIsNotSent() async throws {
        let room = ManagedRoom()
        await #expect(throws: CancellationError.self) {
            try await RoomManagementActions.leaveRoom(room: room) { throw CancellationError() }
        }
        #expect(room.leaves.all.isEmpty)
    }
}
