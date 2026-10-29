import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class LinkRoom: Room, @unchecked Sendable {
    let identifier: String
    let space: Bool
    /// False until the room's create event has synced, so its type is still unknown.
    var stateReady = true
    var state = Membership.joined
    var infoFails = false
    let infoGate = Gate()
    init(_ id: String, space: Bool = false) {
        identifier = id
        self.space = space
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func id() -> String { identifier }
    override func membership() -> Membership { state }
    override func isSpace() -> Bool { space }
    override func roomInfo() async throws -> RoomInfo {
        await infoGate.wait()
        if infoFails { throw FixtureFailure() }
        var info = SlatrixTests.roomInfo(id: identifier, isSpace: space)
        info.creators = stateReady ? ["@owner:example.org"] : nil
        return info
    }
}

private final class LinkPreview: RoomPreview, @unchecked Sendable {
    let identifier: String
    let space: Bool
    init(_ id: String, space: Bool) {
        identifier = id
        self.space = space
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func info() -> RoomPreviewInfo {
        RoomPreviewInfo(
            roomId: identifier, canonicalAlias: nil, name: "Fixture", topic: nil, avatarUrl: nil, numJoinedMembers: 1,
            numActiveMembers: 1, roomType: space ? .space : .room, isHistoryWorldReadable: false, membership: nil,
            joinRule: nil, isDirect: false, heroes: nil)
    }
}

private struct FixtureFailure: Error {}

private final class LinkClient: Client, @unchecked Sendable {
    let ownID = "@owner:example.org"
    private let lock = NSLock()
    private var rooms: [String: LinkRoom] = [:]
    var aliasResult: ResolvedRoomAlias? = ResolvedRoomAlias(
        roomId: "!resolved:example.org", servers: ["resolver.example.org"])
    var failAlias = false
    /// nil: the preview is unavailable, as for a private room.
    var previewIsSpace: Bool?
    var throwAfterAccept = false
    var joinedRoomID: String?
    let aliasGate = Gate(), previewGate = Gate(), joinGate = Gate()
    let aliases = Recorder<String>()
    let previews = Recorder<String>()
    let joins = Recorder<(String, [String])>()
    let creates = Recorder<Void>()

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    func add(_ room: LinkRoom) { lock.withLock { rooms[room.id()] = room } }
    override func userId() throws -> String { ownID }
    override func getRoom(roomId: String) throws -> Room? { lock.withLock { rooms[roomId] } }
    override func resolveRoomAlias(roomAlias: String) async throws -> ResolvedRoomAlias? {
        aliases.append(roomAlias)
        await aliasGate.wait()
        if failAlias { throw FixtureFailure() }
        return aliasResult
    }
    override func getRoomPreviewFromRoomId(roomId: String, viaServers: [String]) async throws -> RoomPreview {
        previews.append(roomId)
        await previewGate.wait()
        guard let previewIsSpace else { throw FixtureFailure() }
        return LinkPreview(roomId, space: previewIsSpace)
    }
    override func joinRoomByIdOrAlias(roomIdOrAlias: String, serverNames: [String]) async throws -> Room {
        joins.append((roomIdOrAlias, serverNames))
        await joinGate.wait()
        let room = LinkRoom(joinedRoomID ?? roomIdOrAlias)
        room.stateReady = false
        add(room)
        if throwAfterAccept { throw FixtureFailure() }
        return room
    }
    override func createRoom(request: CreateRoomParameters) async throws -> String {
        creates.append(())
        return "!unexpected:example.org"
    }
}

/// Stands in for the session check the app runs after every await.
@MainActor
private final class Session {
    var current = true
    func validate() throws { guard current else { throw CancellationError() } }
}

@MainActor
private func entity(_ link: String) throws -> MatrixEntity {
    let url = try #require(URL(string: link))
    return try #require(try MatrixLinkService.parse(url))
}

@MainActor
struct MatrixLinkParsingTests {
    @Test(
        "matrix.to and matrix: links parse into the right typed target",
        arguments: [
            ("https://matrix.to/#/%40alice%3Aexample.org", MatrixId.user(id: "@alice:example.org")),
            ("https://matrix.to/#/!room:example.org", .room(id: "!room:example.org")),
            ("https://matrix.to/#/%23design%3Aexample.org", .roomAlias(alias: "#design:example.org")),
            (
                "https://matrix.to/#/!room:example.org/$event",
                .eventOnRoomId(roomId: "!room:example.org", eventId: "$event")
            ),
            (
                "https://matrix.to/#/%23design:example.org/$event",
                .eventOnRoomAlias(alias: "#design:example.org", eventId: "$event")
            ),
            ("matrix:u/alice:example.org?action=chat", .user(id: "@alice:example.org")),
            ("matrix:roomid/room:example.org/e/event", .eventOnRoomId(roomId: "!room:example.org", eventId: "$event")),
        ])
    func parses(link: String, expected: MatrixId) throws {
        #expect(try entity(link).id == expected)
    }

    @Test("Routing hints keep their order, repeats included")
    func keepsRoutingHints() throws {
        let routed = try entity(
            "https://matrix.to/#/!room:example.org/$event?via=one.example.org&via=two.example.org&via=one.example.org")
        #expect(routed.via == ["one.example.org", "two.example.org", "one.example.org"])
    }

    @Test(
        "Ordinary and look-alike hosts are not treated as Matrix links",
        arguments: [
            "https://example.org/#/!room:example.org", "https://matrix.to.evil/#/!room:example.org",
            "https://matrix.to@evil.example/#/!room:example.org",
        ])
    func ignoresOtherHosts(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(!MatrixLinkService.isMatrixCandidate(url))
        #expect(try MatrixLinkService.parse(url) == nil)
    }

    @Test("A look-alike link with credentials is not opened in the browser either")
    func spoofNotOpenedExternally() throws {
        let url = try #require(URL(string: "https://matrix.to@evil.example/#/!room:example.org"))
        #expect(!PlatformIntegration.isSafeExternalURL(url))
    }

    @Test(
        "Malformed, credential-bearing, oversized or control-character Matrix links are rejected",
        arguments: [
            "https://matrix.to/#///$event", "https://matrix.to/#/!room:example.org///", "https://matrix.to/#//",
            "https://matrix.to/", "https://matrix.to/!room:example.org", "https://matrix.to/?via=server.org",
            "https://matrix.to/#/invalid", "http://matrix.to/#/!room:example.org",
            "https://matrix.to:443/#/!room:example.org", "https://alice:secret@matrix.to/#/!room:example.org",
            "https://matrix.to/other#/!room:example.org", "matrix://evil.example/u/alice:example.org",
            "matrix://alice:secret@evil.example/u/alice:example.org", "matrix:u/alice:example.org#fragment",
            "https://matrix.to/#/@ali%00ce:example.org", "matrix:u/ali%0Ace:example.org",
            "matrix:u/alice:example.org?via=server%0A.example.org",
            "matrix:roomid/room:example.org?via=https%3A%2F%2Fevil.example",
            "matrix:roomid/room:example.org?via=user%40evil.example",
            "https://matrix.to/#/!room:example.org?unexpected=value",
            "matrix:u/" + String(repeating: "a", count: 9_000) + ":example.org",
        ])
    func rejectsMalformed(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: (any Error).self) { try MatrixLinkService.parse(url) }
    }

    @Test(
        "Percent sequences in an ID are decoded once, never twice",
        arguments: [("%250A", "%0A"), ("%252F", "%2F")])
    func decodesOnce(encoded: String, literal: String) throws {
        let link = "https://matrix.to/#/@ali\(encoded)ce:example.org"
        let url = try #require(URL(string: link))
        if let parsed = try? MatrixLinkService.parse(url) {
            #expect(parsed.id == .user(id: "@ali\(literal)ce:example.org"))
        } else {
            #expect(parseMatrixEntityFrom(uri: link) == nil)
        }
    }
}

@MainActor
struct MatrixLinkResolutionTests {
    private let client = LinkClient()
    private let session = UUID()

    private func resolve(_ link: String, validate: () throws -> Void = {}) async throws -> MatrixLinkResolution {
        try await resolve(entity(link), validate: validate)
    }
    private func resolve(_ entity: MatrixEntity, validate: () throws -> Void = {}) async throws
        -> MatrixLinkResolution
    {
        try await MatrixLinkService.resolve(
            client: client, entity: entity, accountID: client.ownID, sessionID: session, validate: validate)
    }
    private func joinRequest(_ link: String) async throws -> MatrixRoomJoinRequest {
        guard case .join(let request) = try await resolve(link).destination else {
            Issue.record("expected a join confirmation")
            throw FixtureFailure()
        }
        return request
    }
    private func join(_ request: MatrixRoomJoinRequest, validate: () throws -> Void = {}) async throws
        -> MatrixRoomJoinDestination
    {
        try await MatrixLinkService.join(client: client, request: request, validate: validate)
    }
    private var direct: MatrixRoomJoinRequest {
        MatrixRoomJoinRequest(
            accountID: client.ownID, sessionID: session, address: "!direct:example.org",
            roomID: "!direct:example.org", via: ["route.example.org"], eventID: "$event", isSpaceHint: false)
    }

    // capability: message.matrix-links
    @Test("A link to a message in a joined room opens that message for the same account and session")
    func joinedRoomMessage() async throws {
        client.add(LinkRoom("!room:example.org"))
        let resolution = try await resolve("https://matrix.to/#/!room:example.org/$event")
        #expect(resolution.destination == .conversation(roomID: "!room:example.org", eventID: "$event"))
        #expect(resolution.sessionID == session && resolution.accountID == client.ownID)
    }

    // capability: message.matrix-links
    @Test("A user link, even with action=chat, opens the profile and changes nothing")
    func userLinkOpensProfile() async throws {
        let resolution = try await resolve("matrix:u/alice:example.org?action=chat")
        #expect(resolution.destination == .profile(userID: "@alice:example.org"))
        #expect(client.joins.all.isEmpty && client.creates.all.isEmpty)
    }

    @Test("A joined Space opens as a workspace; a link to a message inside it is refused")
    func joinedSpace() async throws {
        client.add(LinkRoom("!workspace:example.org", space: true))
        #expect(
            try await resolve("https://matrix.to/#/!workspace:example.org").destination
                == .workspace(spaceID: "!workspace:example.org"))
        await #expect(throws: MatrixLinkError.workspaceEvent) {
            try await resolve("https://matrix.to/#/!workspace:example.org/$event")
        }
        #expect(client.joins.all.isEmpty)
    }

    @Test("An alias link asks to join the room it resolves to, merging the link's and the server's routes")
    func aliasNeedsConfirmation() async throws {
        client.aliasResult = ResolvedRoomAlias(
            roomId: "!resolved:example.org", servers: ["resolver.example.org", "link.example.org"])
        let request = try await joinRequest("https://matrix.to/#/%23design:example.org/$event?via=link.example.org")
        #expect(request.address == "#design:example.org" && request.roomID == "!resolved:example.org")
        #expect(request.eventID == "$event" && request.isSpaceHint == nil)
        #expect(request.via == ["link.example.org", "resolver.example.org"])
        #expect(request.sessionID == session && request.accountID == client.ownID)
        #expect(client.joins.all.isEmpty)
    }

    @Test("Joining uses the reviewed room ID and routes, and a room of unknown type joins with a syncing notice")
    func joinUsesReviewedTarget() async throws {
        let request = try await joinRequest("https://matrix.to/#/%23design:example.org/$event")
        client.aliasResult = ResolvedRoomAlias(roomId: "!redirected:example.org", servers: ["different.example.org"])
        let joined = try await join(request)
        #expect(client.joins.all.map(\.0) == ["!resolved:example.org"])
        #expect(client.joins.all.map(\.1) == [request.via])
        #expect(joined.roomID == request.roomID && joined.eventID == "$event")
        #expect(joined.isSpace == nil && joined.warning != nil)
    }

    @Test("A joined room whose type has not synced is not opened as a chat, and joining it again sends nothing")
    func unclassifiedJoinedRoom() async throws {
        let request = try await joinRequest("https://matrix.to/#/%23design:example.org")
        _ = try await join(request)
        await #expect(throws: MatrixLinkError.detailsSyncing) {
            try await resolve("https://matrix.to/#/!resolved:example.org/$event")
        }
        let again = try await join(request)
        #expect(again.roomID == request.roomID && client.joins.all.count == 1)
    }

    @Test("An alias the server does not know is refused")
    func unknownAlias() async {
        client.aliasResult = nil
        await #expect(throws: MatrixLinkError.aliasNotFound) {
            try await resolve("https://matrix.to/#/%23missing:example.org")
        }
    }

    @Test("A route from the server that is not a server name is refused")
    func badResolverRoute() async {
        client.aliasResult = ResolvedRoomAlias(roomId: "!resolved:example.org", servers: ["https://evil.example"])
        await #expect(throws: MatrixLinkError.invalidLink) {
            try await resolve("https://matrix.to/#/%23design:example.org")
        }
    }

    @Test(
        "Switching accounts while an alias resolves, fails or previews cancels the link quietly",
        arguments: ["alias", "alias failure", "preview"])
    func accountSwitchCancels(stage: String) async throws {
        let gate = stage == "preview" ? client.previewGate : client.aliasGate
        client.failAlias = stage == "alias failure"
        gate.arm()
        let session = Session()
        let link =
            stage == "preview" ? "https://matrix.to/#/!room:example.org" : "https://matrix.to/#/%23design:example.org"
        let pending = Task { try await resolve(link, validate: session.validate) }
        #expect(await eventually { gate.isWaiting })
        session.current = false
        gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(client.joins.all.isEmpty)
        if stage != "preview" { #expect(client.previews.all.isEmpty) }
    }

    @Test("A preview that shows a Space carries through the join and later opens as a workspace")
    func previewClassifiesSpace() async throws {
        client.previewIsSpace = true
        let request = try await joinRequest("https://matrix.to/#/!space:example.org")
        #expect(request.isSpaceHint == true)
        let joined = try await join(request)
        #expect(joined.isSpace == true && joined.warning == nil)
        #expect(
            try await resolve("https://matrix.to/#/!space:example.org").destination
                == .workspace(spaceID: "!space:example.org"))
        await #expect(throws: MatrixLinkError.workspaceEvent) {
            try await resolve("https://matrix.to/#/!other-space:example.org/$event")
        }
        #expect(client.joins.all.count == 1)
    }

    @Test("Confirming the same join twice at once sends one join")
    func concurrentJoinsShareOne() async throws {
        client.joinGate.arm()
        let request = direct
        let first = Task { try await join(request) }
        #expect(await eventually { client.joinGate.isWaiting })
        await #expect(throws: MatrixLinkError.joinBusy) { try await join(request) }
        client.joinGate.release()
        let joined = try await first.value
        #expect(joined.roomID == request.roomID && joined.eventID == "$event" && joined.isSpace == false)
        #expect(client.joins.all.count == 1)
    }

    @Test(
        "A join that completes or fails after an account switch is cancelled quietly and not repeated",
        arguments: [false, true])
    func staleJoinCancelled(joinFails: Bool) async throws {
        client.throwAfterAccept = joinFails
        client.joinGate.arm()
        let session = Session()
        let request = direct
        let pending = Task { try await join(request, validate: session.validate) }
        #expect(await eventually { client.joinGate.isWaiting })
        session.current = false
        client.joinGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(client.joins.all.count == 1)
    }

    @Test("When the reply to an accepted join is lost, retrying finds the joined room instead of joining again")
    func lostReplyReconciled() async throws {
        client.throwAfterAccept = true
        await #expect(throws: (any Error).self) { try await join(direct) }
        client.throwAfterAccept = false
        _ = try await join(direct)
        #expect(client.joins.all.count == 1)
    }

    @Test("If the server joins a different room, the app stays on the reviewed one with a warning")
    func unexpectedRoomNotFollowed() async throws {
        client.joinedRoomID = "!different:example.org"
        let joined = try await join(direct)
        #expect(joined.roomID == direct.roomID && joined.isSpace == nil && joined.warning != nil)
        #expect(client.joins.all.count == 1)
    }

    @Test("A link resolved after the session ended sends no request to the server")
    func staleBeforeStart() async {
        let session = Session()
        session.current = false
        await #expect(throws: CancellationError.self) {
            try await resolve("https://matrix.to/#/%23design:example.org", validate: session.validate)
        }
        #expect(client.aliases.all.isEmpty && client.previews.all.isEmpty)
    }

    @Test(
        "A link that did not come through the parser is still checked before any request",
        arguments: [
            MatrixEntity(id: .roomAlias(alias: "#design:example.org"), via: ["https://evil.example"]),
            MatrixEntity(id: .roomAlias(alias: "#des\nign:example.org"), via: []),
            MatrixEntity(id: .room(id: "!" + String(repeating: "a", count: 2_048)), via: []),
        ])
    func validatesUnparsedEntity(entity: MatrixEntity) async {
        await #expect(throws: MatrixLinkError.invalidLink) { try await resolve(entity) }
        #expect(client.aliases.all.isEmpty && client.previews.all.isEmpty)
    }

    @Test("A room ID of exactly 2,048 bytes is accepted")
    func longestRoomID() async throws {
        let id = "!" + String(repeating: "a", count: 2_047)
        let resolution = try await resolve(MatrixEntity(id: .room(id: id), via: []))
        guard case .join(let request) = resolution.destination else {
            Issue.record("expected a join confirmation")
            return
        }
        #expect(request.roomID == id)
    }

    @Test("A link may carry up to 32 routing hints", arguments: [(32, true), (33, false)])
    func routingHintLimit(count: Int, accepted: Bool) throws {
        let via = (1...count).map { "via=s\($0).example.org" }.joined(separator: "&")
        let url = try #require(URL(string: "https://matrix.to/#/!room:example.org?" + via))
        if accepted {
            #expect(try MatrixLinkService.parse(url)?.via.count == count)
        } else {
            #expect(throws: MatrixLinkError.invalidLink) { try MatrixLinkService.parse(url) }
        }
    }

    @Test(
        "Switching accounts while a joined room's details load sends no preview request",
        arguments: [false, true])
    func staleWhileLoadingDetails(detailsFail: Bool) async throws {
        let room = LinkRoom("!room:example.org")
        room.stateReady = false
        room.infoFails = detailsFail
        room.infoGate.arm()
        client.add(room)
        let session = Session()
        let pending = Task { try await resolve("https://matrix.to/#/!room:example.org", validate: session.validate) }
        #expect(await eventually { room.infoGate.isWaiting })
        session.current = false
        room.infoGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(client.previews.all.isEmpty)
    }

    @Test("A link to a room you are banned from is refused without a preview or join")
    func bannedRoom() async {
        let room = LinkRoom("!room:example.org")
        room.state = .banned
        client.add(room)
        await #expect(throws: MatrixLinkError.banned) { try await resolve("https://matrix.to/#/!room:example.org") }
        #expect(client.previews.all.isEmpty && client.joins.all.isEmpty)
    }

    @Test("A join confirmed after the session ended sends nothing")
    func staleBeforeJoin() async {
        let session = Session()
        session.current = false
        await #expect(throws: CancellationError.self) { try await join(direct, validate: session.validate) }
        #expect(client.joins.all.isEmpty)
    }

    @Test("A join request whose message ID is malformed is refused before joining", arguments: ["event", "$ev\nent"])
    func malformedJoinEvent(eventID: String) async {
        let request = MatrixRoomJoinRequest(
            accountID: client.ownID, sessionID: session, address: "!direct:example.org",
            roomID: "!direct:example.org", via: [], eventID: eventID)
        await #expect(throws: MatrixLinkError.invalidLink) { try await join(request) }
        #expect(client.joins.all.isEmpty)
    }

    @Test(
        "Joining a Space from a message link warns that the message cannot open; a room does not",
        arguments: [(true, true), (false, false)])
    func workspaceEventWarning(isSpace: Bool, warns: Bool) async throws {
        let request = MatrixRoomJoinRequest(
            accountID: client.ownID, sessionID: session, address: "!direct:example.org",
            roomID: "!direct:example.org", via: [], eventID: "$event", isSpaceHint: isSpace)
        let joined = try await join(request)
        #expect(joined.isSpace == isSpace && (joined.warning != nil) == warns)
    }
}
