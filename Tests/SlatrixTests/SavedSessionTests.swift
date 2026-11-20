import Foundation
import Testing

@testable import Slatrix

/// The saved session and vault keys, each test's in a file of its own.
@MainActor
struct SavedSessionTests {
    private let folder: TemporaryDirectory
    private let credentials: SecureSessionStore
    private let session = StoredSession(
        accessToken: "synthetic-token", userId: "@owner:example.org", deviceId: "FIXTURE",
        homeserverUrl: "https://example.org", storeID: UUID().uuidString, storeKey: Data(repeating: 0x31, count: 32))

    init() throws {
        folder = try TemporaryDirectory()
        credentials = SecureSessionStore(file: folder.path("credentials.json"))
    }

    @Test("Leaving the sample workspace runs none of sign-out, whatever a failed start left installed")
    func leavingPreview() async throws {
        try credentials.save(session)
        let client = FakeClient()
        let matrix = MatrixService(credentials: credentials)
        matrix.configureRoomOpenForChecks(
            client: client, roomList: FakeRoomListService(), user: ChatUser(id: session.userId, name: "Owner"))
        matrix.enterPreview()
        try await matrix.logout()
        #expect(!client.loggedOut)
        #expect(try credentials.load() == session)
        #expect(matrix.status == .signedOut && matrix.user == nil && !matrix.isPreview)
    }

    struct Damaged: CustomTestStringConvertible, Sendable {
        var name: String
        var record: String
        var kept: [String: Data]
        var testDescription: String { name }

        static let key = Data(repeating: 0x42, count: 32)
        static let all = [
            Damaged(name: "Cut short", record: #"{"version":1,"vaultKeys":{"@keep:exa"#, kept: [:]),
            Damaged(
                name: "A bad session and bad keys beside a good one",
                record: """
                    {"version":1,"session":{"userId":"nobody"},"vaultKeys":{"@keep:example.org":"\(key.base64EncodedString())",\
                    "@short:example.org":"QkJC","not an account":"\(key.base64EncodedString())"}}
                    """,
                kept: ["@keep:example.org": key]),
        ]
    }

    private func savedKeys() throws -> [String: Data] {
        try SecureSessionStore.decodeEnvelope(Data(contentsOf: folder.path("credentials.json"))).vaultKeys
    }

    @Test("Signing in over a damaged saved record keeps every vault key that still reads", arguments: Damaged.all)
    func signInOverDamaged(_ damaged: Damaged) throws {
        _ = try folder.file("credentials.json", Data(damaged.record.utf8))
        try credentials.save(session)
        #expect(try credentials.load() == session)
        #expect(try savedKeys() == damaged.kept)
    }

    @Test(
        "Finishing sign-out over a damaged saved record keeps every vault key that still reads",
        arguments: Damaged.all)
    func finishSignOutOverDamaged(_ damaged: Damaged) throws {
        _ = try folder.file("credentials.json", Data(damaged.record.utf8))
        try credentials.delete()
        #expect(try credentials.load() == nil)
        #expect(try savedKeys() == damaged.kept)
    }

    @Test("A saved record from a newer build is never rewritten")
    func newerRecordKept() throws {
        let record = Data(#"{"version":2,"vaultKeys":{"@keep:example.org":"QkJC"}}"#.utf8)
        let file = try folder.file("credentials.json", record)
        #expect(throws: (any Error).self) { try credentials.save(session) }
        #expect(throws: (any Error).self) { try credentials.delete() }
        #expect(try Data(contentsOf: file) == record)
    }
}
