import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class TypingRoom: Room, @unchecked Sendable {
    let gate = Gate()
    let notices = Recorder<Bool>()
    var joined = true
    var failTyping = false
    override func membership() -> Membership { joined ? .joined : .left }
    override func typingNotice(isTyping: Bool) async throws {
        notices.append(isTyping)
        await gate.wait()
        if failTyping { throw MatrixServiceError.request("typing request failed") }
    }
}

private final class RoomsClient: Client, @unchecked Sendable {
    var roomsByID: [String: Room] = [:]
    override func getRoom(roomId: String) throws -> Room? { roomsByID[roomId] }
}

private final class SendTimeline: Timeline, @unchecked Sendable {
    let sends = Recorder<String>()
    var failEnqueue = false
    override func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        sends.append("send")
        if failEnqueue { throw MatrixServiceError.request("enqueue failed") }
        return SendHandle(noHandle: .init())
    }
    override func sendReply(msg: RoomMessageEventContentWithoutRelation, eventId: String) async throws -> SendHandle {
        sends.append("reply:\(eventId)")
        if failEnqueue { throw MatrixServiceError.request("enqueue failed") }
        return SendHandle(noHandle: .init())
    }
    let attachments = Recorder<AttachmentKind>()
    override func sendAttachment(params: UploadParameters, attachment: AttachmentKind) throws
        -> SendAttachmentJoinHandle
    {
        attachments.append(attachment)
        return SentAttachment(noHandle: .init())
    }
}

private final class SentAttachment: SendAttachmentJoinHandle, @unchecked Sendable {
    override func join() async throws {}
}

private let roomID = "!original:example.org"
private let otherID = "!other:example.org"

@MainActor
struct ComposerSendTests {
    private let service = MatrixService()
    private let client = RoomsClient(noHandle: .init())
    private let room = TypingRoom(noHandle: .init())
    private let otherRoom = TypingRoom(noHandle: .init())
    private let main = SendTimeline(noHandle: .init())
    private let thread = SendTimeline(noHandle: .init())
    private let session = UUID()

    init() {
        client.roomsByID = [roomID: room, otherID: otherRoom]
        service.user = ChatUser(id: "@sender:example.org", name: "Sender")
        service.selectedRoomID = roomID
        service.rooms = [ChatRoom(id: roomID, name: "Send")]
        configure(session)
    }

    private func configure(_ session: UUID) {
        service.configureMessageActionsForChecks(
            client: client, main: main, thread: thread, rootID: "$root", sessionID: session, selectionID: UUID(),
            threadID: UUID())
    }

    // capability: composer.send
    // capability: message.reply
    // capability: thread.reply
    @Test(
        "A sent message goes to its pane as one plain send or quoted reply, with no typing request",
        arguments: [false, true], [false, true])
    func sendsOnceInItsPane(threaded: Bool, quoted: Bool) async throws {
        try await service.sendMessage(
            "Accepted text", threadRootID: threaded ? "$root" : nil, replyToID: quoted ? "$quoted" : nil,
            roomID: roomID)
        #expect((threaded ? thread : main).sends.all == [quoted ? "reply:$quoted" : "send"])
        #expect((threaded ? main : thread).sends.all.isEmpty)
        #expect(room.notices.all.isEmpty && service.errorMessage == nil)
    }

    // capability: composer.attachments
    @Test(
        "An uploaded image carries its size as it displays, so every client reserves its shape before it loads",
        arguments: [(1, 160, 90), (6, 90, 160)])
    func uploadedImageSize(orientation: Int, width: UInt64, height: UInt64) async throws {
        let scratch = try TemporaryDirectory()
        let photo = try scratch.png("photo.png", width: 160, height: 90, orientation: orientation)
        try await service.uploadFile(photo, roomID: roomID)
        guard case .image(let info, _) = try #require(main.attachments.all.first) else {
            Issue.record("not sent as an image")
            return
        }
        #expect(info.width == width && info.height == height)
    }

    @Test("A send the SDK refuses to queue fails without being retried", arguments: [false, true])
    func enqueueFailure(threaded: Bool) async {
        let target = threaded ? thread : main
        target.failEnqueue = true
        await #expect(throws: MatrixServiceError.self) {
            try await service.sendMessage("Keep this draft", threadRootID: threaded ? "$root" : nil, roomID: roomID)
        }
        #expect(target.sends.all == ["send"])
        #expect(room.notices.all.isEmpty)
    }

    // capability: composer.typing
    @Test("Typing is announced in the selected room")
    func typingInSelectedRoom() async {
        await service.setTyping(true, roomID: roomID, sessionID: session)
        #expect(room.notices.all == [true])
    }

    @Test("After switching rooms, the old composer can stop typing in its room but not start again")
    func oldRoomAfterNavigation() async {
        service.selectedRoomID = otherID
        await service.setTyping(true, roomID: roomID, sessionID: session)
        #expect(room.notices.all.isEmpty)
        await service.setTyping(false, roomID: roomID, sessionID: session)
        #expect(room.notices.all == [false] && otherRoom.notices.all.isEmpty)
    }

    @Test("Typing from an earlier session reaches no room")
    func earlierSession() async {
        await service.setTyping(true, roomID: roomID, sessionID: UUID())
        #expect(room.notices.all.isEmpty)
    }

    @Test("The local preview and a room I left get no typing requests")
    func previewAndLeftRoom() async {
        service.isPreview = true
        await service.setTyping(true, roomID: roomID, sessionID: session)
        service.isPreview = false
        room.joined = false
        await service.setTyping(true, roomID: roomID, sessionID: session)
        #expect(room.notices.all.isEmpty)
    }

    @Test("A cancelled typing update sends nothing")
    func cancelledTyping() async {
        let pending = Task { await service.setTyping(true, roomID: roomID, sessionID: session) }
        pending.cancel()
        await pending.value
        #expect(room.notices.all.isEmpty)
    }

    @Test("A typing failure in the current room is shown")
    func currentFailureShown() async {
        room.failTyping = true
        await service.setTyping(true, roomID: roomID, sessionID: session)
        #expect(service.errorMessage == "typing request failed")
    }

    enum Change: CaseIterable { case room, session, cancellation }

    @Test(
        "A typing failure that lands after the room, session or task changed leaves the current screen's error alone",
        arguments: Change.allCases)
    func lateFailureIgnored(change: Change) async {
        room.failTyping = true
        room.gate.arm()
        let captured = session
        let pending = Task { await service.setTyping(false, roomID: roomID, sessionID: captured) }
        #expect(await eventually { room.gate.isWaiting })
        switch change {
        case .room: service.selectedRoomID = otherID
        case .session: configure(UUID())
        case .cancellation: pending.cancel()
        }
        service.errorMessage = "Keep the current screen's error"
        room.gate.release()
        await pending.value
        #expect(service.errorMessage == "Keep the current screen's error")
        #expect(room.notices.all == [false] && otherRoom.notices.all.isEmpty)
    }
}
