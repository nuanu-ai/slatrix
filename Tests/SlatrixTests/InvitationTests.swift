import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class Powers: RoomPowerLevels, @unchecked Sendable {
    let invites: Bool
    let children: Bool
    init(invites: Bool = true, children: Bool = true) {
        self.invites = invites
        self.children = children
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func canOwnUserInvite() -> Bool { invites }
    override func canOwnUserSendState(stateEvent: StateEventType) -> Bool { stateEvent == .spaceChild && children }
}

/// A room whose power levels come from `RoomInfo` (`powers`) or, when those are missing, `getPowerLevels()`
/// (`fallbackPowers`; `nil` makes the lookup fail).
private final class InvitationRoom: Room, @unchecked Sendable {
    let identifier: String
    let space: Bool
    let writes = Recorder<String>()
    let membershipGate = Gate()
    let infoGate = Gate()
    let powerGate = Gate()
    private let lock = NSLock()
    private var member: Membership
    var powers: RoomPowerLevels? = Powers()
    var fallbackPowers: RoomPowerLevels?
    var fails = false

    init(_ id: String, space: Bool = false, membership: Membership = .invited) {
        identifier = id
        self.space = space
        member = membership
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    override func id() -> String { identifier }
    override func isSpace() -> Bool { space }
    override func membership() -> Membership { lock.withLock { member } }
    func setMembership(_ value: Membership) { lock.withLock { member = value } }
    override func join() async throws {
        writes.append("join")
        await membershipGate.wait()
        if fails { throw MatrixServiceError.request("Fixture join failed") }
        setMembership(.joined)
    }
    override func leave() async throws {
        writes.append("leave")
        await membershipGate.wait()
        if fails { throw MatrixServiceError.request("Fixture leave failed") }
        setMembership(.left)
    }
    override func inviteUserById(userId: String) async throws { writes.append("invite:\(userId)") }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        await powerGate.wait()
        guard let fallbackPowers else { throw MatrixServiceError.request("Fixture permission lookup failed") }
        return fallbackPowers
    }
    override func roomInfo() async throws -> RoomInfo {
        await infoGate.wait()
        var info = SlatrixTests.roomInfo(id: identifier, membership: membership(), isSpace: space)
        info.powerLevels = powers
        return info
    }
}

private final class Spaces: SpaceService, @unchecked Sendable {
    var parents: [String] = []
    let writes = Recorder<String>()
    let parentGate = Gate()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func topLevelJoinedSpaces() async -> [SpaceRoom] { [] }
    override func joinedParentIdsOfChild(childId: String) async throws -> [String] {
        await parentGate.wait()
        return parents
    }
    override func addChildToSpace(childId: String, spaceId: String) async throws {
        writes.append("add:\(childId):\(spaceId)")
        parents.append(spaceId)
    }
    override func removeChildFromSpace(childId: String, spaceId: String) async throws {
        writes.append("remove:\(childId):\(spaceId)")
        parents.removeAll { $0 == spaceId }
    }
}

/// Where a room is listed by its membership, from the shared cases in `spec/invitations.json`.
struct InvitationPlacementTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var space: Bool
        var membership: String
        var expected: String
        var testDescription: String { name }
    }

    struct Spec: Decodable { var placement: [Case] }

    @Test(
        "Rooms are placed as in every shared case",
        arguments: try SharedSpec.decode("spec/invitations.json", as: Spec.self).placement)
    func placement(spec: Case) throws {
        let memberships: [String: Membership] = [
            "invited": .invited, "joined": .joined, "left": .left, "banned": .banned,
        ]
        let placements: [String: InvitationRoomPlacement] = [
            "conversation": .conversation, "workspace": .workspace, "ignored": .ignored,
        ]
        let membership = try #require(memberships[spec.membership])
        #expect(
            InvitationRoomPlacement.classify(isSpace: spec.space, membership: membership) == placements[spec.expected])
    }
}

@MainActor
struct InvitationActionTests {

    // capability: home.invitations
    @Test("A second Accept while the first is in flight shares its join and its destination")
    func duplicateAcceptSharesJoin() async throws {
        var pending = Set<String>()
        let actions = InvitationActions { pending = $0 }
        let room = InvitationRoom("!room:example.org")
        room.membershipGate.arm()
        let first = Task { try await actions.perform(room: room, action: .accept) { true } }
        #expect(await eventually { room.membershipGate.isWaiting })
        var duplicateStarted = false
        let duplicate = Task {
            try await actions.perform(room: room, action: .accept) {
                duplicateStarted = true
                return true
            }
        }
        // Past its first check, the duplicate is awaiting the request in flight.
        #expect(await eventually { duplicateStarted })
        #expect(pending == [room.id()])
        await #expect(throws: MatrixServiceError.self) {
            try await actions.perform(room: room, action: .decline) { true }
        }
        room.membershipGate.release()
        let destination = try await first.value
        #expect(destination == InvitationDestination(id: room.id(), kind: .room))
        #expect(try await duplicate.value == destination)
        #expect(room.writes.all == ["join"] && pending.isEmpty)
    }

    @Test("An invitation that is no longer pending is not accepted again")
    func joinedRoomIsNotAcceptedAgain() async throws {
        let room = InvitationRoom("!room:example.org", membership: .joined)
        await #expect(throws: MatrixServiceError.self) {
            try await InvitationActions().perform(room: room, action: .accept) { true }
        }
        #expect(room.writes.all.isEmpty)
    }

    // capability: home.invitations
    @Test("Declining an invited workspace leaves it and reports a workspace")
    func declineWorkspace() async throws {
        let space = InvitationRoom("!workspace:example.org", space: true)
        let destination = try await InvitationActions().perform(room: space, action: .decline) { true }
        #expect(destination.kind == .workspace)
        #expect(space.writes.all == ["leave"] && space.membership() == .left)
    }

    @Test("A failed Accept clears the busy state and can be retried")
    func failedAcceptIsRetryable() async throws {
        var pending = Set<String>()
        let actions = InvitationActions { pending = $0 }
        let room = InvitationRoom("!retry:example.org")
        room.fails = true
        await #expect(throws: MatrixServiceError.self) {
            try await actions.perform(room: room, action: .accept) { true }
        }
        #expect(pending.isEmpty)
        room.fails = false
        _ = try await actions.perform(room: room, action: .accept) { true }
        #expect(room.writes.all == ["join", "join"])
    }

    @Test("An invitation acted on from a stale account makes no membership request")
    func staleAccountMakesNoRequest() async throws {
        let room = InvitationRoom("!stale:example.org")
        await #expect(throws: CancellationError.self) {
            try await InvitationActions().perform(room: room, action: .accept) { false }
        }
        #expect(room.writes.all.isEmpty)
    }

    @Test("After a sign-out, the old account's late Accept neither returns nor clears the new account's request")
    func oldAccountCompletionIsIsolated() async throws {
        var pending = Set<String>()
        let actions = InvitationActions { pending = $0 }
        let old = InvitationRoom("!same:example.org")
        old.membershipGate.arm()
        let oldAccept = Task { try await actions.perform(room: old, action: .accept) { true } }
        #expect(await eventually { old.membershipGate.isWaiting })
        actions.reset()
        let current = InvitationRoom(old.id(), space: true)
        current.membershipGate.arm()
        let currentAccept = Task { try await actions.perform(room: current, action: .accept) { true } }
        #expect(await eventually { current.membershipGate.isWaiting })
        old.membershipGate.release()
        await #expect(throws: CancellationError.self) { try await oldAccept.value }
        #expect(pending == [current.id()])
        current.membershipGate.release()
        #expect(try await currentAccept.value == InvitationDestination(id: current.id(), kind: .workspace))
        #expect(pending.isEmpty)
    }
}

@MainActor
struct InvitationPermissionTests {
    enum Permission: String, CaseIterable, CustomTestStringConvertible {
        case allowed, denied, deniedDespiteFallback, fallbackAllowed, fallbackDenied, fallbackFailed
        var testDescription: String { rawValue }
        var allows: Bool { self == .allowed || self == .fallbackAllowed }
    }

    // capability: channel.invite
    @Test(
        "Inviting someone needs invite permission, checked with the SDK when RoomInfo lacks it",
        arguments: Permission.allCases)
    func invitePermission(permission: Permission) async throws {
        let room = InvitationRoom("!room:example.org", membership: .joined)
        permission.configure(room)
        let invite = { try await InvitationPermissions.invite(room: room, userID: "@person:example.org") {} }
        if permission.allows {
            try await invite()
            #expect(room.writes.all == ["invite:@person:example.org"])
        } else {
            await #expect(throws: (any Error).self) { try await invite() }
            #expect(room.writes.all.isEmpty)
        }
    }

    enum Wait: String, CaseIterable, CustomTestStringConvertible {
        case roomInfo, powerLevels
        var testDescription: String { rawValue }
    }

    @Test("An invite whose account changed during the permission lookup is not sent", arguments: Wait.allCases)
    func staleInviteIsNotSent(wait: Wait) async throws {
        let room = InvitationRoom("!room:example.org", membership: .joined)
        let gate = wait == .roomInfo ? room.infoGate : room.powerGate
        if wait == .powerLevels { (room.powers, room.fallbackPowers) = (nil, Powers()) }
        gate.arm()
        var current = true
        let pending = Task {
            try await InvitationPermissions.invite(room: room, userID: "@person:example.org") {
                guard current else { throw CancellationError() }
            }
        }
        #expect(await eventually { gate.isWaiting })
        current = false
        gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(room.writes.all.isEmpty)
    }

    @Test("An invite to a room left during the permission lookup is not sent")
    func leftRoomInviteIsNotSent() async throws {
        let room = InvitationRoom("!room:example.org", membership: .joined)
        (room.powers, room.fallbackPowers) = (nil, Powers())
        room.powerGate.arm()
        let pending = Task { try await InvitationPermissions.invite(room: room, userID: "@person:example.org") {} }
        #expect(await eventually { room.powerGate.isWaiting })
        room.setMembership(.left)
        room.powerGate.release()
        await #expect(throws: MatrixServiceError.self) { try await pending.value }
        #expect(room.writes.all.isEmpty)
    }
}

@MainActor
struct WorkspaceLinkTests {
    private let workspace = InvitationRoom("!parent:example.org", space: true, membership: .joined)
    private let channel = InvitationRoom("!child:example.org", membership: .joined)

    private func link(_ spaces: Spaces, adding: Bool, isCurrent: @escaping () -> Bool = { true }) async throws {
        try await InvitationPermissions.updateSpaceLink(
            space: workspace, child: channel, spaces: spaces, adding: adding
        ) {
            guard isCurrent() else { throw CancellationError() }
        }
    }

    @Test("A channel inherited through another workspace cannot be unlinked as if it were direct")
    func indirectLinkCannotBeRemoved() async throws {
        let spaces = Spaces()
        await #expect(throws: MatrixServiceError.self) { try await link(spaces, adding: false) }
        #expect(spaces.writes.all.isEmpty)
    }

    // capability: channel.link-workspace
    @Test("Linking twice adds once, and unlinking removes only that workspace's link")
    func linkAndUnlink() async throws {
        let spaces = Spaces()
        spaces.parents = ["!other:example.org"]
        try await link(spaces, adding: true)
        try await link(spaces, adding: true)
        try await link(spaces, adding: false)
        #expect(
            spaces.writes.all == [
                "add:!child:example.org:!parent:example.org", "remove:!child:example.org:!parent:example.org",
            ])
        #expect(spaces.parents == ["!other:example.org"])
    }

    @Test(
        "Linking a channel needs permission to manage the workspace's channels",
        arguments: InvitationPermissionTests.Permission.allCases)
    func linkPermission(permission: InvitationPermissionTests.Permission) async throws {
        permission.configure(workspace)
        let spaces = Spaces()
        if permission.allows {
            try await link(spaces, adding: true)
            #expect(spaces.writes.all.count == 1)
        } else {
            await #expect(throws: (any Error).self) { try await link(spaces, adding: true) }
            #expect(spaces.writes.all.isEmpty)
        }
    }

    @Test("A link change whose account changed while the SDK answered is not made", arguments: [false, true])
    func staleLinkChangeIsNotMade(duringPermissionLookup: Bool) async throws {
        let spaces = Spaces()
        let gate = duringPermissionLookup ? workspace.powerGate : spaces.parentGate
        if duringPermissionLookup { (workspace.powers, workspace.fallbackPowers) = (nil, Powers()) }
        gate.arm()
        var current = true
        let pending = Task { try await link(spaces, adding: true) { current } }
        #expect(await eventually { gate.isWaiting })
        current = false
        gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(spaces.writes.all.isEmpty)
    }
}

extension InvitationPermissionTests.Permission {
    fileprivate func configure(_ room: InvitationRoom) {
        let allow = Powers()
        let deny = Powers(invites: false, children: false)
        switch self {
        case .allowed: room.powers = allow
        case .denied: room.powers = deny
        case .deniedDespiteFallback: (room.powers, room.fallbackPowers) = (deny, allow)
        case .fallbackAllowed: (room.powers, room.fallbackPowers) = (nil, allow)
        case .fallbackDenied: (room.powers, room.fallbackPowers) = (nil, deny)
        case .fallbackFailed: (room.powers, room.fallbackPowers) = (nil, nil)
        }
    }
}
