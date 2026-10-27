import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct HomeserverAndSessionTests {
    @Test("A bare homeserver name becomes an https URL without a trailing slash")
    func normalizesHomeserver() throws {
        #expect(try MatrixService.validatedHomeserver("example.org/") == "https://example.org")
    }

    @Test(
        "Homeserver URLs with credentials, plain http, a query or a fragment are refused",
        arguments: [
            "https://user:password@example.org", "http://example.org", "https://example.org/?access_token=secret",
            "https://example.org/#fragment",
        ])
    func rejectsUnsafeHomeserver(url: String) {
        #expect(throws: MatrixServiceError.self) { try MatrixService.validatedHomeserver(url) }
    }

    @Test("Error text shown to the user never contains tokens or passwords from the underlying error")
    func safeErrorRedacts() {
        let raw = NSError(
            domain: "Authorization: Bearer private-token", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "password=private-password"])
        let shown = MatrixService.safeError(raw)
        #expect(!shown.contains("private-token") && !shown.contains("private-password"))
    }

    @Test(
        "Only an unknown-token error ends the local session; network and permission errors keep it",
        arguments: [
            (
                ClientError.MatrixApi(
                    kind: .unknownToken(softLogout: false), code: "M_UNKNOWN_TOKEN", msg: "", details: nil), true
            ),
            (.MatrixApi(kind: .unknownToken(softLogout: true), code: "M_UNKNOWN_TOKEN", msg: "", details: nil), true),
            (.Generic(msg: "network connection failed", details: nil), false),
            (.MatrixApi(kind: .forbidden, code: "M_FORBIDDEN", msg: "forbidden", details: nil), false),
        ])
    func revokedSession(error: ClientError, revoked: Bool) {
        #expect(MatrixService.isRevokedSession(error) == revoked)
    }

    @Test("A stored session keeps its 256-bit store key through encoding and refuses a short key")
    func storeKey() throws {
        let key = try SecureSessionStore.generateStoreKey()
        #expect(key.count == 32)
        func session(_ key: Data) -> StoredSession {
            StoredSession(
                accessToken: "token", userId: "@alice:example.org", deviceId: "DEVICE",
                homeserverUrl: "https://example.org", storeID: UUID().uuidString, storeKey: key)
        }
        try session(key).validate()
        let decoded = try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(session(key)))
        #expect(decoded.storeKey == key)
        #expect(throws: (any Error).self) { try session(Data(repeating: 0, count: 31)).validate() }
    }
}

@MainActor
struct MatrixServiceGuardTests {
    let service = MatrixService()

    private func failure(_ operation: () async throws -> Void) async -> String {
        do { try await operation() } catch { return error.localizedDescription }
        return "no error"
    }

    @Test("Text and files queued for a room are refused once another room is selected")
    func wrongRoomSend() async {
        service.selectedRoomID = "!current:example.org"
        #expect(
            await failure { try await service.sendMessage("x", roomID: "!original:example.org") }.contains(
                "switched conversations"))
        #expect(
            await failure {
                try await service.uploadFile(
                    URL(fileURLWithPath: "/nonexistent/fixture"), roomID: "!original:example.org")
            }.contains("switched conversations"))
    }

    @Test("The local preview cannot send anything")
    func previewCannotSend() async {
        service.isPreview = true
        #expect(await failure { try await service.sendMessage("x") }.contains("local preview"))
        #expect(service.messages.isEmpty)
    }

    @Test("Selecting a room returns to its latest messages")
    func selectingClearsFocus() async {
        service.focusedEventID = "$older"
        await service.selectRoom("!room:example.org")
        #expect(service.focusedEventID == nil)
    }

    @Test("Jumping to a message that only has a local transaction ID stays put and says why")
    func jumpToLocalEcho() async {
        service.selectedRoomID = "!room:example.org"
        await service.jumpToMessage(roomID: "!other:example.org", eventID: "local-transaction")
        #expect(service.selectedRoomID == "!room:example.org" && service.errorMessage != nil)
    }

    @Test("Cancelling a search clears its results")
    func cancelSearchClears() {
        service.searchResults = [
            ChatMessage(
                id: "$hit", roomID: "!room:example.org", senderID: "@a:example.org", senderName: "A", body: "x",
                timestamp: .distantPast)
        ]
        service.searchState = "ready"
        service.searchHasMore = true
        service.cancelSearch()
        #expect(service.searchResults.isEmpty && service.searchState == "idle" && !service.searchHasMore)
    }

    @Test("Searching while signed out fails with a sign-in message")
    func signedOutSearch() async {
        #expect(await failure { try await service.searchMessages(query: "x") }.contains("Sign in"))
        #expect(service.searchState == "error" && service.searchErrorMessage != nil)
    }

    @Test("Without a session, a row cannot capture a message action")
    func signedOutCapture() {
        let message = ChatMessage(
            id: "$event", roomID: "!room:example.org", senderID: "@a:example.org", senderName: "A", body: "x",
            timestamp: .distantPast)
        service.selectedRoomID = message.roomID
        service.messages = [message]
        #expect(service.captureMessageAction(message: message, surface: .conversation) == nil)
    }

    @Test("A saved message preview needs a session and never moves the open conversation")
    func savedPreviewSignedOut() async {
        service.selectedRoomID = "!active:example.org"
        service.focusedEventID = "$active"
        await #expect(throws: MatrixServiceError.self) {
            _ = try await service.messagePreview(roomID: "!saved:example.org", eventID: "$saved")
        }
        #expect(service.selectedRoomID == "!active:example.org" && service.focusedEventID == "$active")
    }
}
