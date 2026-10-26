import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// A timeline that records every SDK write and read it receives. `gate` holds writes, `readGate` holds
/// `getEventTimelineItemByEventId`, and `paginationGate` holds the initial thread pagination.
final class ActionTimeline: Timeline, @unchecked Sendable {
    let writes = Recorder<String>()
    let reads = Recorder<String>()
    let gate = Gate()
    let readGate = Gate()
    let paginationGate = Gate()
    private let lock = NSLock()
    private var current: EventTimelineItem?
    private var failing = false
    private var failingPagination = false
    /// Runs after each read is released, before the read returns.
    var onRead: (@MainActor () -> Void)?

    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    var event: EventTimelineItem? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
    var failsWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    var failsPagination: Bool {
        get { lock.withLock { failingPagination } }
        set { lock.withLock { failingPagination = newValue } }
    }

    private func write(_ value: String) async throws {
        writes.append(value)
        await gate.wait()
        if failsWrites { throw MatrixServiceError.request("Fixture write failed") }
    }
    override func fetchDetailsForEvent(eventId: String) async throws { try await write("details:\(eventId)") }
    override func toggleReaction(itemId: EventOrTransactionId, key: String) async throws -> Bool {
        try await write("reaction:\(key):\(MatrixMapping.identifier(itemId))")
        return false
    }
    override func edit(eventOrTransactionId: EventOrTransactionId, newContent: EditedContent) async throws {
        guard case .roomMessage = newContent else { return try await write("edit-other") }
        try await write("edit:\(MatrixMapping.identifier(eventOrTransactionId))")
    }
    override func redactEvent(eventOrTransactionId: EventOrTransactionId, reason: String?) async throws {
        try await write("delete:\(MatrixMapping.identifier(eventOrTransactionId))")
    }
    override func send(msg: RoomMessageEventContentWithoutRelation) async throws -> SendHandle {
        try await write("send")
        return SendHandle(noHandle: .init())
    }
    override func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws {
        try await write("\(receiptType == .read ? "read" : "fully"):\(eventId)")
    }
    override func markAsRead(receiptType: ReceiptType) async throws { try await write("mark-read") }
    override func getEventTimelineItemByEventId(eventId: String) async throws -> EventTimelineItem {
        reads.append(eventId)
        await readGate.wait()
        await onRead?()
        guard let event else { throw MatrixServiceError.request("Fixture event unavailable") }
        return event
    }
    override func addListener(listener: TimelineListener) async -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        await paginationGate.wait()
        if failsPagination { throw MatrixServiceError.request("Fixture pagination failed") }
        return false
    }
}

final class ActionPowerLevels: RoomPowerLevels, @unchecked Sendable {
    var canSend = true
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func canOwnUserSendMessage(message: MessageLikeEventType) -> Bool { canSend && message == .roomMessage }
}

/// A joined room whose membership, permalinks, encryption and power levels the test controls.
final class ActionRoom: Room, @unchecked Sendable {
    let identifier: String
    /// What `timelineWithConfiguration` returns: a thread timeline or a forwarding destination.
    let timeline = ActionTimeline()
    let powers = ActionPowerLevels()
    let linkGate = Gate()
    let setupGate = Gate()
    let configurations = Recorder<TimelineConfiguration>()
    let linkRequests = Recorder<String>()
    private let lock = NSLock()
    private var isJoined = true
    var links: [String: String] = [:]
    var failsLinks = false
    var encryption: EncryptionState = .encrypted
    var failsEncryption = false

    init(id: String) {
        identifier = id
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    var joined: Bool {
        get { lock.withLock { isJoined } }
        set { lock.withLock { isJoined = newValue } }
    }
    override func id() -> String { identifier }
    override func membership() -> Membership { joined ? .joined : .left }
    override func isEncrypted() async -> Bool { encryption == .encrypted }
    override func roomInfo() async throws -> RoomInfo {
        SlatrixTests.roomInfo(id: identifier, membership: membership())
    }
    override func subscribeToRoomInfoUpdates(listener: RoomInfoListener) -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
    override func matrixToEventPermalink(eventId: String) async throws -> String {
        linkRequests.append(eventId)
        await linkGate.wait()
        if failsLinks { throw MatrixServiceError.request("Fixture permalink failed") }
        guard let link = links[eventId] else { throw MatrixServiceError.request("Unexpected fixture event") }
        return link
    }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        configurations.append(configuration)
        await setupGate.wait()
        return timeline
    }
    override func latestEncryptionState() async throws -> EncryptionState {
        if failsEncryption { throw MatrixServiceError.request("Fixture encryption state unavailable") }
        return encryption
    }
    override func getPowerLevels() async throws -> RoomPowerLevels { powers }
}

final class ActionClient: Client, @unchecked Sendable {
    let entries: [String: ActionRoom]
    let mediaReads = Recorder<String>()
    let recentEmoji = Recorder<String>()
    var storedRecentEmoji: [RecentEmoji] = []
    init(_ rooms: [ActionRoom]) {
        entries = Dictionary(uniqueKeysWithValues: rooms.map { ($0.identifier, $0) })
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getRoom(roomId: String) throws -> Room? { entries[roomId] }
    override func rooms() -> [Room] { Array(entries.values) }
    override func spaceService() async -> SpaceService { FakeSpaceService() }
    override func addRecentEmoji(emoji: String) async throws { recentEmoji.append(emoji) }
    override func getRecentEmojis() async throws -> [RecentEmoji] { storedRecentEmoji }
    override func getMediaContent(mediaSource: MediaSource) async throws -> Data {
        mediaReads.append(mediaSource.url())
        throw MatrixServiceError.request("Fixture media unavailable")
    }
    override func getMediaFile(
        mediaSource: MediaSource, filename: String?, mimeType: String, useCache: Bool, tempDir: String?
    ) async throws -> MediaFileHandle {
        mediaReads.append(mediaSource.url())
        throw MatrixServiceError.request("Fixture media unavailable")
    }
}

/// A signed-in `MatrixService` with one joined room open, a main timeline and an optional thread on `rootID`.
@MainActor
final class ActionFixture {
    let service = MatrixService()
    let roomID = "!actions:example.org"
    let userID = "@owner:example.org"
    let rootID: String
    let room: ActionRoom
    let client: ActionClient
    let main = ActionTimeline()
    var thread: ActionTimeline { room.timeline }
    var session = UUID()
    var selection = UUID()
    var threadLoad = UUID()

    init(rootID: String = "$root", threadReady: Bool = true, otherRooms: [ActionRoom] = []) {
        self.rootID = rootID
        room = ActionRoom(id: roomID)
        client = ActionClient([room] + otherRooms)
        service.user = ChatUser(id: userID, name: "Owner")
        service.selectedRoomID = roomID
        service.rooms = [ChatRoom(id: roomID, name: "Actions", isEncrypted: true)]
        configure(threadReady: threadReady)
    }

    func configure(threadReady: Bool = true) {
        service.configureMessageActionsForChecks(
            client: client, main: main, thread: threadReady ? thread : nil, rootID: threadReady ? rootID : nil,
            sessionID: session, selectionID: selection, threadID: threadLoad)
    }

    func message(_ id: String, inThread: Bool = false, sender: String? = nil) -> ChatMessage {
        var value = ChatMessage(
            id: id, roomID: roomID, senderID: sender ?? userID, senderName: "Owner", body: "Original",
            timestamp: Date(timeIntervalSince1970: 0))
        if inThread { value.threadRootID = rootID }
        return value
    }

    func target(_ message: ChatMessage, _ surface: MessageActionTarget.Surface) throws -> MessageActionTarget {
        try #require(service.captureMessageAction(message: message, surface: surface))
    }

    /// Makes captured actions stale the way the app does: a new session, a new room selection, a closed and
    /// reopened thread pane, or a membership change the SDK reports.
    func apply(_ change: StaleChange) {
        switch change {
        case .session:
            session = UUID()
            configure()
        case .selection:
            selection = UUID()
            configure()
        case .threadReload:
            threadLoad = UUID()
            configure()
        case .threadReopened:
            service.setMessageActionThread(rootID: nil)
            service.setMessageActionThread(rootID: rootID)
        case .left: room.joined = false
        }
    }
}

enum StaleChange: String, CaseIterable, CustomTestStringConvertible {
    case session, selection, threadReload, threadReopened, left
    var testDescription: String { rawValue }
}

/// An encrypted source; `replacement` keeps the MXC URL and changes the key material.
func actionMediaSource(replacement: Bool = false) throws -> MediaSource {
    try encryptedSource(
        url: "mxc://example.org/action-media", key: replacement ? "AQAAAAAAAAAAAAAAAAAAAA" : "AAAAAAAAAAAAAAAAAAAAAA")
}

func messageEvent(
    _ id: String, type: MessageType, sender: String = "@owner:example.org", own: Bool = true, thread: String? = nil
) -> EventTimelineItem {
    let body: String
    switch type {
    case .image(let value): body = value.caption ?? value.filename
    case .file(let value): body = value.caption ?? value.filename
    case .text(let value): body = value.body
    case .notice(let value): body = value.body
    case .emote(let value): body = value.body
    default: body = ""
    }
    let content = MessageContent(
        msgType: type, body: body, isEdited: true, mentions: Mentions(userIds: ["@mentioned:example.org"], room: true))
    return EventTimelineItem(
        isRemote: true, eventOrTransactionId: .eventId(eventId: id), sender: sender, senderProfile: .unavailable,
        forwarder: nil, forwarderProfile: nil, isOwn: own, isEditable: own,
        content: .msgLike(
            content: MsgLikeContent(
                kind: .message(content: content), inReplyTo: nil, threadRoot: thread, threadSummary: nil)),
        reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000, localSendState: nil, editSendState: nil,
        redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
        lazyProvider: LazyTimelineItemProvider(noHandle: .init()))
}

/// An image or file with a caption, HTML caption, size and thumbnail, so every copied field can change.
func captionedMedia(file: Bool, source: MediaSource, caption: String? = "Current caption") -> MessageType {
    let thumbnail = ThumbnailInfo(height: 20, width: 30, mimetype: "image/png", size: 42)
    let formatted = caption.map { _ in
        FormattedBody(format: .html, body: "<b>Current caption</b> <span data-mx-spoiler>hidden</span>")
    }
    if file {
        return .file(
            content: FileMessageContent(
                filename: "report.txt", caption: caption, formattedCaption: formatted, source: source,
                info: FileInfo(mimetype: "text/plain", size: 72, thumbnailInfo: thumbnail, thumbnailSource: source)))
    }
    return .image(
        content: ImageMessageContent(
            filename: "Pasted image.png", caption: caption, formattedCaption: formatted, source: source,
            info: ImageInfo(
                height: 240, width: 320, mimetype: "image/png", size: 1024, thumbnailInfo: thumbnail,
                thumbnailSource: source, blurhash: "fixture-blurhash", isAnimated: false)))
}
