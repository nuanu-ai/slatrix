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
        let app = try await watching(sender, main: timeline, room: server.room)
        try await app.sendMessage("first", roomID: server.room)
        try #require(
            await eventually(timeout: .seconds(15)) {
                shown.messages.contains { $0.body == "first" && $0.sendState == "sent" }
            })

        try await timeline.redactEvent(eventOrTransactionId: .eventId(eventId: "$message-1"), reason: nil)
        #expect(await eventually(timeout: .seconds(15)) { app.errorMessage == "Couldn’t delete this message." })
        try await app.sendMessage("second", roomID: server.room)
        #expect(
            await eventually(timeout: .seconds(15)) {
                shown.messages.contains { $0.body == "second" && $0.sendState == "sent" }
            }, "Sender states: \(shown.messages.map { "\($0.body) \($0.sendState) \($0.isRedacted)" })")
        #expect(shown.messages.map(\.body) == ["first", "second"])
    }

    // capability: message.delete
    @Test(
        "A thread deletion refused after you left its thread or room holds up nothing sent there, and says nothing elsewhere",
        arguments: [false, true])
    func refusedAfterLeaving(leftRoom: Bool) async throws {
        let server = try await FakeHomeserver(
            room: "!room:localhost", messages: Self.thread, refusesDeletions: true, holdsDeletions: true)
        let scratch = try TemporaryDirectory()
        let sender = try await signIn("me", to: server, in: scratch)
        let room = try await sender.joinRoomById(roomId: server.room)
        let main = try await room.timeline()
        let app = try await watching(sender, main: main, room: server.room, threadRootID: "$root")
        let pane = try await room.timelineWithConfiguration(configuration: Self.everything)
        let shown = DeliveryTimeline(roomID: server.room)
        let handle = await pane.addListener(listener: shown)
        _ = try await pane.paginateBackwards(numEvents: 20)
        try #require(await eventually { shown.messages.contains { $0.eventID == "$reply" } })

        try await pane.redactEvent(eventOrTransactionId: .eventId(eventId: "$reply"), reason: nil)
        try #require(await eventually(timeout: .seconds(15)) { server.deletionsHeld == 1 })
        handle.cancel()
        if leftRoom { app.selectedRoomID = "!elsewhere:localhost" } else { app.setMessageActionThread(rootID: nil) }
        server.releaseDeletions()
        _ = try await main.send(msg: messageEventContentFromMarkdown(md: "second"))
        #expect(
            await eventually(timeout: .seconds(15)) { server.bodies.contains("second") }, "Server has \(server.bodies)")
        await drainMainActor()
        #expect(app.errorMessage == nil)
    }

    // capability: message.delete
    @Test("A deletion refused before a relaunch is cancelled at launch, and what was sent after it goes out")
    func refusedBeforeRelaunch() async throws {
        let server = try await FakeHomeserver(room: "!room:localhost", messages: Self.thread, refusesDeletions: true)
        let scratch = try TemporaryDirectory()
        do {
            let sender = try await signIn("me", to: server, in: scratch)
            let pane = try await sender.joinRoomById(roomId: server.room).timelineWithConfiguration(
                configuration: Self.everything)
            let shown = DeliveryTimeline(roomID: server.room)
            let handle = await pane.addListener(listener: shown)
            defer { handle.cancel() }
            _ = try await pane.paginateBackwards(numEvents: 20)
            try #require(await eventually { shown.messages.contains { $0.eventID == "$reply" } })
            try await pane.redactEvent(eventOrTransactionId: .eventId(eventId: "$reply"), reason: nil)
            _ = try await pane.send(msg: messageEventContentFromMarkdown(md: "second"))
            try #require(
                await eventually(timeout: .seconds(15)) {
                    shown.shown.contains {
                        guard case .sendingFailed(_, isRecoverable: false) = $0.asEvent()?.redactionSendState
                        else { return false }
                        return true
                    }
                })
        }

        let relaunched = try await signIn("me", to: server, in: scratch)
        let app = try await watching(relaunched, main: nil, room: server.room)
        #expect(
            await eventually(timeout: .seconds(15)) { server.bodies.contains("second") }, "Server has \(server.bodies)")
        withExtendedLifetime(app) {}
    }

    // capability: message.edit
    @Test("An edit of a thread reply the server refuses puts its text back, says so, and holds up nothing after it")
    func refusedEdit() async throws {
        let server = try await FakeHomeserver(room: "!room:localhost", messages: Self.thread, refusesEdits: true)
        let scratch = try TemporaryDirectory()
        let sender = try await signIn("me", to: server, in: scratch)
        let room = try await sender.joinRoomById(roomId: server.room)
        let pane = try await room.timelineWithConfiguration(configuration: Self.everything)
        let shown = DeliveryTimeline(roomID: server.room)
        let handle = await pane.addListener(listener: shown)
        defer { handle.cancel() }
        let app = try await watching(sender, main: pane, room: server.room, threadRootID: "$root")
        _ = try await pane.paginateBackwards(numEvents: 20)
        try #require(await eventually { shown.messages.contains { $0.eventID == "$reply" } })

        try await pane.edit(
            eventOrTransactionId: .eventId(eventId: "$reply"),
            newContent: .roomMessage(content: messageEventContentFromMarkdown(md: "Changed")))
        #expect(await eventually(timeout: .seconds(15)) { app.errorMessage == "Couldn’t edit this message." })
        #expect(shown.messages.first { $0.eventID == "$reply" }?.body == "Reply")
        _ = try await pane.send(msg: messageEventContentFromMarkdown(md: "second"))
        #expect(
            await eventually(timeout: .seconds(15)) { server.bodies.contains("second") }, "Server has \(server.bodies)")
    }

    /// The live timeline with thread replies in it.
    private static let everything = TimelineConfiguration(
        focus: .live(hideThreadedEvents: false), filter: .all, internalIdPrefix: nil, dateDividerMode: .daily,
        trackReadReceipts: .disabled, reportUtds: false)

    /// A thread of yours, newest first: its root and one reply.
    nonisolated private static var thread: [[String: Any]] {
        [
            [
                "type": "m.room.message", "event_id": "$reply", "sender": "@me:localhost", "origin_server_ts": 2,
                "content": [
                    "msgtype": "m.text", "body": "Reply",
                    "m.relates_to": [
                        "rel_type": "m.thread", "event_id": "$root", "is_falling_back": true,
                        "m.in_reply_to": ["event_id": "$root"],
                    ],
                ],
            ],
            [
                "type": "m.room.message", "event_id": "$root", "sender": "@me:localhost", "origin_server_ts": 1,
                "content": ["msgtype": "m.text", "body": "Root"],
            ],
        ]
    }

    /// The app signed in as `client`, with `room` open and, when `threadRootID` is given, that thread's pane.
    private func watching(_ client: Client, main: Timeline?, room: String, threadRootID: String? = nil) async throws
        -> MatrixService
    {
        let app = MatrixService()
        app.configureMessageActionsForChecks(
            client: client, main: main, thread: nil, rootID: threadRootID, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        app.selectedRoomID = room
        try await app.watchRefusedChangesForChecks()
        return app
    }
}
