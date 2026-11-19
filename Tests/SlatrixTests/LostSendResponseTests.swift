import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class DeliveryTimeline: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimelineItem] = []
    let roomID: String

    init(roomID: String) { self.roomID = roomID }

    func onUpdate(diff: [TimelineDiff]) { _ = lock.withLock { items.apply(diff.map(\.change)) } }

    var shown: [TimelineItem] { lock.withLock { items } }

    var messages: [ChatMessage] {
        lock.withLock {
            items.compactMap { item in
                item.asEvent().flatMap { MatrixMapping.message($0, roomID: roomID, ownUserID: nil) }
            }
        }
    }
}

/// A client of `server` signed in as `user`, keeping its stores in `scratch`.
@MainActor
private func signIn(_ user: String, to server: FakeHomeserver, in scratch: TemporaryDirectory) async throws -> Client {
    let client = try await ClientBuilder().homeserverUrl(url: server.url).sessionPaths(
        dataPath: scratch.path("\(user)-data").path, cachePath: scratch.path("\(user)-cache").path
    ).build()
    try await client.restoreSession(
        session: Session(
            accessToken: user, refreshToken: nil, userId: "@\(user):localhost", deviceId: user.uppercased(),
            homeserverUrl: server.url, oauthData: nil, slidingSyncVersion: .native))
    return client
}

@MainActor
struct LostSendResponseTests {
    @Test("Losing the reply after a send commits leaves one delivered copy and the following message gets through")
    func lostResponse() async throws {
        let server = try await FakeHomeserver(room: "!room:localhost", messages: [], dropFirstSendResponse: true)
        let scratch = try TemporaryDirectory()
        let sender = try await signIn("me", to: server, in: scratch)
        let senderTimeline = try await sender.joinRoomById(roomId: server.room).timeline()
        let sent = DeliveryTimeline(roomID: server.room)
        let senderHandle = await senderTimeline.addListener(listener: sent)
        defer { senderHandle.cancel() }
        let app = MatrixService()
        app.configureMessageActionsForChecks(
            client: sender, main: senderTimeline, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        app.selectedRoomID = server.room
        try await app.sendMessage("first", roomID: server.room)
        try await app.sendMessage("second", roomID: server.room)
        try #require(
            await eventually(timeout: .seconds(15)) {
                sent.messages.contains { $0.body == "second" && $0.sendState == "sent" }
            }, "Sender states: \(sent.messages.map { "\($0.body) \($0.sendState)" })")
        #expect(sent.messages.map(\.body) == ["first", "second"])
        #expect(sent.messages.map(\.sendState) == ["sent", "sent"])
        #expect(server.retriedDroppedSend)

        let recipient = try await signIn("reader", to: server, in: scratch)
        let recipientTimeline = try await recipient.joinRoomById(roomId: server.room).timeline()
        let received = DeliveryTimeline(roomID: server.room)
        let recipientHandle = await recipientTimeline.addListener(listener: received)
        defer { recipientHandle.cancel() }
        _ = try await recipientTimeline.paginateBackwards(numEvents: 20)
        try #require(await eventually { received.messages.contains { $0.body == "second" } })
        #expect(received.messages.map(\.body) == ["first", "second"])
        #expect(received.messages.map(\.eventID) == sent.messages.map(\.eventID))
    }

    // capability: message.delete
    @Test("A deletion the server refuses brings the message back and holds up nothing sent after it")
    func refusedDeletion() async throws {
        let server = try await FakeHomeserver(room: "!room:localhost", messages: [], refusesDeletions: true)
        let scratch = try TemporaryDirectory()
        let sender = try await signIn("me", to: server, in: scratch)
        let timeline = try await sender.joinRoomById(roomId: server.room).timeline()
        let shown = DeliveryTimeline(roomID: server.room)
        let handle = await timeline.addListener(listener: shown)
        defer { handle.cancel() }
        let app = MatrixService()
        app.configureMessageActionsForChecks(
            client: sender, main: timeline, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        app.selectedRoomID = server.room
        try await app.sendMessage("first", roomID: server.room)
        try #require(
            await eventually(timeout: .seconds(15)) {
                shown.messages.contains { $0.body == "first" && $0.sendState == "sent" }
            })

        try await timeline.redactEvent(eventOrTransactionId: .eventId(eventId: "$message-1"), reason: nil)
        // The app shows the timeline as it changes.
        #expect(
            await eventually(timeout: .seconds(15)) {
                app.projectMediaCaptionForChecks(shown.shown, roomID: server.room, inThread: false)
                return app.errorMessage == "Couldn’t delete this message."
            })
        try await app.sendMessage("second", roomID: server.room)
        #expect(
            await eventually(timeout: .seconds(15)) {
                shown.messages.contains { $0.body == "second" && $0.sendState == "sent" }
            }, "Sender states: \(shown.messages.map { "\($0.body) \($0.sendState) \($0.isRedacted)" })")
        #expect(shown.messages.map(\.body) == ["first", "second"])
    }
}
