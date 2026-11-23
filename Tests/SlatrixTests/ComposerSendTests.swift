import Foundation
import ImageIO
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class TypingRoom: Room, @unchecked Sendable {
    let gate = Gate()
    let notices = Recorder<Bool>()
    let sendQueueHandles = Recorder<FakeCancellableHandle>()
    var onSubscribeSendQueue: (@Sendable () async -> Void)?
    var joined = true
    var failTyping = false
    override func membership() -> Membership { joined ? .joined : .left }
    override func typingNotice(isTyping: Bool) async throws {
        notices.append(isTyping)
        await gate.wait()
        if failTyping { throw MatrixServiceError.request("typing request failed") }
    }
    override func subscribeToSendQueueUpdates(listener: SendQueueListener) async throws -> TaskHandle {
        if let onSubscribeSendQueue { await onSubscribeSendQueue() }
        let handle = FakeCancellableHandle(noHandle: .init())
        sendQueueHandles.append(handle)
        return handle
    }
}

private final class RoomsClient: Client, @unchecked Sendable {
    var roomsByID: [String: Room] = [:]
    override func getRoom(roomId: String) throws -> Room? { roomsByID[roomId] }
    override func session() throws -> Session { throw URLError(.userAuthenticationRequired) }
}

private final class SendTimeline: Timeline, @unchecked Sendable {
    let sends = Recorder<String>()
    var failEnqueue = false
    override func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        sends.append("send")
        if failEnqueue { throw MatrixServiceError.request("enqueue failed") }
        return FakeSendHandle("tx-send")
    }
    override func sendReply(msg: RoomMessageEventContentWithoutRelation, eventId: String) async throws -> SendHandle {
        sends.append("reply:\(eventId)")
        if failEnqueue { throw MatrixServiceError.request("enqueue failed") }
        return FakeSendHandle("tx-reply")
    }
    let attachments = Recorder<AttachmentKind>()
    /// A video's poster as it is when it goes up; the upload removes it after.
    let posters = Recorder<Data>()
    var failAttachmentEnqueue = false
    var failAttachmentJoin = false
    var attachmentJoinError: Error?
    override func sendAttachment(params: UploadParameters, attachment: AttachmentKind) throws
        -> SendAttachmentJoinHandle
    {
        attachments.append(attachment)
        if failAttachmentEnqueue { throw MatrixServiceError.request("Unreadable attachment") }
        if case .video(_, .file(let path)?) = attachment, let poster = FileManager.default.contents(atPath: path) {
            posters.append(poster)
        }
        let error =
            attachmentJoinError ?? (failAttachmentJoin ? MatrixServiceError.request("upload queue failed") : nil)
        return SentAttachment(joinError: error)
    }
}

private final class SentAttachment: SendAttachmentJoinHandle, @unchecked Sendable {
    let joinError: Error?
    init(joinError: Error? = nil) {
        self.joinError = joinError
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func join() async throws {
        if let joinError { throw joinError }
    }
}

private let roomID = "!original:example.org"
private let otherID = "!other:example.org"

@MainActor
struct ComposerSendTests {
    private let service = MatrixService.scratch()
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
        service.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
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

    // capability: composer.video
    @Test("An uploaded video carries its upright size, its length and a poster from a second in, as Slack's do")
    func uploadedVideo() async throws {
        let scratch = try TemporaryDirectory()
        // Two seconds of 320×180 frames, red on the left and blue on the right, stored on their side and turned a
        // quarter by the track, as a phone records upright. A copy, since the upload takes the file it's given.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phone-video.mov")
        let clip = try scratch.file("clip.mov", Data(contentsOf: fixture))
        try await service.uploadFile(clip, roomID: roomID)
        guard case .video(let info, .file(let path)?) = try #require(main.attachments.all.first) else {
            Issue.record("not sent as a video with a poster")
            return
        }
        #expect(info.width == 180 && info.height == 320 && info.mimetype == "video/quicktime")
        #expect(abs((info.duration ?? 0) - 2) < 0.2)
        let poster = try #require(main.posters.all.first)
        let thumbnail = try #require(info.thumbnailInfo)
        #expect(thumbnail.width == 180 && thumbnail.height == 320 && thumbnail.mimetype == "image/jpeg")
        #expect(thumbnail.size == UInt64(poster.count))
        let image = try #require(
            CGImageSourceCreateWithData(poster as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 180 && image.height == 320)
        // Turned upright, not stretched: the stored left and right halves are now its top and bottom.
        #expect(Self.redder(image, x: 90, y: 40) != Self.redder(image, x: 90, y: 280))
        #expect(Self.redder(image, x: 20, y: 40) == Self.redder(image, x: 160, y: 40))
        #expect(!FileManager.default.fileExists(atPath: path), "The poster goes once the video is up")
    }

    private static func redder(_ image: CGImage, x: Int, y: Int) -> Bool {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        let pixel = context.data!.assumingMemoryBound(to: UInt8.self)
        return pixel[0] > pixel[2]
    }

    @Test("A file for a thread closed before it was queued fails instead of going to another conversation")
    func fileForClosedThread() async throws {
        let scratch = try TemporaryDirectory()
        // Another thread of the room opened while this file was being prepared.
        service.configureMessageActionsForChecks(
            client: client, main: main, thread: thread, rootID: "$other", sessionID: session, selectionID: UUID(),
            threadID: UUID())
        await #expect(throws: MatrixServiceError.self) {
            try await service.uploadFile(try scratch.file("notes.txt"), threadRootID: "$root", roomID: roomID)
        }
        #expect(main.attachments.all.isEmpty && thread.attachments.all.isEmpty)
    }

    @Test("An attachment failure during handle.join throws AttachmentDeliveryError and does not bump sends")
    func attachmentJoinFailureDoesNotBumpSends() async throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.file("notes.txt", Data("hello".utf8))
        main.failAttachmentJoin = true
        await #expect(throws: AttachmentDeliveryError.self) {
            try await service.uploadFile(file, roomID: roomID)
        }
        #expect(service.sends[Conversation(roomID: roomID, threadRootID: nil)] == nil)
    }

    @Test("A pre-enqueue sendAttachment failure is not wrapped in AttachmentDeliveryError")
    func preEnqueueAttachmentFailureIsNotDeliveryError() async throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.file("notes.txt", Data("hello".utf8))
        main.failAttachmentEnqueue = true
        do {
            try await service.uploadFile(file, roomID: roomID)
            Issue.record("Expected pre-enqueue failure to throw")
        } catch is AttachmentDeliveryError {
            Issue.record("Pre-enqueue failure must not trigger AttachmentDeliveryError ('Send anyway')")
        } catch let error as MatrixServiceError {
            #expect(error.localizedDescription == "Unreadable attachment")
        }
    }

    @Test("Session expiry while awaiting SentEcho refuses enqueueing and cancels the echo subscription")
    func sendMessageRefusesEnqueueIfSessionExpiresDuringSentEcho() async {
        room.onSubscribeSendQueue = { [service] in
            await MainActor.run { service.expireSessionForChecks() }
        }
        do {
            try await service.sendMessage(
                "Do not enqueue after expiry", threadRootID: "$root", roomID: roomID, alsoToChannel: true)
            Issue.record("Expected expired session to refuse send after SentEcho subscription")
        } catch let error as MatrixServiceError {
            #expect(error.localizedDescription.contains("expired"))
        } catch {
            Issue.record("Expected MatrixServiceError, got \(error)")
        }
        #expect(thread.sends.all.isEmpty && main.sends.all.isEmpty)
        #expect(room.sendQueueHandles.all.first?.isCancelled == true)
    }

    @Test("Session expiry during video preparation refuses enqueueing and cleans up the poster file")
    func uploadFileRefusesEnqueueIfSessionExpiresDuringVideoPrepare() async throws {
        let scratch = try TemporaryDirectory()
        let clip = try scratch.file("clip.mov", Data("fake-video".utf8))
        let poster = try scratch.file("poster.jpg", Data("jpeg".utf8))
        let prepareGate = Gate()
        prepareGate.arm()
        service.prepareVideo = { _, mimetype, size in
            await prepareGate.wait()
            return (
                VideoUpload.info(mimetype: mimetype, size: size, shown: nil, durationMillis: nil, poster: nil), poster
            )
        }

        let uploading = Task { try await service.uploadFile(clip, roomID: roomID) }
        #expect(await eventually { prepareGate.isWaiting })
        service.expireSessionForChecks()
        prepareGate.release()

        do {
            try await uploading.value
            Issue.record("Expected expired session to refuse video upload after prepare")
        } catch let error as MatrixServiceError {
            #expect(error.localizedDescription.contains("expired"))
        } catch {
            Issue.record("Expected MatrixServiceError, got \(error)")
        }
        #expect(main.attachments.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: poster.path))
    }

    @Test("An unreadable staged attachment fails before sendAttachment without AttachmentDeliveryError")
    func unreadableAttachmentFailsBeforeSendAttachment() async throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.file("secret.txt", Data("hello".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        do {
            try await service.uploadFile(file, roomID: roomID)
            Issue.record("Expected unreadable file to throw before sendAttachment")
        } catch is AttachmentDeliveryError {
            Issue.record("Unreadable file must fail before queueing without AttachmentDeliveryError")
        } catch {
            // Expected local file-read error.
        }
        #expect(main.attachments.all.isEmpty)
    }

    @Test("Unambiguous pre-enqueue RoomError from join is not wrapped in AttachmentDeliveryError")
    func preEnqueueRoomErrorFromJoinIsNotDeliveryError() async throws {
        let scratch = try TemporaryDirectory()
        let file = try scratch.file("notes.txt", Data("hello".utf8))
        main.attachmentJoinError = RoomError.InvalidAttachmentData(message: "ENOENT")
        do {
            try await service.uploadFile(file, roomID: roomID)
            Issue.record("Expected InvalidAttachmentData to throw")
        } catch is AttachmentDeliveryError {
            Issue.record("InvalidAttachmentData is a pre-enqueue error and must not become AttachmentDeliveryError")
        } catch let error as RoomError {
            #expect(error == .InvalidAttachmentData(message: "ENOENT"))
        }

        main.attachmentJoinError = RoomError.FailedSendingAttachment(message: "timeout")
        await #expect(throws: AttachmentDeliveryError.self) {
            try await service.uploadFile(file, roomID: roomID)
        }
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

    @Test(
        "Typing notices are skipped whenever the connection is not running",
        arguments: [MatrixConnectionState.idle, .connecting, .offline, .stopped, .failed])
    func typingSkippedWhenNotRunning(state: MatrixConnectionState) async {
        service.applyConnection(
            MatrixConnectionFeedback(state: state, isRetrying: false, canRetry: true, errorMessage: nil))
        await service.setTyping(true, roomID: roomID, sessionID: session)
        #expect(room.notices.all.isEmpty && service.errorMessage == nil)
    }

    @Test("A typing failure never writes to the conversation error banner")
    func typingFailureNeverSetsErrorBanner() async {
        room.failTyping = true
        await service.setTyping(true, roomID: roomID, sessionID: session)
        #expect(room.notices.all == [true] && service.errorMessage == nil)
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
