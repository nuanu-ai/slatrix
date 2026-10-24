import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class Members: RoomMembersIterator, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [RoomMember]
    init(_ members: [RoomMember]) {
        remaining = members
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func nextChunk(chunkSize: UInt32) -> [RoomMember]? {
        lock.withLock {
            guard !remaining.isEmpty else { return nil }
            defer { remaining = [] }
            return remaining
        }
    }
}

private final class DirectRoom: Room, @unchecked Sendable {
    let identifier: String
    let users: [RoomMember]
    var encryptionFails = false
    private let lock = NSLock()
    private var encrypted: Bool
    private var enabled = false
    var encryptionEnabled: Bool { lock.withLock { enabled } }
    init(_ id: String, members: [RoomMember], encrypted: Bool) {
        identifier = id
        users = members
        self.encrypted = encrypted
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func id() -> String { identifier }
    override func membership() -> Membership { .joined }
    override func isDirect() async -> Bool { true }
    override func members() async throws -> RoomMembersIterator { Members(users) }
    override func isEncrypted() async -> Bool { lock.withLock { encrypted } }
    override func enableEncryption() async throws {
        if encryptionFails { throw MatrixServiceError.request("encryption failed") }
        lock.withLock {
            enabled = true
            encrypted = true
        }
    }
}

private final class PeopleClient: Client, @unchecked Sendable {
    var joinedRooms: [Room] = []
    var directory = SearchUsersResults(results: [], limited: false)
    var unavailableProfiles = Set<String>()
    let searchGate = Gate()
    let profileGate = Gate()
    let createGate = Gate()
    let searches = Recorder<String>()
    let creations = Recorder<CreateRoomParameters>()
    override func userId() throws -> String { "@me:example.org" }
    override func rooms() -> [Room] { joinedRooms }
    override func getDmRooms(userId: String) throws -> [Room] { joinedRooms }
    override func getRoom(roomId: String) throws -> Room? { joinedRooms.first { $0.id() == roomId } }
    override func searchUsers(searchTerm: String, limit: UInt64) async throws -> SearchUsersResults {
        searches.append(searchTerm)
        if searchTerm == "new" {
            return SearchUsersResults(
                results: [
                    UserProfile(userId: "@new:example.org", displayName: "New", avatarUrl: nil, status: nil, call: nil)
                ],
                limited: false)
        }
        await searchGate.wait()
        return directory
    }
    override func getProfile(userId: String) async throws -> UserProfile {
        await profileGate.wait()
        if unavailableProfiles.contains(userId) { throw MatrixServiceError.request("profile unavailable") }
        return UserProfile(
            userId: userId, displayName: "Profile", avatarUrl: "mxc://example.org/avatar",
            status: UserStatus(emoji: "🌱", text: "Working"), call: nil)
    }
    override func isUserStatusSupported() async throws -> Bool { true }
    override func createRoom(request: CreateRoomParameters) async throws -> String {
        creations.append(request)
        await createGate.wait()
        return "!created:example.org"
    }
}

private func member(_ id: String, _ membership: MembershipState = .join, service: Bool = false) -> RoomMember {
    RoomMember(
        userId: id, displayName: nil, avatarUrl: nil, status: nil, call: nil, membership: membership,
        isNameAmbiguous: false, powerLevel: .value(value: 0), isIgnored: false, suggestedRoleForPowerLevel: .user,
        membershipChangeReason: nil, isServiceMember: service)
}

private let alice = "@alice:example.org"
private let me = "@me:example.org"

struct PeopleMappingTests {
    @Test("A Matrix ID typed with surrounding spaces is accepted")
    func trimsID() throws {
        #expect(try PeopleMapping.validatedID("  \(alice)  ") == alice)
    }

    @Test("A profile without a display name shows its ID, and status shows only where the server supports it")
    func profileMapping() {
        let value = UserProfile(
            userId: alice, displayName: nil, avatarUrl: nil, status: UserStatus(emoji: "🌱", text: "Working"), call: nil)
        #expect(PeopleMapping.profile(value, statusSupported: true).name == alice)
        #expect(PeopleMapping.profile(value, statusSupported: true).status == "🌱 Working")
        #expect(PeopleMapping.profile(value, statusSupported: false).status == nil)
    }

    @Test(
        "A DM is reused only when its active members are exactly me (joined) and the person",
        arguments: [
            ([member(me), member(alice, .invite)], true),
            ([member(me), member(alice), member("@bot:example.org", service: true)], false),
            ([member(me, .invite), member(alice)], false),
        ])
    func exactParticipants(members: [RoomMember], exact: Bool) {
        #expect(PeopleMapping.exactDirectParticipants(members, ownUserID: me, targetUserID: alice) == exact)
    }
}

@MainActor
struct PeopleSearchTests {
    private let client = PeopleClient(noHandle: .init())
    let people = PeopleService()
    init() { people.attach(client) }

    @Test("A query replaced while it is still debouncing never reaches the server")
    func debounceSkipsSupersededQuery() async {
        let discarded = Task { await people.search("discarded") }
        #expect(await eventually { people.searchState == "loading" })
        await people.search("new")
        await discarded.value
        #expect(client.searches.all == ["new"])
        #expect(people.results.map(\.id) == ["@new:example.org"])
    }

    @Test("A late directory answer for an old query cannot replace the new query's results")
    func lateResultIgnored() async {
        client.searchGate.arm()
        let old = Task { await people.search("old") }
        #expect(await eventually { client.searchGate.isWaiting })
        await people.search("new")
        client.searchGate.release()
        await old.value
        #expect(people.results.map(\.id) == ["@new:example.org"] && people.searchState == "ready")
    }

    @Test("A full Matrix ID is found even when the directory search is limited")
    func exactIDOutsideDirectory() async {
        client.directory = SearchUsersResults(results: [], limited: true)
        await people.search(alice)
        #expect(people.results.first?.id == alice && people.results.first?.name == "Profile")
        #expect(people.limited)
    }

    @Test("A full Matrix ID whose profile can't load stays a candidate, flagged as unavailable")
    func unavailableProfileCandidate() async {
        client.unavailableProfiles = [alice]
        await people.search(alice)
        #expect(people.results.first?.id == alice && people.results.first?.profileAvailable == false)
        #expect(people.searchState == "ready" && people.searchErrorMessage != nil)
        #expect(client.creations.all.isEmpty)
    }

    @Test("Opening a profile that can't load keeps the room member's name and creates nothing")
    func profileFallback() async {
        client.unavailableProfiles = [alice]
        await people.loadProfile(userID: alice, fallback: ChatUser(id: alice, name: "Room name"))
        #expect(people.profile?.name == "Room name" && people.profile?.profileAvailable == false)
        #expect(people.profileState == "error")
        #expect(client.creations.all.isEmpty)
    }

    @Test("Signing out discards a profile that arrives late")
    func detachRejectsLateProfile() async {
        client.profileGate.arm()
        let lookup = Task { await people.loadProfile(userID: alice) }
        #expect(await eventually { client.profileGate.isWaiting })
        people.attach(nil)
        client.profileGate.release()
        await lookup.value
        #expect(people.profile == nil && people.profileState == "idle" && !people.statusSupported)
    }
}

@MainActor
struct DirectRoomTests {
    private let client = PeopleClient(noHandle: .init())
    let people = PeopleService()
    let exact = [member(me), member(alice, .invite)]

    @Test("An existing encrypted DM is reused over a plaintext one, without encrypting or creating anything")
    func prefersEncryptedDM() async throws {
        let plaintext = DirectRoom("!a:example.org", members: exact, encrypted: false)
        client.joinedRooms = [plaintext, DirectRoom("!z:example.org", members: exact, encrypted: true)]
        people.attach(client)
        #expect(try await people.directRoom(userID: alice) == "!z:example.org")
        #expect(!plaintext.encryptionEnabled && client.creations.all.isEmpty)
    }

    @Test("A plaintext DM is encrypted before it is reused")
    func encryptsPlaintextDM() async throws {
        let plaintext = DirectRoom("!a:example.org", members: exact, encrypted: false)
        client.joinedRooms = [plaintext]
        people.attach(client)
        #expect(try await people.directRoom(userID: alice) == plaintext.id())
        #expect(plaintext.encryptionEnabled)
    }

    @Test("A plaintext DM that can't be encrypted is not reused")
    func failedEncryptionRejected() async {
        let plaintext = DirectRoom("!a:example.org", members: exact, encrypted: false)
        plaintext.encryptionFails = true
        client.joinedRooms = [plaintext]
        people.attach(client)
        await #expect(throws: MatrixServiceError.self) { _ = try await people.directRoom(userID: alice) }
    }

    @Test("A new DM is an encrypted, private, direct room inviting exactly the person")
    func newDMParameters() async throws {
        people.attach(client)
        #expect(try await people.directRoom(userID: alice) == "!created:example.org")
        let request = try #require(client.creations.all.first)
        #expect(request.isEncrypted && request.isDirect && request.visibility == .private && request.invite == [alice])
    }

    @Test("Concurrent and repeated Message actions create only one room while it syncs")
    func createsOnce() async throws {
        people.attach(client)
        client.createGate.arm()
        let first = Task { try await people.directRoom(userID: alice) }
        #expect(await eventually { client.createGate.isWaiting })
        let second = Task { try await people.directRoom(userID: alice) }
        client.createGate.release()
        #expect(try await first.value == "!created:example.org")
        #expect(try await second.value == "!created:example.org")
        #expect(try await people.directRoom(userID: alice) == "!created:example.org")
        #expect(client.creations.all.count == 1)
    }

    @Test("Message is refused after sign-out")
    func signedOut() async {
        people.attach(client)
        people.attach(nil)
        await #expect(throws: MatrixServiceError.self) { _ = try await people.directRoom(userID: alice) }
    }
}
