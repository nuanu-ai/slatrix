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
}
