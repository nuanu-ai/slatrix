import CoreGraphics
import Foundation
import ImageIO
import MatrixRustSDK
import Observation
import UniformTypeIdentifiers

enum MatrixServiceError: LocalizedError {
    case signedOut, noRoom, invalidHomeserver, emptyName, preview
    case request(String)
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to continue."
        case .noRoom: return "Open a conversation first."
        case .invalidHomeserver: return "Enter a server address that starts with https://."
        case .emptyName: return "Enter a name."
        case .preview: return "This is a local preview. Sign in to send messages."
        case .request(let message): return message
        }
    }
}

// Read-only links remain useful for deleted remote events. Keep their target
// separate from mutation targets, whose eligibility intentionally excludes them.
struct MessagePermalinkTarget: Identifiable {
    let id = UUID()
    let roomID: String
    let eventID: String
    let surface: MessageActionTarget.Surface
    fileprivate let owner: MessageActionTarget.Context
}

struct SendQueueMessageKey: Hashable {
    let roomID: String
    let messageID: String
}

struct MessageSendFailure: Hashable {
    enum Kind: Hashable { case recoverable, verification, session, missingMedia, invalidMedia, rejected }
    let kind: Kind
    let message: String
    var canRetry: Bool { kind == .recoverable || kind == .verification || kind == .rejected }
    /// Offline, a network failure is only a wait: the message goes out by itself when the connection returns.
    func shown(offline: Bool) -> MessageSendFailure? { offline && kind == .recoverable ? nil : self }

    static func failure(_ state: EventSendState?) -> MessageSendFailure? {
        guard case .sendingFailed(let error, let recoverable) = state else { return nil }
        // Raw SDK errors can carry device maps and IDs, so each reason maps to a fixed message.
        switch error {
        case .insecureDevices, .identityViolations, .crossVerificationRequired:
            return Self(
                kind: .verification,
                message: "Verify the device or person, then retry.")
        case .expiredAccessToken:
            return Self(
                kind: .session,
                message: "Your session expired. Sign in again to send.")
        case .missingMediaContent:
            return Self(
                kind: .missingMedia,
                message: "The file is gone. Cancel and attach it again.")
        case .invalidMimeType:
            return Self(
                kind: .invalidMedia,
                message: "This file type isn’t supported. Cancel and choose another file.")
        case .genericApiError:
            return recoverable
                ? Self(
                    kind: .recoverable,
                    message: "Couldn’t send. Retry to resume."
                )
                : Self(
                    kind: .rejected,
                    message: "The server rejected this message. Retry or cancel it."
                )
        }
    }
}

// Recovery resumes the original send instead of creating a new one, so a message is never sent twice.
@MainActor
enum SendQueueActions {
    static func retry(_ failure: MessageSendFailure, itemID: EventOrTransactionId, room: Room, timeline: Timeline)
        async throws -> Bool
    {
        guard case .transactionId = itemID else { return false }
        guard failure.canRetry else { throw MatrixServiceError.request(failure.message) }
        if failure.kind == .recoverable {
            room.enableSendQueue(enable: true)
            return true
        }
        return try await timeline.retrySend(itemId: itemID, target: .event)
    }

    static func cancel(itemID: EventOrTransactionId, timeline: Timeline) async throws -> Bool {
        guard case .transactionId = itemID else { return false }
        // The SDK may queue a compensating redaction if sending was already in
        // flight and succeeds. A remote event ID is never accepted here.
        return try await timeline.abortSend(itemId: itemID, target: .event)
    }
}

enum MatrixMapping {
    static let maximumAutomaticPreviewBytes: UInt64 = 10 * 1024 * 1024
    static func permitsAutomaticOriginalPreview(size: UInt64?) -> Bool {
        size.map { $0 <= maximumAutomaticPreviewBytes } ?? false
    }

    static func content(_ message: ComposerFormat.Message) throws -> RoomMessageEventContentWithoutRelation {
        try messageEventContentNew(
            msgtype: .text(
                content: TextMessageContent(
                    body: message.body, formatted: message.html.map { FormattedBody(format: .html, body: $0) })))
    }

    /// Fills the shared rich-text cache with the HTML bodies of these items.
    static func renderBodies(of items: [TimelineItem]) {
        for item in items {
            guard let event = item.asEvent(), case .msgLike(let content) = event.content,
                case .message(let message) = content.kind
            else { continue }
            let html: String?
            switch message.msgType {
            case .text(let text): html = htmlBody(text.formatted)
            case .notice(let text): html = htmlBody(text.formatted)
            case .emote(let text): html = htmlBody(text.formatted)
            case .image(let file): html = htmlBody(file.formattedCaption)
            case .file(let file): html = htmlBody(file.formattedCaption)
            default: html = nil
            }
            if let html { _ = MessageBodyRenderer.shared.render(body: message.body, formattedBody: html) }
        }
    }

    static func identifier(_ id: EventOrTransactionId) -> String {
        switch id {
        case .eventId(let id), .transactionId(let id): return id
        }
    }

    static func profileName(_ profile: ProfileDetails, fallback: String) -> String {
        if case .ready(let name, _, _, _, _) = profile { return name ?? fallback }
        return fallback
    }

    static func htmlBody(_ formatted: FormattedBody?) -> String? {
        guard let formatted, case .html = formatted.format else { return nil }
        return formatted.body
    }

    /// A message summarized as text: mentions read "@Name", never a link or a raw ID, and a spoiler hides it all.
    static func previewText(_ body: String, formatted: FormattedBody?) -> String {
        let html = htmlBody(formatted)
        if html?.localizedCaseInsensitiveContains("data-mx-spoiler") == true { return "[Spoiler hidden]" }
        return MessageBodyRenderer.shared.render(body: body, formattedBody: html).plainText
    }

    static func replyPreview(eventID: String, details: EmbeddedEventDetails) -> ChatReplyPreview {
        switch details {
        case .unavailable: return ChatReplyPreview(state: .unavailable, eventID: eventID)
        case .pending: return ChatReplyPreview(state: .pending, eventID: eventID)
        case .error:
            return ChatReplyPreview(state: .failed, eventID: eventID, body: "Original message unavailable")
        case .ready(let content, let sender, let profile, _, _):
            var preview = ChatReplyPreview(
                state: .ready, eventID: eventID, senderID: sender, senderName: profileName(profile, fallback: sender),
                body: "Room event", kind: "m.room.event")
            // A reply preview is a leaf: never traverse this event's own reply or thread details.
            guard case .msgLike(let message) = content else { return preview }
            switch message.kind {
            case .message(let value):
                preview.body = value.body
                switch value.msgType {
                case .text(let text):
                    preview.kind = "m.text"
                    preview.body = previewText(value.body, formatted: text.formatted)
                case .notice(let text):
                    preview.kind = "m.notice"
                    preview.body = previewText(value.body, formatted: text.formatted)
                case .emote(let text):
                    preview.kind = "m.emote"
                    preview.body = previewText(value.body, formatted: text.formatted)
                case .image: preview.kind = "m.image"
                case .file: preview.kind = "m.file"
                case .video: preview.kind = "m.video"
                case .audio: preview.kind = "m.audio"
                case .location: preview.kind = "m.location"
                case .gallery: preview.kind = "m.gallery"
                case .other(let kind, _): preview.kind = kind
                }
            case .redacted:
                preview.body = "This message was deleted"
                preview.kind = "m.room.message"
                preview.isRedacted = true
            case .unableToDecrypt:
                preview.body = "Waiting for this message"
                preview.kind = "m.room.encrypted"
            case .sticker(let body, _, _):
                preview.body = body
                preview.kind = "m.sticker"
            case .poll(let question, _, _, _, _, _, _):
                preview.body = question
                preview.kind = "m.poll"
            case .liveLocation:
                preview.body = "Live location"
                preview.kind = "m.location"
            case .other:
                preview.body = "Unsupported message"
                preview.kind = "other"
            }
            return preview
        }
    }

    static func project(
        _ content: MsgLikeContent, id: String, roomID: String, senderID: String, senderName: String, timestamp: UInt64
    ) -> ChatMessage {
        var message = ChatMessage(
            id: id, roomID: roomID, senderID: senderID, senderName: senderName, body: "",
            timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1000))
        message.threadRootID = content.threadRoot
        message.replyToID = content.inReplyTo?.eventId()
        if let reply = content.inReplyTo {
            message.replyPreview = replyPreview(eventID: reply.eventId(), details: reply.event())
        }
        if let summary = content.threadSummary {
            message.replyCount = Int(summary.numReplies())
            if case .ready(_, let sender, let profile, let timestamp, _) = summary.latestEvent() {
                var avatar: String?
                if case .ready(_, _, let url, _, _) = profile { avatar = url }
                message.lastReply = ThreadReply(
                    senderID: sender, senderName: profileName(profile, fallback: sender), avatarURL: avatar,
                    timestamp: Date(timeIntervalSince1970: Double(timestamp) / 1000))
            }
        }
        switch content.kind {
        case .message(let value):
            message.body = value.body
            message.isEdited = value.isEdited
            switch value.msgType {
            case .text(let text): message.formattedBody = htmlBody(text.formatted)
            case .notice(let text):
                message.kind = "m.notice"
                message.formattedBody = htmlBody(text.formatted)
            case .emote(let text):
                message.kind = "m.emote"
                message.formattedBody = htmlBody(text.formatted)
            case .image(let file):
                message.kind = "m.image"
                message.mediaCaption = file.caption
                message.formattedBody = htmlBody(file.formattedCaption)
                message.attachment = MessageAttachment(
                    name: file.filename, url: file.source.url(), mimeType: file.info?.mimetype, size: file.info?.size,
                    width: file.info?.width, height: file.info?.height,
                    animated: file.info?.isAnimated ?? (file.info?.mimetype == "image/gif"))
            case .file(let file):
                message.kind = "m.file"
                message.mediaCaption = file.caption
                message.formattedBody = htmlBody(file.formattedCaption)
                message.attachment = MessageAttachment(
                    name: file.filename, url: file.source.url(), mimeType: file.info?.mimetype, size: file.info?.size)
            case .video(let file):
                message.kind = "m.video"
                message.attachment = MessageAttachment(
                    name: file.filename, url: file.source.url(), mimeType: file.info?.mimetype, size: file.info?.size,
                    width: file.info?.width, height: file.info?.height, duration: file.info?.duration)
            case .audio(let file):
                message.kind = "m.audio"
                message.attachment = MessageAttachment(
                    name: file.filename, url: file.source.url(), mimeType: file.info?.mimetype, size: file.info?.size)
            case .location: message.kind = "m.location"
            case .gallery: message.kind = "m.gallery"
            case .other(let kind, _): message.kind = kind
            }
        case .redacted:
            message.body = "This message was deleted"
            message.isRedacted = true
        case .unableToDecrypt:
            message.body = "Waiting for this message"
            message.kind = "m.room.encrypted"
        case .sticker(let body, _, _):
            message.body = body
            message.kind = "m.sticker"
        case .poll(let question, _, _, _, _, _, _):
            message.body = question
            message.kind = "m.poll"
        case .liveLocation:
            message.body = "Live location"
            message.kind = "m.location"
        case .other:
            message.body = "Unsupported message"
            message.kind = "other"
        }
        return message
    }

    /// `uniqueID` is the timeline item's own ID, which outlives the switch from a local echo to its remote event.
    static func message(_ item: EventTimelineItem, roomID: String, ownUserID: String?, uniqueID: String? = nil)
        -> ChatMessage?
    {
        guard case .msgLike(let content) = item.content else { return nil }
        let eventID = identifier(item.eventOrTransactionId)
        var result = project(
            content, id: uniqueID ?? eventID, roomID: roomID, senderID: item.sender,
            senderName: profileName(item.senderProfile, fallback: item.sender), timestamp: item.timestamp)
        if uniqueID != nil { result.timelineEventID = eventID }
        result.reactions = item.reactions.map {
            MessageReaction(
                key: $0.key, count: $0.senders.count, mine: $0.senders.contains { $0.senderId == ownUserID },
                senders: $0.senders.map(\.senderId))
        }
        if case .ready(_, _, let avatar, _, _) = item.senderProfile { result.avatarURL = avatar }
        if let state = item.localSendState {
            switch state {
            case .notSentYet: result.sendState = "sending"
            case .sendingFailed: result.sendState = "failed"
            case .sent: result.sendState = "sent"
            }
        }
        return result
    }

    static func searchMessages(_ results: [SearchServiceResult], roomID: String?) -> [ChatMessage] {
        var seen = Set<String>()
        return results.compactMap { result in
            guard case .message(let room, let value) = result, roomID == nil || roomID == room,
                case .msgLike(let content) = value.content,
                seen.insert("\(room)|\(value.eventId)").inserted
            else { return nil }
            let name = profileName(value.senderProfile, fallback: value.sender)
            var message = project(
                content, id: value.eventId, roomID: room, senderID: value.sender, senderName: name,
                timestamp: value.timestamp)
            if case .ready(_, _, let avatar, _, _) = value.senderProfile { message.avatarURL = avatar }
            return message.isRedacted ? nil : message
        }
    }
}

// Diff callbacks can arrive on Rust worker threads. Apply each batch under the same lock before handing a snapshot to
// SwiftUI.
private final class TimelineObserver: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TimelineItem] = []
    private var revision = 0
    let callback: @Sendable ([TimelineItem], Int) -> Void
    init(_ callback: @escaping @Sendable ([TimelineItem], Int) -> Void) { self.callback = callback }
    var snapshot: (items: [TimelineItem], revision: Int) { lock.withLock { (items, revision) } }
    func onUpdate(diff: [TimelineDiff]) {
        let changes = diff.map(\.change)
        lock.lock()
        items.apply(changes)
        revision += 1
        let snapshot = items
        let nextRevision = revision
        lock.unlock()
        // Off the main thread, before the rows that show these bodies exist.
        MatrixMapping.renderBodies(of: changes.flatMap(\.values))
        callback(snapshot, nextRevision)
    }
}

private final class RoomsObserver: RoomListEntriesListener, @unchecked Sendable {
    let callback: @Sendable ([RoomListEntriesUpdate]) -> Void
    init(_ callback: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) { self.callback = callback }
    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) { callback(roomEntriesUpdate) }
}

private final class TypingObserver: TypingNotificationsListener, @unchecked Sendable {
    let callback: @Sendable ([String]) -> Void
    init(_ callback: @escaping @Sendable ([String]) -> Void) { self.callback = callback }
    func call(typingUserIds: [String]) { callback(typingUserIds) }
}

private final class SessionPersistence: ClientSessionDelegate, @unchecked Sendable {
    let storeID: String
    let storeKey: Data
    private let lock = NSLock()
    private var active = true
    private var cachedSession: StoredSession?
    let failure: @Sendable () -> Void
    init(storeID: String, storeKey: Data, initialSession: StoredSession?, failure: @escaping @Sendable () -> Void) {
        self.storeID = storeID
        self.storeKey = storeKey
        self.cachedSession = initialSession
        self.failure = failure
    }
    func deactivate() {
        lock.lock()
        active = false
        cachedSession = nil
        lock.unlock()
    }
    func cache(_ session: StoredSession) {
        lock.lock()
        defer { lock.unlock() }
        if active, session.storeID == storeID, session.storeKey == storeKey { cachedSession = session }
    }
    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard active, let stored = cachedSession, stored.userId == userId, stored.storeID == storeID else {
                throw MatrixServiceError.signedOut
            }
            return Session(
                accessToken: stored.accessToken, refreshToken: stored.refreshToken, userId: stored.userId,
                deviceId: stored.deviceId, homeserverUrl: stored.homeserverUrl, oauthData: stored.oidcData,
                slidingSyncVersion: .native)
        } catch {
            throw ClientError.Generic(
                msg: "Stored session is unavailable. Unlock Keychain or sign in again.", details: nil)
        }
    }
    func saveSessionInKeychain(session: Session) {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let stored = StoredSession(
            accessToken: session.accessToken, refreshToken: session.refreshToken, userId: session.userId,
            deviceId: session.deviceId, homeserverUrl: session.homeserverUrl, oidcData: session.oauthData,
            storeID: storeID, storeKey: storeKey)
        cachedSession = stored
        do { try SecureSessionStore.save(stored) } catch { failure() }
    }
}

private final class NotificationsObserver: SyncNotificationListener, @unchecked Sendable {
    let callback: @Sendable (NotificationItem, String) -> Void
    init(_ callback: @escaping @Sendable (NotificationItem, String) -> Void) { self.callback = callback }
    func onNotification(notification: NotificationItem, roomId: String) { callback(notification, roomId) }
}

private final class SearchResultsObserver: SearchServiceResultsListener, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SearchServiceResult] = []
    private var revision = 0
    let callback: @Sendable ([SearchServiceResult], Int) -> Void
    init(_ callback: @escaping @Sendable ([SearchServiceResult], Int) -> Void) { self.callback = callback }
    func onUpdate(updates: [SearchServiceResultsUpdate]) {
        lock.lock()
        results.apply(updates.map(\.change))
        revision += 1
        let snapshot = results
        let nextRevision = revision
        lock.unlock()
        callback(snapshot, nextRevision)
    }
}

private final class SearchPaginationObserver: SearchServicePaginationStateListener, @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    let callback: @Sendable (SearchServicePaginationState, Int) -> Void
    init(_ callback: @escaping @Sendable (SearchServicePaginationState, Int) -> Void) { self.callback = callback }
    func onUpdate(paginationState: SearchServicePaginationState) {
        lock.lock()
        revision += 1
        let nextRevision = revision
        lock.unlock()
        callback(paginationState, nextRevision)
    }
}

@MainActor
@Observable final class MatrixService {
    let verification = VerificationService()
    let threadFeed = ThreadFeedService()
    let activity = ActivityService()
    let people = PeopleService()
    let pinnedMessages = PinnedMessagesService()
    let sharedFiles = SharedFilesService()
    let avatarImages = AvatarImageCache()
    /// Decoded inline images and posters by event and source, so a row that comes back draws its picture at once.
    let mediaImages: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()
    private let roomSubscriptions = RoomSubscriptionCoordinator()
    private let readDelivery = ReadStateDelivery()
    private(set) var pendingInvitationRoomIDs = Set<String>()
    @ObservationIgnored private lazy var invitationActions = InvitationActions { [weak self] pending in
        self?.pendingInvitationRoomIDs = pending
    }
    private var lastAutomaticReceipt: ReadReceiptTarget?
    var timelineSelectionID: UUID { selection }
    var status: ConnectionStatus = .signedOut
    var connectionDetail = "Opening your workspace…"
    private(set) var connectionErrorMessage: String?
    private(set) var connectionState = MatrixConnectionState.idle
    private(set) var isRetryingConnection = false
    private(set) var canRetryConnection = false
    private let connectionRecovery = ConnectionRecovery()
    private var profileLoadTask: Task<Void, Never>?
    private var profileRevision: UInt64 = 0
    private var roomDetailsSaves = Set<String>()
    private var connectionStopTask: (id: UUID, task: Task<Void, Never>)?
    private(set) var sessionCleanupPending = false
    /// Sign-in and sign-out exclude each other for the whole of their SDK and Keychain work,
    /// so a late credential delete can never erase a newer sign-in.
    private enum AuthOperation { case signingIn, signingOut }
    private var authOperation: AuthOperation?
    private static let authBusy = MatrixServiceError.request(
        "Still signing in or out. Try again in a moment.")
    var canChangeAuthentication: Bool {
        authOperation == nil && !sessionCleanupPending && connectionStopTask == nil
    }
    var errorMessage: String?
    var rooms: [ChatRoom] = [] { didSet { updateSelectedRoom() } }
    var workspaces: [Workspace] = []
    var messages: [ChatMessage] = [] {
        didSet {
            let locked = messages.contains { $0.kind == "m.room.encrypted" }
            if locked != hasLockedMessages { hasLockedMessages = locked }
        }
    }
    /// Whether the open conversation shows messages this device can't decrypt yet; apart from `messages`, so its
    /// readers aren't redrawn by every message.
    private(set) var hasLockedMessages = false
    private(set) var sendFailures: [SendQueueMessageKey: MessageSendFailure] = [:]
    private(set) var pendingSendActions = Set<SendQueueMessageKey>()
    private var mainSendFailures: [SendQueueMessageKey: MessageSendFailure] = [:]
    private var threadSendFailures: [SendQueueMessageKey: MessageSendFailure] = [:]
    var threadMessages: [ChatMessage] = []
    private(set) var hasMoreHistory = true
    private(set) var hasMoreForwardHistory = false
    private(set) var isLoadingForwardHistory = false
    private(set) var firstUnreadEventID: String?
    private var forwardLoadID: UUID?
    private(set) var hasMoreThreadHistory = true
    var members: [ChatUser] = []
    /// Whether your power level lets you notify the whole selected room, read with its members.
    var canMentionRoom = false
    var user: ChatUser?
    /// Emoji this account reacted with, newest first, kept in its account data so Element shares them.
    private(set) var recentEmoji: [String] = []
    var selectedRoomID: String? { didSet { updateSelectedRoom() } }
    /// The open conversation's entry in `rooms`, apart so its readers are not redrawn by changes to other rooms.
    /// Without its unread state, which changes with every message in it; the sidebar shows that from `rooms`.
    private(set) var selectedRoom: ChatRoom?
    private func updateSelectedRoom() {
        var room = rooms.first { $0.id == selectedRoomID }
        room?.unread = 0
        room?.unreadMessages = 0
        room?.isMarkedUnread = false
        room?.mentions = 0
        room?.fullyReadEventID = nil
        if room != selectedRoom { selectedRoom = room }
    }
    var typingUsers: [String] = []
    var isPreview = false
    /// Inline images and videos the reader collapsed, by event ID; they stay collapsed until the app quits.
    var collapsedMedia = Set<String>()
    var searchResults: [ChatMessage] = []
    var searchState = "idle"
    var searchErrorMessage: String?
    var searchHasMore = false
    private(set) var searchIndexingState: SearchIndexingState = .idle
    let publicDirectory = PublicRoomDirectoryService()
    /// Set while the main timeline is one loaded around an older message rather than the live one.
    var focusedEventID: String?
    /// The message the open conversation scrolls to and highlights.
    var jump: MessageJump?
    private(set) var homeserverURL: String?
    var notificationHandler: ((DesktopMessageNotification) -> Void)?
    var notificationSessionID: UUID { sessionGeneration }
    let notificationRetries = NotificationSettingsRetryState()
    private var client: Client?
    private var roomList: RoomListEntriesWithDynamicAdaptersResult?
    private var handles: [TaskHandle] = []
    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    /// The open conversation's live timeline; nil while it shows one opened at an older message.
    private var liveTimeline: KeptTimeline?
    private var recentTimelines = RecentTimelines<KeptTimeline>()
    /// The open whose conversation is on screen, which can trail `selection` while the next one reads its cache.
    private var shownSelection: UUID?
    private var typingHandle: TaskHandle?
    private var threadTimeline: Timeline?
    private var threadHandle: TaskHandle?
    private var timelineRevision = 0
    private var threadRevision = 0
    private var threadSelection = UUID()
    private var loadedThreadRootID: String?
    private var readyThreadReadSelection: UUID?
    private var lastThreadReceipt: ThreadReadReceiptTarget?
    var threadReadIdentity: ThreadReadIdentity? {
        guard connectionStopTask == nil, !isPreview, client != nil, let account = user?.id,
            let roomID = selectedRoomID, selectedRoom?.membership == "join",
            let root = loadedThreadRootID, visibleActionThreadID == root, threadTimeline != nil,
            readyThreadReadSelection == threadSelection
        else { return nil }
        return ThreadReadIdentity(
            accountID: account, sessionID: sessionGeneration, roomID: roomID,
            timelineID: selection, rootID: root, threadSelectionID: threadSelection,
            presentationID: messageActionThreadPresentationID)
    }
    private var visibleActionThreadID: String?
    private(set) var messageActionThreadPresentationID = UUID()

    // Closing a pane invalidates its actions and read acknowledgements without cancelling the SDK's
    // independent read/listener lifetime.
    func setMessageActionThread(rootID: String?) {
        guard visibleActionThreadID != rootID else { return }
        visibleActionThreadID = rootID
        messageActionThreadPresentationID = UUID()
    }
    var messageActionContext: MessageActionTarget.Context {
        MessageActionTarget.Context(
            sessionID: sessionGeneration, userID: user?.id, roomID: selectedRoomID,
            timelineID: selection, threadSelectionID: threadSelection,
            threadPresentationID: messageActionThreadPresentationID,
            readyThreadID: threadTimeline != nil && visibleActionThreadID == loadedThreadRootID
                ? loadedThreadRootID : nil,
            authenticated: client != nil && connectionStopTask == nil,
            joined: selectedRoom?.membership == "join", preview: isPreview)
    }
    func captureMessageAction(message: ChatMessage, surface: MessageActionTarget.Surface) -> MessageActionTarget? {
        guard let target = MessageActionTarget(message: message, surface: surface, context: messageActionContext),
            let current = currentActionMessage(target), !current.isRedacted, current.sendState == "sent"
        else { return nil }
        return target
    }
    func isCurrentMessageAction(_ target: MessageActionTarget) -> Bool { target.isCurrent(in: messageActionContext) }
    func captureMessagePermalink(message: ChatMessage, surface: MessageActionTarget.Surface) -> MessagePermalinkTarget?
    {
        let target = MessagePermalinkTarget(
            roomID: message.roomID, eventID: message.eventID, surface: surface, owner: messageActionContext)
        return isCurrentMessagePermalink(target) ? target : nil
    }
    func isCurrentMessagePermalink(_ target: MessagePermalinkTarget) -> Bool {
        let context = messageActionContext
        guard context.authenticated, context.joined, !context.preview, context.userID != nil,
            context.sessionID == target.owner.sessionID, context.userID == target.owner.userID,
            context.roomID == target.roomID, context.timelineID == target.owner.timelineID,
            target.eventID.hasPrefix("$"), let client,
            let room = try? client.getRoom(roomId: target.roomID), room.membership() == .joined
        else { return false }
        let items: [ChatMessage]
        switch target.surface {
        case .conversation: items = messages
        case .thread(let rootID):
            guard context.readyThreadID == rootID, context.threadSelectionID == target.owner.threadSelectionID,
                context.threadPresentationID == target.owner.threadPresentationID
            else { return false }
            items = threadMessages
        }
        guard let message = items.first(where: { $0.eventID == target.eventID && $0.roomID == target.roomID }),
            message.sendState == "sent"
        else { return false }
        if case .thread(let rootID) = target.surface {
            return message.eventID == rootID || message.threadRootID == rootID
        }
        return true
    }
    func roomPermalink(_ roomID: String) async throws -> String {
        try await requireRoom(roomID).matrixToPermalink()
    }
    func messagePermalink(for target: MessagePermalinkTarget) async throws -> String {
        @MainActor func validate() throws {
            try Task.checkCancellation()
            guard isCurrentMessagePermalink(target) else { throw CancellationError() }
        }
        do {
            try validate()
            let room = try requireRoom(target.roomID)
            let link = try await room.matrixToEventPermalink(eventId: target.eventID)
            try validate()
            return link
        } catch {
            try validate()
            throw error
        }
    }
    private func currentActionMessage(_ target: MessageActionTarget) -> ChatMessage? {
        let items: [ChatMessage]
        switch target.surface {
        case .conversation: items = messages
        case .thread: items = threadMessages
        }
        // From the newest end, where the rows people act on are.
        return items.last { $0.eventID == target.message.eventID && $0.roomID == target.message.roomID }
    }
    private func validateMessageAction(_ target: MessageActionTarget) throws {
        try Task.checkCancellation()
        guard isCurrentMessageAction(target), try requireRoom(target.message.roomID).membership() == .joined else {
            throw CancellationError()
        }
    }
    private func actionTimeline(_ target: MessageActionTarget) throws -> (Timeline, ChatMessage) {
        try validateMessageAction(target)
        guard let current = currentActionMessage(target), !current.isRedacted, current.sendState == "sent" else {
            throw CancellationError()
        }
        switch target.surface {
        case .conversation: return (try requireTimeline(), current)
        case .thread(let rootID):
            guard loadedThreadRootID == rootID, let threadTimeline else { throw CancellationError() }
            return (threadTimeline, current)
        }
    }
    #if DEBUG
    func configureMessageActionsForChecks(
        client: Client, main: Timeline?, thread: Timeline?, rootID: String?, sessionID: UUID, selectionID: UUID,
        threadID: UUID
    ) {
        self.client = client
        timeline = main
        threadTimeline = thread
        loadedThreadRootID = rootID
        sessionGeneration = sessionID
        selection = selectionID
        threadSelection = threadID
        setMessageActionThread(rootID: rootID)
    }
    func configureRoomOpenForChecks(client: Client, roomList: RoomListService, user: ChatUser) {
        self.client = client
        self.user = user
        roomSubscriptions.attach(roomList)
    }
    #endif
    private var captionSaves = Set<UUID>()
    private var forwardingReviews = Set<UUID>()
    private var replyPreviewLoads = Set<MessageActionTarget.ReplyPreviewIdentity>()
    private var selection = UUID()
    private var sessionGeneration = UUID()
    @ObservationIgnored private lazy var roomListRefresher: RoomListRefresher = {
        let refresher = RoomListRefresher()
        refresher.onChange = { [weak self, weak refresher] in
            guard let self, let refresher else { return }
            if self.rooms != refresher.rooms { self.rooms = refresher.rooms }
            if self.workspaces != refresher.workspaces { self.workspaces = refresher.workspaces }
            self.threadFeed.updateRooms(refresher.rooms)
        }
        refresher.onError = { [weak self] error in self?.errorMessage = Self.safeError(error) }
        return refresher
    }()
    private var eventIDs: [String: EventOrTransactionId] = [:]
    private var mediaSources: [String: MediaSource] = [:]
    private struct ThumbnailSource {
        let source: MediaSource
        let size: UInt64?
    }
    private var thumbnailSources: [String: ThumbnailSource] = [:]
    private var mainForwardMedia: [String: ForwardMediaRevision] = [:]
    private var threadForwardMedia: [String: ForwardMediaRevision] = [:]
    /// Remote, undeleted attachments each open timeline shows, by event ID.
    private struct ShownMedia {
        let source: MediaSource
        let attachment: MessageAttachment
        /// The full source, encryption key included; an edit can keep the URL and change the key.
        let identity: String
    }
    private var mainMedia: [String: ShownMedia] = [:]
    /// A live timeline with what its conversation last showed, so coming back to it rebuilds nothing.
    @MainActor private final class KeptTimeline {
        let roomID: String
        let token: UUID
        let timeline: Timeline
        let observer: TimelineObserver
        let listener: TaskHandle
        var revision = 0
        var messages: [ChatMessage] = []
        var members: [ChatUser] = []
        var hasMoreHistory = true
        var firstUnreadEventID: String?
        var eventIDs: [String: EventOrTransactionId] = [:]
        var mediaSources: [String: MediaSource] = [:]
        var thumbnailSources: [String: ThumbnailSource] = [:]
        var media: [String: ShownMedia] = [:]
        var forwardMedia: [String: ForwardMediaRevision] = [:]
        var sendFailures: [SendQueueMessageKey: MessageSendFailure] = [:]
        var projections: Projections = [:]
        init(roomID: String, token: UUID, timeline: Timeline, observer: TimelineObserver, listener: TaskHandle) {
            self.roomID = roomID
            self.token = token
            self.timeline = timeline
            self.observer = observer
            self.listener = listener
        }
    }
    private var threadMedia: [String: ShownMedia] = [:]
    private let mediaFiles = MediaFileCache()
    private let savedPreviewLimit = ConcurrencyLimit(slots: 2)
    private var persistence: SessionPersistence?
    private var activeSearch: SearchService?
    private var searchHandles: [TaskHandle] = []
    private var searchGeneration = UUID()
    private var searchResultRevision = 0
    private var searchPaginationRevision = 0
    private var searchQueryCompleted = false
    private let searchIndexing = SearchIndexingController()
    private var verificationAttachTask: Task<Void, Never>?

    static func validatedHomeserver(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URLComponents(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw MatrixServiceError.invalidHomeserver }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func buildClient(homeserver: String, storeID: String, storeKey: Data, initialSession: StoredSession? = nil)
        async throws -> (Client, SessionPersistence)
    {
        let folders = try SessionStores.create(storeID)
        let delegate = SessionPersistence(storeID: storeID, storeKey: storeKey, initialSession: initialSession) {
            [weak self] in
            Task { @MainActor [weak self] in
                self?.errorMessage =
                    "Couldn’t save your session to Keychain. Unlock Keychain before restarting Slatrix."
            }
        }
        let stores = SqliteStoreBuilder(dataPath: folders.data.path, cachePath: folders.cache.path).key(key: storeKey)
        let client = try await Self.clientBuilder(homeserver: homeserver, restoring: initialSession != nil).sqliteStore(
            config: stores
        ).withSearchIndexStore(path: folders.searchIndex.path, password: storeKey.base64EncodedString())
            .enableAutomaticBackPagination(enableAutomaticBackPagination: true).setSessionDelegate(
                sessionDelegate: delegate
            ).threadsEnabled(enabled: true, threadSubscriptions: false).build()
        return (client, delegate)
    }

    /// Restoring reuses the homeserver URL resolved at sign-in, so launch doesn't wait on `.well-known` and
    /// `/versions`; signing in still discovers it from what the person typed.
    static func clientBuilder(homeserver: String, restoring: Bool) -> ClientBuilder {
        restoring
            ? ClientBuilder().homeserverUrl(url: homeserver).slidingSyncVersionBuilder(versionBuilder: .native)
            : ClientBuilder().serverNameOrHomeserverUrl(serverNameOrUrl: homeserver).slidingSyncVersionBuilder(
                versionBuilder: .discoverNative)
    }

    func login(homeserver: String, username: String, password: String) async throws {
        guard canChangeAuthentication else {
            throw MatrixServiceError.request(
                sessionCleanupPending
                    ? "Clear the saved session before signing in again."
                    : "Still signing in or out. Try again in a moment.")
        }
        authOperation = .signingIn
        defer { authOperation = nil }
        let account = sessionGeneration
        status = .connecting
        errorMessage = nil
        connectionDetail = "Signing in…"
        let storeID = UUID().uuidString
        var storeSaved = false
        do {
            let homeserver = try Self.validatedHomeserver(homeserver)
            let storeKey = try SecureSessionStore.generateStoreKey()
            let (newClient, delegate) = try await buildClient(
                homeserver: homeserver, storeID: storeID, storeKey: storeKey)
            try validateAuthentication(account)
            try await newClient.login(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password,
                initialDeviceName: "Slatrix · macOS", deviceId: nil)
            let session = try newClient.session()
            let stored = StoredSession(
                accessToken: session.accessToken, refreshToken: session.refreshToken, userId: session.userId,
                deviceId: session.deviceId, homeserverUrl: session.homeserverUrl, oidcData: session.oauthData,
                storeID: storeID, storeKey: storeKey)
            try validateAuthentication(account)
            try await Task.detached(priority: .userInitiated) {
                delegate.cache(stored)
                try SecureSessionStore.save(stored)
            }.value
            storeSaved = true
            try validateAuthentication(account)
            try await start(newClient, delegate: delegate)
        } catch {
            // Once Keychain points at this store it holds the device's keys; only an unsaved one is disposable.
            if !storeSaved { SessionStores.remove(storeID) }
            status = .error
            errorMessage = Self.safeError(error)
            throw MatrixServiceError.request(Self.safeError(error))
        }
    }

    func restore() async {
        guard status == .signedOut, canChangeAuthentication else { return }
        authOperation = .signingIn
        defer { authOperation = nil }
        let account = sessionGeneration
        do {
            status = .connecting
            connectionDetail = "Restoring your session…"
            let saved = try await Task.detached(priority: .userInitiated) { try SecureSessionStore.load() }.value
            try validateAuthentication(account)
            SessionStores.removeAll(except: saved?.storeID)
            guard let stored = saved else {
                status = .signedOut
                return
            }
            connectionDetail = "Opening encrypted history…"
            let (newClient, delegate) = try await buildClient(
                homeserver: stored.homeserverUrl, storeID: stored.storeID, storeKey: stored.storeKey,
                initialSession: stored)
            connectionDetail = "Connecting…"
            try validateAuthentication(account)
            try await newClient.restoreSession(
                session: Session(
                    accessToken: stored.accessToken, refreshToken: stored.refreshToken, userId: stored.userId,
                    deviceId: stored.deviceId, homeserverUrl: stored.homeserverUrl, oauthData: stored.oidcData,
                    slidingSyncVersion: .native))
            try validateAuthentication(account)
            try await start(newClient, delegate: delegate)
        } catch {
            status = .error
            errorMessage = Self.safeError(error)
        }
    }

    private func validateAuthentication(_ account: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == account else { throw CancellationError() }
    }

    private func start(_ newClient: Client, delegate: SessionPersistence) async throws {
        await stop()
        client = newClient
        persistence = delegate
        isPreview = false
        status = .syncing
        connectionDetail = "Loading your conversations…"
        roomListRefresher.attach(newClient)
        people.attach(newClient)
        pinnedMessages.attach(newClient)
        sharedFiles.attach(newClient)
        homeserverURL = try newClient.session().homeserverUrl
        let generation = sessionGeneration
        let id = try newClient.userId()
        user = ChatUser(id: id, name: id)
        verificationAttachTask = Task { [weak self] in
            guard let self, self.sessionGeneration == generation else { return }
            await self.verification.attach(client: newClient)
        }
        let startedAt = UInt64(Date().timeIntervalSince1970 * 1000)
        await newClient.registerNotificationHandler(
            listener: NotificationsObserver { [weak self] notification, roomID in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionGeneration == generation else { return }
                    guard let item = self.activity.receive(notification, roomID: roomID, ownUserID: id) else { return }
                    // The feed records notifications received this session, before native preference filters.
                    guard item.allowsNativeNotification else { return }
                    if case .message = item.kind, item.timestamp.timeIntervalSince1970 * 1000 < Double(startedAt) {
                        return
                    }
                    if let target = MatrixNotificationTarget(accountID: id, roomID: roomID, eventID: item.eventID) {
                        self.notificationHandler?(
                            DesktopMessageNotification(
                                target: target, title: item.roomName, body: item.body,
                                playSound: notification.isNoisy == true))
                    }
                }
            })
        guard sessionGeneration == generation, connectionStopTask == nil else { throw CancellationError() }
        let service = try await newClient.syncService().withOfflineMode().finish()
        guard sessionGeneration == generation, connectionStopTask == nil else { throw CancellationError() }
        roomSubscriptions.attach(service.roomListService())
        try await connectionRecovery.attach(service, client: newClient) { [weak self] feedback in
            guard let self, self.sessionGeneration == generation, self.connectionStopTask == nil else { return }
            self.connectionDetail = feedback.detail
            self.connectionErrorMessage = feedback.errorMessage
            self.connectionState = feedback.state
            self.isRetryingConnection = feedback.isRetrying
            self.canRetryConnection = feedback.canRetry
            switch feedback.state {
            case .running: self.status = .ready
            case .failed: self.status = .error
            case .idle, .connecting, .offline, .stopped: self.status = .syncing
            }
            self.requestRefresh()
        }
        guard sessionGeneration == generation, connectionStopTask == nil else { throw CancellationError() }
        let allRooms = try await service.roomListService().allRooms()
        guard sessionGeneration == generation, connectionStopTask == nil else { throw CancellationError() }
        roomList = allRooms.entriesWithDynamicAdapters(
            pageSize: 100,
            listener: RoomsObserver { [weak self] updates in
                Task { @MainActor [weak self] in
                    // The updates carry this account's rooms; a late batch must not list them under another.
                    guard let self, self.sessionGeneration == generation else { return }
                    self.roomListRefresher.request(updates)
                }
            })
        // The dynamic list emits nothing until a filter is set; false means the list is already gone.
        guard roomList?.controller().setFilter(kind: .all(filters: [])) == true else {
            throw MatrixServiceError.request("Couldn’t load your conversations. Sign in again.")
        }
        try await connectionRecovery.retry()
        guard sessionGeneration == generation else { throw CancellationError() }
        requestRefresh()
        // Cached rooms and sync can become usable without waiting on profile
        // HTTP requests. A late profile response belongs only to this account.
        let loadedProfileRevision = profileRevision
        Task { [weak self] in await self?.loadRecentEmoji() }
        profileLoadTask = Task { [weak self] in
            do {
                let name = try await newClient.displayName()
                let avatar = try await newClient.avatarUrl()
                guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                if self.profileRevision == loadedProfileRevision { self.user?.name = name }
                self.user?.avatarURL = avatar
            } catch {
                guard let self, self.sessionGeneration == generation, !Task.isCancelled else { return }
                if self.errorMessage == nil {
                    self.errorMessage = "Couldn’t load your profile."
                }
            }
        }
    }

    func retryConnection() async throws {
        guard connectionStopTask == nil else { throw CancellationError() }
        _ = try requireClient()
        let generation = sessionGeneration
        do {
            try await connectionRecovery.retry()
            guard sessionGeneration == generation else { throw CancellationError() }
        } catch {
            guard sessionGeneration == generation else { throw CancellationError() }
            throw error
        }
    }

    private func stop() async {
        if let pending = connectionStopTask {
            await pending.task.value
            return
        }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopCurrentSession()
        }
        // Caller cancellation does not interrupt teardown; replacements await
        // this same cleanup, including any noncancellable SDK start in flight.
        connectionStopTask = (id, task)
        await task.value
        if connectionStopTask?.id == id { connectionStopTask = nil }
    }

    private func stopCurrentSession() async {
        mediaFiles.removeAll()
        mainMedia = [:]
        threadMedia = [:]
        mainForwardMedia = [:]
        threadForwardMedia = [:]
        people.attach(nil)
        pinnedMessages.attach(nil)
        sharedFiles.attach(nil)
        threadFeed.close()
        activity.clear()
        roomSubscriptions.attach(nil)
        avatarImages.clear()
        mediaImages.removeAllObjects()
        replyPreviewLoads.removeAll()
        verificationAttachTask?.cancel()
        verificationAttachTask = nil
        verification.detach()
        cancelSearch()
        publicDirectory.close()
        searchIndexing.reset()
        searchIndexingState = .idle
        focusedEventID = nil
        jump = nil
        sessionGeneration = UUID()
        selection = UUID()
        notificationRetries.reset()
        profileLoadTask?.cancel()
        profileLoadTask = nil
        connectionErrorMessage = nil
        connectionState = .idle
        isRetryingConnection = false
        canRetryConnection = false
        readDelivery.reset()
        lastAutomaticReceipt = nil
        readyThreadReadSelection = nil
        lastThreadReceipt = nil
        captionSaves.removeAll()
        forwardingReviews.removeAll()
        invitationActions.reset()
        roomDetailsSaves.removeAll()
        firstUnreadEventID = nil
        hasMoreForwardHistory = false
        isLoadingForwardHistory = false
        forwardLoadID = nil
        recentEmoji = []
        await connectionRecovery.stop()
        mainSendFailures = [:]
        threadSendFailures = [:]
        sendFailures = [:]
        pendingSendActions = []
        let oldPersistence = persistence
        persistence = nil
        await Task.detached(priority: .userInitiated) { oldPersistence?.deactivate() }.value
        roomListRefresher.attach(nil)
        timelineHandle?.cancel()
        typingHandle?.cancel()
        threadHandle?.cancel()
        for kept in recentTimelines.removeAll() { kept.listener.cancel() }
        liveTimeline = nil
        mainProjections = [:]
        threadProjections = [:]
        timelineHandle = nil
        typingHandle = nil
        threadHandle = nil
        for handle in handles { handle.cancel() }
        handles.removeAll()
        roomList?.entriesStream().cancel()
        roomList = nil
        timeline = nil
        threadTimeline = nil
        client = nil
        MessageBodyRenderer.shared.clearCache()
        eventIDs.removeAll()
        mediaSources.removeAll()
        thumbnailSources.removeAll()
    }

    private func beginLogout() throws {
        guard authOperation == nil, connectionStopTask == nil else { throw Self.authBusy }
        authOperation = .signingOut
    }

    private var logoutOwner: LogoutOwner {
        LogoutOwner(sessionID: sessionGeneration, userID: user?.id, isPreview: isPreview)
    }

    private func validateLogout(_ owner: LogoutOwner) throws {
        guard logoutOwner == owner else { throw CancellationError() }
    }

    func logout() async throws {
        try beginLogout()
        let owner = logoutOwner
        defer { authOperation = nil }
        if let originalClient = client {
            do { try await originalClient.logout() } catch {
                try validateLogout(owner)
                if error is CancellationError { throw error }
                if !Self.isRevokedSession(error) { throw ServerLogoutFailure(message: Self.safeError(error)) }
            }
        }
        try validateLogout(owner)
        try await clearLocalSession(owner)
    }

    func logoutLocally() async throws {
        try beginLogout()
        let owner = logoutOwner
        defer { authOperation = nil }
        try await clearLocalSession(owner)
    }

    private func clearLocalSession(_ owner: LogoutOwner) async throws {
        try validateLogout(owner)
        let storeID = persistence?.storeID
        await stop()
        // Our own stop rotates sessionGeneration. Authentication is excluded
        // until deletion finishes, so a delayed delete cannot erase a new login.
        let stoppedOwner = LogoutOwner(sessionID: sessionGeneration, userID: owner.userID, isPreview: owner.isPreview)
        try validateLogout(stoppedOwner)
        guard client == nil else { throw CancellationError() }
        var deletionError: Error?
        do { try await Task.detached(priority: .userInitiated) { try SecureSessionStore.delete() }.value } catch {
            deletionError = error
        }
        // While Keychain still holds the session it can restore into this store, so keep it.
        if deletionError == nil, let storeID { SessionStores.remove(storeID) }
        try validateLogout(stoppedOwner)
        sessionCleanupPending = deletionError != nil
        // Keep the old account published through credential deletion; exposing
        // LoginView earlier would allow overlapping new-session persistence.
        rooms = []
        workspaces = []
        messages = []
        threadMessages = []
        members = []
        canMentionRoom = false
        user = nil
        selectedRoomID = nil
        typingUsers = []
        homeserverURL = nil
        isPreview = false
        status = .signedOut
        errorMessage = nil
        if deletionError != nil {
            let message =
                "Signed out, but couldn’t remove the saved session from Keychain. Unlock Keychain and finish signing out."
            errorMessage = message
            throw MatrixServiceError.request(message)
        }
    }

    static func isRevokedSession(_ error: Error) -> Bool {
        if let error = error as? ClientError, case .MatrixApi(let kind, _, _, _) = error, case .unknownToken = kind {
            return true
        }
        return false
    }

    private func requireClient() throws -> Client {
        if isPreview { throw MatrixServiceError.preview }
        guard let client else { throw MatrixServiceError.signedOut }
        return client
    }
    private func requireRoom(_ id: String? = nil) throws -> Room {
        let client = try requireClient()
        guard let id = id ?? selectedRoomID, let room = try client.getRoom(roomId: id) else {
            throw MatrixServiceError.noRoom
        }
        return room
    }
    private func requireTimeline() throws -> Timeline {
        _ = try requireClient()
        guard let timeline else { throw MatrixServiceError.noRoom }
        return timeline
    }
    private func assertDestination(_ roomID: String?) throws {
        if let roomID, roomID != selectedRoomID {
            throw MatrixServiceError.request("You switched conversations, so the rest wasn’t sent.")
        }
    }

    private func requestRefresh() { roomListRefresher.request() }

    func selectRoom(_ id: String) async {
        jump = nil
        if showRecentRoom(id) { return }
        await setupRoom(id, focus: .live(hideThreadedEvents: true), eventID: nil)
    }

    /// Opens a conversation with unread messages at its unread line.
    func resumeRoom(_ id: String, at anchor: String) async {
        jump = nil
        await open(id, at: anchor)
    }

    /// Opens a conversation scrolled to a message, which it highlights.
    func jumpToMessage(roomID: String, eventID: String) async {
        jump = MessageJump(roomID: roomID, eventID: eventID)
        await open(roomID, at: eventID)
    }

    /// Live, as Slack does, when the live timeline open or in the cache holds `eventID`; else loaded around it.
    private func open(_ id: String, at eventID: String) async {
        guard eventID.hasPrefix("$") else {
            errorMessage = "This message hasn’t been sent yet."
            return
        }
        if showRecentRoom(id, containing: eventID) { return }
        if await setupRoom(id, focus: .live(hideThreadedEvents: true), eventID: nil, containing: eventID) { return }
        let focus = TimelineFocus.event(
            eventId: eventID, numContextEvents: 30, threadMode: .automatic(hideThreadedEvents: false))
        await setupRoom(id, focus: focus, eventID: eventID)
    }

    /// Shows a conversation whose live timeline is still open, rows and all, in the frame of the click. False when
    /// none is open, or when it does not hold `anchor`.
    func showRecentRoom(_ id: String, containing anchor: String? = nil) -> Bool {
        guard connectionStopTask == nil, client != nil, !isPreview else { return false }
        func holds(_ kept: KeptTimeline) -> Bool {
            anchor.map { Self.contains(kept.observer.snapshot.items, $0) } ?? true
        }
        if let live = liveTimeline, live.roomID == id, holds(live) {
            // Already on screen; this drops any other conversation that was still opening.
            selection = live.token
            showTimeline(live.observer.snapshot, roomID: id)
            return true
        }
        guard let kept = recentTimelines.entry(id), holds(kept) else { return false }
        _ = recentTimelines.take(id)
        selection = kept.token
        showConversation(id, eventID: nil, token: kept.token)
        liveTimeline = kept
        timeline = kept.timeline
        timelineHandle = kept.listener
        messages = kept.messages
        members = kept.members
        canMentionRoom = false
        hasMoreHistory = kept.hasMoreHistory
        firstUnreadEventID = kept.firstUnreadEventID
        eventIDs = kept.eventIDs
        mediaSources = kept.mediaSources
        thumbnailSources = kept.thumbnailSources
        mainMedia = kept.media
        mainForwardMedia = kept.forwardMedia
        mainSendFailures = kept.sendFailures
        sendFailures = kept.sendFailures
        mainProjections = kept.projections
        timelineRevision = kept.revision
        // What arrived while the reader was away.
        showTimeline(kept.observer.snapshot, roomID: id)
        if !messages.isEmpty { Performance.finish(.roomTimeline, ["messages": messages.count]) }
        updateSubscriptions(id)
        if let room = try? client?.getRoom(roomId: id) { watchTyping(room, token: kept.token) }
        Task { [weak self] in await self?.loadMembers() }
        return true
    }

    func isLiveTimelineReady(roomID: String) -> Bool {
        guard connectionStopTask == nil, let client, selectedRoomID == roomID,
            focusedEventID == nil, timeline != nil, timelineHandle != nil,
            let room = try? client.getRoom(roomId: roomID)
        else { return false }
        return room.membership() == .joined
    }

    private static func contains(_ items: [TimelineItem], _ eventID: String) -> Bool {
        items.contains { $0.asEvent().map { MatrixMapping.identifier($0.eventOrTransactionId) } == eventID }
    }

    /// False, without showing the room, when its live timeline does not hold `anchor`.
    @discardableResult
    private func setupRoom(_ id: String, focus: TimelineFocus, eventID: String?, containing anchor: String? = nil)
        async -> Bool
    {
        let token = UUID()
        selection = token
        updateSubscriptions(id)
        // The previous conversation stays up while this one reads its cache, so its rows replace the old ones in
        // one frame; only a slow open shows the room before its rows.
        let handoff = Task { [weak self] in
            try? await Task.sleep(for: LoadingPresentation.handoff)
            guard !Task.isCancelled else { return }
            self?.showConversation(id, eventID: eventID, token: token)
        }
        var missedAnchor = false
        defer {
            handoff.cancel()
            if !missedAnchor { showConversation(id, eventID: eventID, token: token) }
        }
        do {
            let client = try requireClient()
            var pendingRoom = try client.getRoom(roomId: id)
            for _ in 0..<50 where pendingRoom == nil {
                try await Task.sleep(nanoseconds: 200_000_000)
                guard selection == token else { return true }
                pendingRoom = try client.getRoom(roomId: id)
            }
            guard let room = pendingRoom else {
                throw MatrixServiceError.request("This conversation is still loading. Try again in a moment.")
            }
            if room.membership() == .invited { return true }
            let next = try await room.timelineWithConfiguration(configuration: Self.timelineConfiguration(focus))
            guard selection == token else { return true }
            let observer = TimelineObserver { [weak self] items, revision in
                Task { @MainActor [weak self] in
                    guard let self, self.selection == token else { return }
                    self.showTimeline((items, revision), roomID: id)
                }
            }
            let listenerHandle = await next.addListener(listener: observer)
            guard selection == token else {
                listenerHandle.cancel()
                return true
            }
            if let anchor, !Self.contains(observer.snapshot.items, anchor) {
                listenerHandle.cancel()
                missedAnchor = true
                return false
            }
            showConversation(id, eventID: eventID, token: token)
            timeline = next
            timelineHandle = listenerHandle
            if eventID == nil {
                liveTimeline = KeptTimeline(
                    roomID: id, token: token, timeline: next, observer: observer, listener: listenerHandle)
            }
            // The cached rows arrived with the listener; they go up in this same turn.
            showTimeline(observer.snapshot, roomID: id)
            watchTyping(room, token: token)
            Task { [weak self] in
                guard let self, self.selection == token else { return }
                await self.loadMembers()
            }
            if eventID == nil {
                let endReached = try await paginateBackwards(next)
                guard selection == token else { return true }
                hasMoreHistory = !endReached
                // Loading or restoring a timeline does not mean the user has seen it.
                // The visible live viewport submits an exact-event receipt separately.
            }
        } catch {
            guard selection == token else { return true }
            showConversation(id, eventID: eventID, token: token)
            errorMessage = Self.safeError(error)
        }
        return true
    }

    private func showTimeline(_ snapshot: (items: [TimelineItem], revision: Int), roomID: String) {
        guard snapshot.revision > timelineRevision else { return }
        timelineRevision = snapshot.revision
        messages = Performance.measure(.timelineProject, ["items": snapshot.items.count]) {
            project(snapshot.items, roomID: roomID)
        }
        if !messages.isEmpty { Performance.finish(.roomTimeline, ["messages": messages.count]) }
    }

    private func watchTyping(_ room: Room, token: UUID) {
        typingHandle?.cancel()
        typingHandle = room.subscribeToTypingNotifications(
            listener: TypingObserver { [weak self] ids in
                Task { @MainActor [weak self] in
                    guard let self, self.selection == token else { return }
                    let typing = ids.filter { $0 != self.user?.id }.map { id in
                        self.members.first { $0.id == id }?.name ?? id
                    }
                    if typing != self.typingUsers { self.typingUsers = typing }
                }
            })
    }

    /// Recent conversations stay subscribed: sync keeps their timelines whole, and their member lists stay loaded.
    private func updateSubscriptions(_ id: String) {
        let recent = recentTimelines.roomIDs + (liveTimeline.map { [$0.roomID] } ?? [])
        Task { [weak self] in
            do { try await self?.roomSubscriptions.setActiveRoom(id, recent: recent) } catch is CancellationError {
            } catch {
                guard let self, self.selectedRoomID == id else { return }
                self.errorMessage = Self.safeError(error)
            }
        }
    }

    /// Puts `id` on screen in place of the previous conversation, once per open. A live timeline being left stays
    /// open among the recent ones.
    private func showConversation(_ id: String, eventID: String?, token: UUID) {
        guard selection == token, shownSelection != token else { return }
        shownSelection = token
        if let live = liveTimeline {
            live.revision = timelineRevision
            live.messages = messages
            live.members = members
            live.hasMoreHistory = hasMoreHistory
            live.firstUnreadEventID = firstUnreadEventID
            live.eventIDs = eventIDs
            live.mediaSources = mediaSources
            live.thumbnailSources = thumbnailSources
            live.media = mainMedia
            live.forwardMedia = mainForwardMedia
            live.sendFailures = mainSendFailures
            live.projections = mainProjections
            for closed in recentTimelines.keep(live, for: live.roomID) { closed.listener.cancel() }
        } else {
            timelineHandle?.cancel()
        }
        liveTimeline = nil
        mainProjections = [:]
        threadProjections = [:]
        mediaFiles.removeAll()
        mainMedia = [:]
        threadMedia = [:]
        mainForwardMedia = [:]
        threadForwardMedia = [:]
        replyPreviewLoads.removeAll()
        // Per-item lookups belong to the open timelines only; without this they grow with every room visited.
        eventIDs.removeAll()
        mediaSources.removeAll()
        thumbnailSources.removeAll()
        mainSendFailures = [:]
        threadSendFailures = [:]
        sendFailures = [:]
        selectedRoomID = id
        focusedEventID = eventID
        messages = []
        threadMessages = []
        members = []
        canMentionRoom = false
        typingUsers = []
        errorMessage = nil
        hasMoreHistory = true
        hasMoreThreadHistory = true
        firstUnreadEventID = nil
        lastAutomaticReceipt = nil
        readyThreadReadSelection = nil
        lastThreadReceipt = nil
        hasMoreForwardHistory = eventID != nil
        isLoadingForwardHistory = false
        forwardLoadID = nil
        timelineRevision = 0
        threadRevision = 0
        timelineHandle = nil
        typingHandle?.cancel()
        threadHandle?.cancel()
        timeline = nil
        threadTimeline = nil
        loadedThreadRootID = nil
    }

    private static func timelineConfiguration(_ focus: TimelineFocus) -> TimelineConfiguration {
        TimelineConfiguration(
            focus: focus, filter: .all, internalIdPrefix: nil, dateDividerMode: .daily, trackReadReceipts: .allEvents,
            reportUtds: false)
    }

    /// What one timeline item contributes to its timeline's rows and lookups, worked out once: the SDK hands an
    /// unchanged item back as the same object, so an update maps only the items it changed.
    private struct ItemProjection {
        /// Held so its identity, the cache key, stays unique.
        let item: TimelineItem
        var unread = UnreadMapping.Mark()
        var id: String?
        var eventOrTransactionId: EventOrTransactionId?
        var isRemote = false
        var failure: MessageSendFailure?
        var forwardMedia: ForwardMediaRevision?
        var media: MediaSource?
        /// Images, files and videos say whether they have a thumbnail; other kinds leave the lookup alone.
        var thumbnail: ThumbnailSource??
        var message: ChatMessage?
    }
    private typealias Projections = [ObjectIdentifier: ItemProjection]
    private var mainProjections: Projections = [:]
    private var threadProjections: Projections = [:]

    private func projection(of item: TimelineItem, roomID: String) -> ItemProjection {
        var result = ItemProjection(item: item)
        let event = item.asEvent()
        guard let event else {
            result.unread = UnreadMapping.mark(virtual: item.asVirtual(), event: nil, shown: false)
            return result
        }
        let id = MatrixMapping.identifier(event.eventOrTransactionId)
        result.id = id
        result.eventOrTransactionId = event.eventOrTransactionId
        result.isRemote = event.isRemote
        result.failure = MessageSendFailure.failure(event.localSendState)
        if case .msgLike(let content) = event.content, case .message(let message) = content.kind {
            result.forwardMedia = (try? ForwardMessageContent(message))?.mediaRevision
            switch message.msgType {
            case .image(let value):
                result.media = value.source
                result.thumbnail = .some(
                    value.info?.thumbnailSource.map {
                        ThumbnailSource(source: $0, size: value.info?.thumbnailInfo?.size)
                    })
            case .file(let value):
                result.media = value.source
                result.thumbnail = .some(
                    value.info?.thumbnailSource.map {
                        ThumbnailSource(source: $0, size: value.info?.thumbnailInfo?.size)
                    })
            case .video(let value):
                result.media = value.source
                result.thumbnail = .some(
                    value.info?.thumbnailSource.map {
                        ThumbnailSource(source: $0, size: value.info?.thumbnailInfo?.size)
                    })
            case .audio(let value): result.media = value.source
            default: break
            }
        }
        result.message = MatrixMapping.message(event, roomID: roomID, ownUserID: user?.id, uniqueID: item.uniqueId().id)
        result.unread = UnreadMapping.mark(virtual: nil, event: event, shown: result.message != nil)
        return result
    }

    private func project(_ items: [TimelineItem], roomID: String, inThread: Bool = false) -> [ChatMessage] {
        var failures: [SendQueueMessageKey: MessageSendFailure] = [:]
        var shownMedia: [String: ShownMedia] = [:]
        var forwardMedia: [String: ForwardMediaRevision] = [:]
        let cached = inThread ? threadProjections : mainProjections
        var projections = Projections(minimumCapacity: items.count)
        var marks: [UnreadMapping.Mark] = []
        marks.reserveCapacity(items.count)
        var projected: [ChatMessage] = []
        projected.reserveCapacity(items.count)
        for item in items {
            let key = ObjectIdentifier(item)
            let projection = cached[key] ?? projection(of: item, roomID: roomID)
            projections[key] = projection
            marks.append(projection.unread)
            guard let id = projection.id, let eventOrTransactionId = projection.eventOrTransactionId else { continue }
            eventIDs[id] = eventOrTransactionId
            if let failure = projection.failure {
                failures[SendQueueMessageKey(roomID: roomID, messageID: id)] = failure
            }
            forwardMedia[id] = projection.forwardMedia
            if let media = projection.media { mediaSources[id] = media }
            if let thumbnail = projection.thumbnail { thumbnailSources[id] = thumbnail }
            guard let mapped = projection.message else { continue }
            if projection.isRemote, id.hasPrefix("$"), !mapped.isRedacted, let attachment = mapped.attachment,
                let source = mediaSources[id]
            {
                shownMedia[id] = ShownMedia(source: source, attachment: attachment, identity: source.toJson())
            }
            projected.append(mapped)
        }
        if inThread {
            threadProjections = projections
            threadMedia = shownMedia
            threadForwardMedia = forwardMedia
            threadSendFailures = failures
        } else {
            mainProjections = projections
            mainMedia = shownMedia
            mainForwardMedia = forwardMedia
            mainSendFailures = failures
            firstUnreadEventID = UnreadMapping.firstUnreadEventID(in: marks)
        }
        sendFailures = mainSendFailures.merging(threadSendFailures) { _, latest in latest }
        return projected
    }

    /// `draft` is the composer's Matrix HTML.
    func sendMessage(_ draft: String, threadRootID: String? = nil, replyToID: String? = nil, roomID: String? = nil)
        async throws
    {
        try assertDestination(roomID)
        let message = ComposerFormat.message(draft: draft)
        guard !message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = selection
        let target: Timeline
        if let threadRootID {
            _ = try requireClient()
            guard threadRootID == loadedThreadRootID, let threadTimeline else {
                throw MatrixServiceError.request("Reopen the thread to reply.")
            }
            target = threadTimeline
        } else {
            target = try requireTimeline()
        }
        _ = try requireRoom(roomID)
        let content = try MatrixMapping.content(message).withMentions(
            mentions: mentions(message))
        // Thread timelines infer their own relation. Extra JSON cannot override
        // that fallback relation, so an explicit quote must use sendReply.
        if let reply = replyToID {
            _ = try await target.sendReply(msg: content, eventId: reply)
        } else {
            _ = try await target.send(msg: content)
        }
        await returnToLive(after: token, threadRootID: threadRootID)
    }

    /// Any timeline sends into the room's queue; a message sent from one loaded around an older message then shows
    /// in the live timeline, as sending in Slack takes you to the present.
    private func returnToLive(after token: UUID, threadRootID: String?) async {
        guard threadRootID == nil, focusedEventID != nil, selection == token, let id = selectedRoomID else { return }
        await selectRoom(id)
    }

    func loadMore() async throws -> Bool {
        let target = try requireTimeline()
        let token = selection
        let endReached = try await paginateBackwards(target)
        if selection == token { hasMoreHistory = !endReached }
        return endReached
    }

    /// The timeline asks for older history as the reader nears the top, possibly while the room's first page is still
    /// loading; a request then joins the page in flight instead of starting a second one.
    private func paginateBackwards(_ timeline: Timeline) async throws -> Bool {
        if let current = backwardPage, current.timeline === timeline { return try await current.task.value }
        let task = Task { try await timeline.paginateBackwards(numEvents: 100) }
        backwardPage = (timeline, task)
        defer { if backwardPage?.timeline === timeline { backwardPage = nil } }
        return try await task.value
    }
    private var backwardPage: (timeline: Timeline, task: Task<Bool, Error>)?

    func loadMoreForward() async throws -> Bool {
        guard let focused = focusedEventID else {
            throw MatrixServiceError.request("Open a message from history before loading newer context.")
        }
        guard hasMoreForwardHistory else { return true }
        guard forwardLoadID == nil else { throw MatrixServiceError.request("Newer messages are already loading.") }
        let target = try requireTimeline()
        let room = try requireRoom()
        let account = sessionGeneration
        let token = selection
        let operation = UUID()
        forwardLoadID = operation
        isLoadingForwardHistory = true
        defer {
            if forwardLoadID == operation {
                forwardLoadID = nil
                isLoadingForwardHistory = false
            }
        }
        let validate = {
            try Task.checkCancellation()
            guard self.sessionGeneration == account, self.selection == token, self.focusedEventID == focused,
                self.connectionStopTask == nil, room.membership() == .joined
            else { throw CancellationError() }
        }
        do {
            let endReached = try await UnreadSDKActions.loadForward(timeline: target, validate: validate)
            hasMoreForwardHistory = !endReached
            return endReached
        } catch {
            try validate()
            throw error
        }
    }

    /// The page a thread is loading, shared by the pane's first page and its history row.
    private var threadPage: (selection: UUID, task: Task<Bool, Error>)?
    func loadMoreThread(rootID: String) async throws -> Bool {
        guard loadedThreadRootID == rootID, let threadTimeline else { throw MatrixServiceError.noRoom }
        let token = threadSelection
        let page =
            threadPage?.selection == token
            ? threadPage!.task : Task { try await threadTimeline.paginateBackwards(numEvents: 50) }
        threadPage = (token, page)
        defer { if threadPage?.task == page { threadPage = nil } }
        let endReached = try await page.value
        if threadSelection == token, loadedThreadRootID == rootID {
            hasMoreThreadHistory = !endReached
            readyThreadReadSelection = token
        }
        return endReached
    }
    func loadThread(_ root: ChatMessage) async throws {
        try assertDestination(root.roomID)
        threadProjections = [:]
        threadMedia = [:]
        threadForwardMedia = [:]
        readyThreadReadSelection = nil
        lastThreadReceipt = nil
        threadHandle?.cancel()
        // The root keeps one identity in the pane from the moment it opens, whichever timeline it came from.
        var opening = root
        opening.id = root.eventID
        threadMessages = [opening]
        threadRevision = 0
        threadTimeline = nil
        loadedThreadRootID = nil
        hasMoreThreadHistory = true
        let token = selection
        let threadToken = UUID()
        threadSelection = threadToken
        threadSendFailures = [:]
        sendFailures = mainSendFailures
        let next = try await requireRoom(root.roomID).timelineWithConfiguration(
            configuration: Self.timelineConfiguration(.thread(rootEventId: root.eventID)))
        guard token == selection, threadToken == threadSelection else { return }
        threadTimeline = next
        loadedThreadRootID = root.eventID
        let listenerHandle = await next.addListener(
            listener: TimelineObserver { [weak self] items, revision in
                Task { @MainActor [weak self] in
                    guard let self, token == self.selection, threadToken == self.threadSelection,
                        revision > self.threadRevision
                    else { return }
                    self.threadRevision = revision
                    var messages = Performance.measure(.timelineProject, ["items": items.count]) {
                        self.project(items, roomID: root.roomID, inThread: true)
                    }
                    if let index = messages.firstIndex(where: { $0.eventID == root.eventID }) {
                        messages[index].id = root.eventID
                    }
                    self.threadMessages = messages
                }
            })
        guard token == selection, threadToken == threadSelection else {
            listenerHandle.cancel()
            return
        }
        threadHandle = listenerHandle
        // The pane shows what the SDK has cached now; the first page arrives whenever the network allows.
        Task { _ = try? await loadMoreThread(rootID: root.eventID) }
    }

    private func actionMedia(_ target: MessageActionTarget) throws -> ShownMedia {
        let (_, message) = try actionTimeline(target)
        let shown = target.surface == .conversation ? mainMedia[message.eventID] : threadMedia[message.eventID]
        guard let shown, shown.attachment == message.attachment else {
            throw MatrixServiceError.request("This attachment is updating. Reload the message and try again.")
        }
        return shown
    }
    func mediaCaptionSourceRevision(_ target: MessageActionTarget) -> MediaCaptionRevision? {
        guard let media = try? actionMedia(target), let current = currentActionMessage(target) else {
            return nil
        }
        return MediaCaptionRevision(
            attachment: media.attachment, source: media.identity, kind: current.kind, caption: current.mediaCaption,
            formattedCaption: current.formattedBody.map { FormattedBody(format: .html, body: $0) })
    }
    func loadMediaCaption(_ target: MessageActionTarget) async throws -> MediaCaptionSnapshot {
        let (timeline, _) = try actionTimeline(target)
        _ = try actionMedia(target)
        do {
            let event = try await timeline.getEventTimelineItemByEventId(eventId: target.message.eventID)
            _ = try actionTimeline(target)
            guard event.isRemote, event.isEditable, event.isOwn, event.sender == user?.id,
                event.sender == target.message.senderID,
                MatrixMapping.identifier(event.eventOrTransactionId) == target.message.eventID,
                case .msgLike(let value) = event.content, case .message(let content) = value.kind
            else { throw MediaCaptionError.unsupported }
            if case .thread(let rootID) = target.surface {
                guard target.message.eventID == rootID || value.threadRoot == rootID else { throw CancellationError() }
            }
            if let state = event.editSendState { if case .sent = state {} else { throw MediaCaptionError.unconfirmed } }
            guard event.redactionSendState == nil else { throw MediaCaptionError.unconfirmed }
            let media = try MediaCaptionContent(content)
            let shown = try actionMedia(target)
            guard let mapped = MatrixMapping.message(event, roomID: target.message.roomID, ownUserID: user?.id),
                !mapped.isRedacted, mapped.attachment == shown.attachment, media.source.toJson() == shown.identity
            else { throw MediaCaptionError.sourceUpdating }
            return MediaCaptionSnapshot(
                target: target, message: mapped, media: media,
                revision: MediaCaptionRevision(
                    attachment: shown.attachment, source: shown.identity, kind: mapped.kind, caption: media.caption,
                    formattedCaption: media.formattedCaption))
        } catch {
            _ = try actionTimeline(target)
            throw error
        }
    }
    func saveMediaCaption(_ snapshot: MediaCaptionSnapshot, caption: String?) async throws -> MediaCaptionSavedResult {
        try validateMessageAction(snapshot.target)
        guard captionSaves.insert(snapshot.id).inserted else { throw MediaCaptionError.busy }
        defer { captionSaves.remove(snapshot.id) }
        do {
            let current = try await loadMediaCaption(snapshot.target)
            guard current.revision == snapshot.revision else { throw MediaCaptionReviewChanged(snapshot: current) }
            guard caption != current.caption else {
                return MediaCaptionSavedResult(snapshotID: snapshot.id, queued: false)
            }
            let (timeline, _) = try actionTimeline(snapshot.target)
            _ = try actionMedia(snapshot.target)
            let payload = try current.media.payload(caption: caption)
            try await timeline.edit(
                eventOrTransactionId: .eventId(eventId: snapshot.message.eventID),
                newContent: .roomMessage(content: payload)
            )
            // The edit has entered the SDK queue. A later scope change must not
            // turn acceptance into an error that invites a duplicate edit.
            return MediaCaptionSavedResult(snapshotID: snapshot.id, queued: true)
        } catch {
            try validateMessageAction(snapshot.target)
            throw error
        }
    }
    #if DEBUG
    func projectMediaCaptionForChecks(_ items: [TimelineItem], roomID: String, inThread: Bool) {
        if inThread {
            threadMessages = project(items, roomID: roomID, inThread: true)
        } else {
            messages = project(items, roomID: roomID)
        }
    }
    #endif

    func forwardMessageSourceRevision(_ target: MessageActionTarget) -> ForwardMessageSourceRevision? {
        guard isCurrentMessageAction(target), let current = currentActionMessage(target) else { return nil }
        return ForwardMessageSourceRevision(
            kind: current.kind, body: current.body, formattedBody: current.formattedBody,
            redacted: current.isRedacted, sendState: current.sendState,
            media: target.surface == .conversation
                ? mainForwardMedia[current.eventID] : threadForwardMedia[current.eventID])
    }
    func loadForwardMessage(_ target: MessageActionTarget) async throws -> ForwardMessageReview {
        let (source, mapped) = try actionTimeline(target)
        if mapped.supportsCaptionEditing { _ = try actionMedia(target) }
        do {
            let event = try await source.getEventTimelineItemByEventId(eventId: target.message.eventID)
            _ = try actionTimeline(target)
            guard event.isRemote, MatrixMapping.identifier(event.eventOrTransactionId) == target.message.eventID,
                event.sender == target.message.senderID,
                case .msgLike(let value) = event.content, case .message(let content) = value.kind
            else { throw ForwardMessageError.unsupported }
            if case .thread(let rootID) = target.surface {
                guard target.message.eventID == rootID || value.threadRoot == rootID else { throw CancellationError() }
            }
            if let state = event.editSendState {
                if case .sent = state {} else { throw ForwardMessageError.unconfirmed }
            }
            if event.redactionSendState != nil { throw ForwardMessageError.unconfirmed }
            let copied = try ForwardMessageContent(content)
            guard let message = MatrixMapping.message(event, roomID: target.message.roomID, ownUserID: user?.id),
                ForwardMessageContent.supports(message)
            else { throw ForwardMessageError.unsupported }
            if let mediaRevision = copied.mediaRevision {
                let shown = try actionMedia(target)
                guard message.attachment == shown.attachment,
                    try MediaCaptionContent(content).source.toJson() == shown.identity,
                    mediaRevision
                        == (target.surface == .conversation
                            ? mainForwardMedia[message.eventID] : threadForwardMedia[message.eventID])
                else { throw ForwardMessageError.sourceUpdating }
            }
            return ForwardMessageReview(target: target, message: message, value: copied, content: content)
        } catch {
            _ = try actionTimeline(target)
            throw error
        }
    }
    func forwardMessage(_ review: ForwardMessageReview, to roomID: String) async throws -> ForwardMessageQueuedResult {
        try validateMessageAction(review.target)
        guard forwardingReviews.insert(review.id).inserted else { throw ForwardMessageError.busy }
        defer { forwardingReviews.remove(review.id) }
        do {
            let initial = try await loadForwardMessage(review.target)
            guard initial.value == review.value else { throw ForwardMessageReviewChanged(review: initial) }
            let client = try requireClient()
            guard rooms.contains(where: { $0.id == roomID && $0.membership == "join" && !$0.isSpace }),
                let destination = try client.getRoom(roomId: roomID), destination.membership() == .joined
            else { throw ForwardMessageError.unavailableDestination }
            @MainActor func validate() throws {
                try self.validateMessageAction(review.target)
                guard self.client === client, destination.membership() == .joined,
                    self.rooms.contains(where: { $0.id == roomID && $0.membership == "join" && !$0.isSpace })
                else { throw ForwardMessageError.unavailableDestination }
            }
            let configuration = TimelineConfiguration(
                focus: .live(hideThreadedEvents: true), filter: .all,
                internalIdPrefix: nil, dateDividerMode: .daily, trackReadReceipts: .disabled, reportUtds: false)
            let destinationTimeline = try await destination.timelineWithConfiguration(configuration: configuration)
            try validate()
            // An encrypted message must not reach the server in plaintext, attachment keys included.
            if try await destination.latestEncryptionState() != .encrypted {
                try validate()
                let source = try requireRoom(review.target.message.roomID)
                guard try await source.latestEncryptionState() == .notEncrypted else {
                    throw ForwardMessageError.unencryptedDestination
                }
            }
            try validate()
            let powers = try await destination.getPowerLevels()
            try validate()
            guard powers.canOwnUserSendMessage(message: .roomMessage) else { throw ForwardMessageError.forbidden }
            // Re-read the original pane after destination setup. The reviewed
            // text, formatting and media must still be the exact SDK payload sent.
            let current = try await loadForwardMessage(review.target)
            guard current.value == review.value else { throw ForwardMessageReviewChanged(review: current) }
            try validate()
            let content = try current.payload()
            _ = try await destinationTimeline.send(msg: content)
            // Queued: a failure reported after this point would invite a duplicate resend.
            return ForwardMessageQueuedResult(reviewID: review.id, destinationRoomID: roomID)
        } catch {
            try validateMessageAction(review.target)
            throw error
        }
    }

    func loadReplyPreview(for target: MessageActionTarget) async {
        guard let request = target.replyPreviewIdentity else { return }
        do {
            let (timeline, current) = try actionTimeline(target)
            guard current.replyToID == request.replyID, current.replyPreview?.state != .ready,
                replyPreviewLoads.insert(request).inserted
            else { return }
            defer { replyPreviewLoads.remove(request) }
            try await timeline.fetchDetailsForEvent(eventId: current.eventID)
            // The fetched details arrive through each timeline's own listener.
            let (_, latest) = try actionTimeline(target)
            guard latest.replyToID == request.replyID else { return }
        } catch {
            guard !Task.isCancelled, isCurrentMessageAction(target) else { return }
            updateReplyPreview(
                for: target,
                preview: ChatReplyPreview(
                    state: .failed, eventID: request.replyID,
                    body: "Original message unavailable"))
        }
    }

    private func updateReplyPreview(for target: MessageActionTarget, preview: ChatReplyPreview) {
        do { try validateMessageAction(target) } catch { return }
        guard let current = currentActionMessage(target), current.sendState == "sent", !current.isRedacted,
            current.replyToID == preview.eventID,
            current.replyToID == target.message.replyToID, current.replyPreview?.state != .ready
        else { return }
        switch target.surface {
        case .conversation:
            guard
                let index = messages.firstIndex(where: { $0.eventID == current.eventID && $0.roomID == current.roomID })
            else {
                return
            }
            messages[index].replyPreview = preview
        case .thread:
            guard
                let index = threadMessages.firstIndex(where: {
                    $0.eventID == current.eventID && $0.roomID == current.roomID
                })
            else { return }
            threadMessages[index].replyPreview = preview
        }
    }

    func editMessage(_ target: MessageActionTarget, body: String) async throws {
        let (timeline, current) = try actionTimeline(target)
        guard current.supportsTextEditing, current.senderID == user?.id else {
            throw MatrixServiceError.request("This message can’t be edited.")
        }
        do {
            try await timeline.edit(
                eventOrTransactionId: .eventId(eventId: target.message.eventID),
                newContent: .roomMessage(content: MatrixMapping.content(ComposerFormat.message(draft: body))))
            try validateMessageAction(target)
        } catch {
            try validateMessageAction(target)
            throw error
        }
    }
    func deleteMessage(_ target: MessageActionTarget) async throws {
        let (timeline, current) = try actionTimeline(target)
        guard current.senderID == user?.id else {
            throw MatrixServiceError.request("You can only delete your own messages.")
        }
        do {
            try await timeline.redactEvent(eventOrTransactionId: .eventId(eventId: target.message.eventID), reason: nil)
            try validateMessageAction(target)
        } catch {
            try validateMessageAction(target)
            throw error
        }
    }
    func toggleReaction(_ target: MessageActionTarget, key: String) async throws {
        let (timeline, current) = try actionTimeline(target)
        do {
            _ = try await timeline.toggleReaction(itemId: .eventId(eventId: target.message.eventID), key: key)
            try validateMessageAction(target)
        } catch {
            try validateMessageAction(target)
            throw error
        }
        if !current.reactions.contains(where: { $0.key == key && $0.mine }) { useEmoji(key) }
    }

    func loadRecentEmoji() async {
        let generation = sessionGeneration
        guard let client, let recent = try? await client.getRecentEmojis(), sessionGeneration == generation else {
            return
        }
        recentEmoji = recent.map(\.emoji)
    }

    /// Shown at once; the account data follows, and losing that write only loses the order elsewhere.
    private func useEmoji(_ emoji: String) {
        recentEmoji = EmojiRecents.adding(emoji, to: recentEmoji)
        guard let client else { return }
        Task { try? await client.addRecentEmoji(emoji: emoji) }
    }

    func uploadFile(_ url: URL, threadRootID: String? = nil, roomID: String? = nil) async throws {
        try assertDestination(roomID)
        let token = selection
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let mime = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        let relation: String? = try threadRootID.map {
            try Self.json([
                "m.relates_to": [
                    "rel_type": "m.thread", "event_id": $0, "is_falling_back": true, "m.in_reply_to": ["event_id": $0],
                ]
            ])
        }
        let parameters = UploadParameters(
            source: .file(filename: url.path), caption: nil, formattedCaption: nil, mentions: nil, inReplyTo: nil,
            extraContentJson: relation)
        let kind: AttachmentKind
        if mime.hasPrefix("image/") {
            let shape = Self.displayedSize(url)
            kind = .image(
                imageInfo: ImageInfo(
                    height: shape?.height, width: shape?.width, mimetype: mime, size: values.fileSize.map(UInt64.init),
                    thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil), thumbnailSource: nil)
        } else {
            kind = .file(
                fileInfo: FileInfo(
                    mimetype: mime, size: values.fileSize.map(UInt64.init), thumbnailInfo: nil, thumbnailSource: nil))
        }
        let target: Timeline
        if let threadRootID, threadRootID == loadedThreadRootID, let threadTimeline {
            _ = try requireClient()
            target = threadTimeline
        } else {
            target = try requireTimeline()
        }
        let handle = try target.sendAttachment(params: parameters, attachment: kind)
        await returnToLive(after: token, threadRootID: threadRootID)
        try await handle.join()
    }

    /// An image's size upright, from its header alone: EXIF orientations 5 to 8 turn it a quarter, swapping the sides.
    private static func displayedSize(_ url: URL) -> (width: UInt64, height: UInt64)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? UInt64,
            let height = properties[kCGImagePropertyPixelHeight] as? UInt64
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// The attachment as an open timeline shows it now, or nil once it was deleted, replaced or left the view.
    private func shownMedia(_ message: ChatMessage) -> (media: ShownMedia, inThread: Bool)? {
        guard !isPreview, message.roomID == selectedRoomID, !message.isRedacted else { return nil }
        if let main = mainMedia[message.eventID], main.attachment == message.attachment { return (main, false) }
        if let reply = threadMedia[message.eventID], reply.attachment == message.attachment { return (reply, true) }
        return nil
    }
    func attachmentSourceRevision(_ message: ChatMessage) -> Data? {
        if isPreview { return message.attachment.map { Data($0.url.utf8) } }
        return shownMedia(message).map { Data($0.media.identity.utf8) }
            ?? sharedFiles.item(for: message)?.mediaRevision
    }
    func prepareAttachmentPreview(_ message: ChatMessage) async throws -> AttachmentPreviewLease {
        if isPreview {
            guard let url = message.attachment.flatMap(PreviewMedia.file) else { throw MatrixServiceError.preview }
            return AttachmentPreviewLease(url: url, handle: nil) { true }
        }
        // A file opened from Files, whose conversation may be closed, comes through Files' own timeline.
        if shownMedia(message) == nil, let item = sharedFiles.item(for: message) {
            return try await sharedFiles.preparePreview(item)
        }
        let client = try requireClient()
        guard connectionStopTask == nil, let shown = shownMedia(message),
            let room = try client.getRoom(roomId: message.roomID), room.membership() == .joined
        else { throw CancellationError() }
        let session = sessionGeneration
        let timeline = selection
        let thread = shown.inThread ? threadSelection : nil
        let identity = shown.media.identity
        return try await mediaFiles.file(
            source: shown.media.source, identity: identity, attachment: shown.media.attachment, client: client
        ) { [weak self] in
            guard let self, self.client != nil, self.connectionStopTask == nil, self.sessionGeneration == session,
                self.selection == timeline, thread == nil || self.threadSelection == thread,
                room.membership() == .joined
            else { return false }
            return self.shownMedia(message)?.media.identity == identity
        }
    }

    func avatarThumbnail(_ source: String, side: UInt64 = 128) async throws -> Data {
        guard source.utf8.count <= 2048, source.rangeOfCharacter(from: .controlCharacters) == nil,
            let url = URLComponents(string: source), url.scheme == "mxc", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.path.hasPrefix("/"), !url.path.dropFirst().isEmpty, !url.path.dropFirst().contains("/")
        else { throw MatrixServiceError.invalidHomeserver }
        let client = try requireClient()
        let token = sessionGeneration
        let data = try await client.getMediaThumbnail(
            mediaSource: MediaSource.fromUrl(url: source), width: side, height: side)
        guard token == sessionGeneration else { throw CancellationError() }
        guard data.count <= 2 * 1024 * 1024 else {
            throw MatrixServiceError.request("This avatar thumbnail is too large to display.")
        }
        return data
    }

    func openThreads(workspaceID: String?) async {
        do {
            let client = try requireClient()
            let token = sessionGeneration
            await threadFeed.open(client: client, rooms: rooms, workspaceID: workspaceID) { [weak self] ids in
                guard let self, self.sessionGeneration == token else { throw CancellationError() }
                try await self.roomSubscriptions.setFeedRooms(ids)
            }
        } catch { threadFeed.unavailable(Self.safeError(error)) }
    }

    func checkMoreThreads() async { await threadFeed.checkMore() }
    func loadOlderThreads(roomID: String) async { await threadFeed.loadOlder(roomID: roomID) }
    func retryThreads(roomID: String) async { await threadFeed.retry(roomID: roomID) }
    func closeThreads() {
        threadFeed.close()
        let token = sessionGeneration
        Task { [weak self] in
            guard let self, self.sessionGeneration == token, self.client != nil, !self.threadFeed.isActive else {
                return
            }
            do { try await self.roomSubscriptions.setFeedRooms([]) } catch {
                if self.sessionGeneration == token { self.errorMessage = Self.safeError(error) }
            }
        }
    }

    func thumbnailData(_ message: ChatMessage, width: UInt64 = 840, height: UInt64 = 520) async throws -> Data {
        if isPreview {
            guard let data = message.attachment.flatMap(PreviewMedia.thumbnail) else {
                throw MatrixServiceError.preview
            }
            return data
        }
        if mediaSources[message.eventID] == nil, let item = sharedFiles.item(for: message) {
            return try await sharedFiles.thumbnailData(item)
        }
        let client = try requireClient()
        guard let original = mediaSources[message.eventID] else { throw MatrixServiceError.noRoom }
        // A video's own file is no picture, so it has a poster only when the sender attached one.
        guard message.kind != "m.video" || thumbnailSources[message.eventID] != nil else {
            throw MatrixServiceError.request("This video has no poster.")
        }
        // The send queue keeps what you send in the media store as whole files; the server has no thumbnail yet.
        if message.sendState != "sent" {
            return try await client.getMediaContent(
                mediaSource: thumbnailSources[message.eventID]?.source ?? original)
        }
        let limit = MatrixMapping.maximumAutomaticPreviewBytes
        let source: MediaSource
        if let thumbnail = thumbnailSources[message.eventID], thumbnail.source.url() != original.url() {
            guard MatrixMapping.permitsAutomaticOriginalPreview(size: thumbnail.size) else {
                throw MatrixServiceError.request(
                    "A small thumbnail is unavailable. Download the attachment to view it.")
            }
            source = thumbnail.source
        } else {
            // Encrypted media is fully downloaded by the SDK even through its thumbnail API. Unknown original sizes are
            // unsafe to preview automatically.
            guard MatrixMapping.permitsAutomaticOriginalPreview(size: message.attachment?.size) else {
                throw MatrixServiceError.request(
                    "A small thumbnail is unavailable. Download the attachment to view the original.")
            }
            source = original
        }
        let data = try await client.getMediaThumbnail(
            mediaSource: source, width: min(max(width, 1), 2048), height: min(max(height, 1), 2048))
        guard data.count <= Int(limit) else {
            throw MatrixServiceError.request(
                "This thumbnail is too large to preview. Download the attachment to view it.")
        }
        return data
    }

    func markVisibleThreadRead(_ target: ThreadReadReceiptTarget, isVisible: @escaping @MainActor () -> Bool)
        async throws
    {
        guard isVisible() else { throw CancellationError() }
        let original = try validatedThreadReadTimeline(target)
        try await readDelivery.perform(roomID: target.identity.roomID) { [weak self] in
            guard let self else { throw CancellationError() }
            guard isVisible() else { throw CancellationError() }
            _ = try self.validatedThreadReadTimeline(target)
            guard self.lastThreadReceipt != target else { return }
            // The thread timeline adds the thread ID to the receipt.
            try await original.sendReadReceipt(receiptType: .read, eventId: target.eventID)
            guard isVisible() else { throw CancellationError() }
            _ = try self.validatedThreadReadTimeline(target)
            self.lastThreadReceipt = target
            self.requestRefresh()
        }
    }
    private func validatedThreadReadTimeline(_ target: ThreadReadReceiptTarget) throws -> Timeline {
        try Task.checkCancellation()
        guard threadReadIdentity == target.identity, let threadTimeline,
            let last = threadMessages.last(where: { $0.eventID.hasPrefix("$") }),
            last.roomID == target.identity.roomID, last.eventID == target.eventID, last.sendState == "sent",
            last.kind != "m.room.encrypted",
            last.eventID == target.identity.rootID || last.threadRootID == target.identity.rootID,
            try requireRoom(target.identity.roomID).membership() == .joined
        else { throw CancellationError() }
        return threadTimeline
    }
    #if DEBUG
    func configureThreadReadForChecks(
        client: Client, main: Timeline, thread: Timeline?, rootID: String?, sessionID: UUID, selectionID: UUID,
        threadID: UUID, ready: Bool
    ) {
        configureMessageActionsForChecks(
            client: client, main: main, thread: thread, rootID: rootID, sessionID: sessionID, selectionID: selectionID,
            threadID: threadID)
        readyThreadReadSelection = ready ? threadID : nil
    }
    #endif

    func markVisibleRead(_ target: ReadReceiptTarget) async throws {
        guard lastAutomaticReceipt != target else { return }
        let originalTimeline = try validatedReadTimeline(target)
        let originalRoom = try requireRoom(target.roomID)
        try await readDelivery.perform(roomID: target.roomID) { [weak self] in
            guard let self else { throw CancellationError() }
            try await UnreadSDKActions.acknowledge(timeline: originalTimeline, eventID: target.eventID) {
                _ = try self.validatedReadTimeline(target)
            }
            if self.rooms.first(where: { $0.id == target.roomID })?.isMarkedUnread == true {
                try await originalRoom.setUnreadFlag(newValue: false)
                _ = try self.validatedReadTimeline(target)
            }
            self.lastAutomaticReceipt = target
            self.requestRefresh()
        }
    }

    private func validatedReadTimeline(_ target: ReadReceiptTarget) throws -> Timeline {
        try Task.checkCancellation()
        guard !isPreview, connectionStopTask == nil, target.accountID == user?.id,
            target.sessionGeneration == sessionGeneration,
            target.timelineGeneration == selection, target.roomID == selectedRoomID, focusedEventID == nil,
            target.eventID.hasPrefix("$"),
            messages.last(where: { $0.eventID.hasPrefix("$") })?.eventID == target.eventID,
            try requireRoom(target.roomID).membership() == .joined
        else { throw CancellationError() }
        return try requireTimeline()
    }

    func setMarkedUnread(_ roomID: String, value: Bool) async throws {
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation before changing its read state.")
        }
        lastAutomaticReceipt = nil
        lastThreadReceipt = nil
        try await readDelivery.perform(roomID: roomID) { [weak self] in
            guard let self, self.sessionGeneration == account, self.connectionStopTask == nil, !self.isPreview else {
                throw CancellationError()
            }
            try Task.checkCancellation()
            guard room.membership() == .joined else { throw MatrixServiceError.noRoom }
            if !value {
                try await UnreadSDKActions.markRoomRead(room: room) {
                    try Task.checkCancellation()
                    guard self.sessionGeneration == account, self.connectionStopTask == nil, !self.isPreview,
                        room.membership() == .joined
                    else { throw CancellationError() }
                }
            }
            try await room.setUnreadFlag(newValue: value)
            guard self.sessionGeneration == account, self.connectionStopTask == nil else { throw CancellationError() }
            self.requestRefresh()
        }
    }

    func setFavorite(_ room: ChatRoom, value: Bool) async throws {
        try await requireRoom(room.id).setIsFavourite(isFavourite: value, tagOrder: nil)
        requestRefresh()
    }
    func loadRoomNotificationSettings(roomID: String) async throws -> RoomNotificationSnapshot {
        let client = try requireClient()
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        try validateRoomMutation(account)
        do {
            let snapshot = try await RoomNotificationSettingsService.load(client: client, room: room) {
                try self.validateRoomMutation(account)
            }
            try validateRoomMutation(account)
            return notificationRetries.decorate(snapshot)
        } catch {
            try validateRoomMutation(account)
            throw error
        }
    }
    func loadAccountNotificationDefaults() async throws -> AccountNotificationDefaultsSnapshot {
        let client = try requireClient()
        let account = sessionGeneration
        try validateRoomMutation(account)
        do {
            let snapshot = try await AccountNotificationDefaultsService.load(client: client) {
                try self.validateRoomMutation(account)
            }
            try validateRoomMutation(account)
            return notificationRetries.decorate(snapshot)
        } catch {
            try validateRoomMutation(account)
            throw error
        }
    }
    func saveAccountNotificationDefault(category: AccountNotificationCategory, mode: AccountNotificationMode)
        async throws -> AccountNotificationDefaultsSaveResult
    {
        let client = try requireClient()
        let account = sessionGeneration
        try validateRoomMutation(account)
        let ticket = try notificationRetries.begin(.account(category: category, mode: mode))
        defer { notificationRetries.end(ticket) }
        do {
            let result = try await AccountNotificationDefaultsService.save(
                client: client, category: category, mode: mode
            ) { try self.validateRoomMutation(account) }
            try validateRoomMutation(account)
            notificationRetries.accepted(ticket)
            requestRefresh()
            return result
        } catch {
            try validateRoomMutation(account)
            if error is AccountNotificationDefaultsSaveFailure { notificationRetries.recordFailure(ticket) }
            requestRefresh()
            throw error
        }
    }
    func saveRoomNotificationSettings(roomID: String, choice: RoomNotificationChoice) async throws
        -> RoomNotificationSaveResult
    {
        let client = try requireClient()
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        try validateRoomMutation(account)
        let ticket = try notificationRetries.begin(.room(id: roomID, choice: choice))
        defer { notificationRetries.end(ticket) }
        do {
            let result = try await RoomNotificationSettingsService.save(client: client, room: room, choice: choice) {
                try self.validateRoomMutation(account)
            }
            try validateRoomMutation(account)
            notificationRetries.accepted(ticket)
            requestRefresh()
            return result
        } catch {
            try validateRoomMutation(account)
            if error is RoomNotificationSaveFailure { notificationRetries.recordFailure(ticket) }
            requestRefresh()
            throw error
        }
    }
    func createRoom(name: String, topic: String, workspaceID: String?) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MatrixServiceError.emptyName }
        let client = try requireClient()
        let account = sessionGeneration
        let workspace = try workspaceID.map { try requireRoom($0) }
        do {
            let id = try await RoomManagementActions.createRoom(
                client: client, name: name, topic: topic, workspace: workspace,
                validate: { try self.validateRoomMutation(account) },
                link: { id in
                    if let workspaceID {
                        try self.validateRoomMutation(account)
                        guard let child = try client.getRoom(roomId: id) else { throw MatrixServiceError.noRoom }
                        let ownUserID = try client.userId()
                        try await self.roomSubscriptions.withMutationRoom(roomID: id) {
                            try await RoomReadiness.waitUntilReady(room: child, ownUserID: ownUserID) {
                                try self.validateRoomMutation(account)
                            }
                            try self.validateRoomMutation(account)
                            try await self.addRoomToWorkspace(spaceID: workspaceID, roomID: id)
                        }
                        try self.validateRoomMutation(account)
                    }
                })
            requestRefresh()
            return id
        } catch let partial as RoomCreationPartialFailure {
            requestRefresh()
            throw partial
        }
    }
    func createWorkspace(name: String, topic: String) async throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MatrixServiceError.emptyName }
        let client = try requireClient()
        let account = sessionGeneration
        let id = try await client.createRoom(
            request: CreateRoomParameters(
                name: name, topic: topic, isEncrypted: false, visibility: .private, preset: .privateChat, isSpace: true)
        )
        guard sessionGeneration == account, connectionStopTask == nil else { throw CancellationError() }
        requestRefresh()
        return id
    }
    func addRoomToWorkspace(spaceID: String, roomID: String) async throws {
        try await updateWorkspaceLink(spaceID: spaceID, roomID: roomID, adding: true)
    }
    func removeRoomFromWorkspace(spaceID: String, roomID: String) async throws {
        try await updateWorkspaceLink(spaceID: spaceID, roomID: roomID, adding: false)
    }
    private func updateWorkspaceLink(spaceID: String, roomID: String, adding: Bool) async throws {
        let client = try requireClient()
        let account = sessionGeneration
        let space = try requireRoom(spaceID)
        let child = try requireRoom(roomID)
        let spaces = await client.spaceService()
        try await InvitationPermissions.updateSpaceLink(space: space, child: child, spaces: spaces, adding: adding) {
            try Task.checkCancellation()
            guard self.sessionGeneration == account, self.connectionStopTask == nil, !self.isPreview else {
                throw CancellationError()
            }
        }
        requestRefresh()
    }
    func createDM(userID: String) async throws -> String {
        _ = try requireClient()
        let token = sessionGeneration
        let id = try await people.directRoom(userID: userID)
        guard sessionGeneration == token else { throw CancellationError() }
        requestRefresh()
        return id
    }

    func messagePreview(roomID: String, eventID: String) async throws -> ChatMessage {
        guard eventID.hasPrefix("$"), eventID.utf8.count <= 1024 else {
            throw MatrixServiceError.request("Still sending; try again in a moment.")
        }
        let client = try requireClient()
        let token = sessionGeneration
        guard let room = try client.getRoom(roomId: roomID), room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation to load its saved message.")
        }
        let configuration = TimelineConfiguration(
            focus: .event(eventId: eventID, numContextEvents: 0, threadMode: .automatic(hideThreadedEvents: false)),
            filter: .all, internalIdPrefix: nil, dateDividerMode: .daily, trackReadReceipts: .disabled,
            reportUtds: false)
        let preview = try await savedPreviewLimit.run {
            try await MainActor.run {
                guard token == self.sessionGeneration, room.membership() == .joined else { throw CancellationError() }
            }
            return try await room.timelineWithConfiguration(configuration: configuration)
        }
        guard token == sessionGeneration, room.membership() == .joined, !Task.isCancelled else {
            throw CancellationError()
        }
        let event = try await preview.getEventTimelineItemByEventId(eventId: eventID)
        guard token == sessionGeneration, room.membership() == .joined, !Task.isCancelled else {
            throw CancellationError()
        }
        guard MatrixMapping.identifier(event.eventOrTransactionId) == eventID,
            let message = MatrixMapping.message(event, roomID: roomID, ownUserID: user?.id)
        else { throw MatrixServiceError.request("This message can’t be previewed.") }
        return message
    }
    func joinRoom(_ alias: String) async throws -> String {
        let client = try requireClient()
        let account = sessionGeneration
        let id = try await RoomManagementActions.joinRoom(client: client, address: alias) {
            try self.validateRoomMutation(account)
        }
        requestRefresh()
        return id
    }
    func resolveMatrixLink(_ url: URL) async throws -> MatrixLinkResolution? {
        guard let entity = try MatrixLinkService.parse(url) else { return nil }
        let client = try requireClient()
        let account = sessionGeneration
        let accountID = try client.userId()
        return try await MatrixLinkService.resolve(
            client: client, entity: entity, accountID: accountID, sessionID: account
        ) { try self.validateRoomMutation(account) }
    }
    /// The server's public directory, or one workspace's channels when `spaceID` is set.
    func openPublicDirectory(spaceID: String? = nil) throws {
        let client = try requireClient()
        let account = sessionGeneration
        try validateRoomMutation(account)
        publicDirectory.open(client: client, spaceID: spaceID) { [weak self] in
            guard let self else { throw CancellationError() }
            try self.validateRoomMutation(account)
        }
    }
    func resolvePublicDirectoryEntry(roomID: String, scopeID: UUID) async throws -> MatrixLinkResolution {
        let client = try requireClient()
        let account = sessionGeneration
        let accountID = try client.userId()
        func validate() throws {
            try validateRoomMutation(account)
            guard publicDirectory.scopeID == scopeID,
                let entry = publicDirectory.entries.first(where: { $0.id == roomID })
            else { throw CancellationError() }
            let joined = try client.getRoom(roomId: roomID)?.membership() == .joined
            guard joined || entry.canJoin else {
                throw MatrixServiceError.request("You need an invitation to join this channel.")
            }
        }
        try validate()
        let via = publicDirectory.entries.first { $0.id == roomID }?.via ?? []
        // Directory aliases are display metadata. Resolve the validated canonical
        // ID directly through the same read-only preview used for native links.
        return try await MatrixLinkService.resolve(
            client: client, entity: MatrixEntity(id: .room(id: roomID), via: via), accountID: accountID,
            sessionID: account, validate: validate)
    }
    func joinMatrixRoom(_ request: MatrixRoomJoinRequest) async throws -> MatrixRoomJoinDestination {
        try validateRoomMutation(request.sessionID)
        let client = try requireClient()
        guard try client.userId() == request.accountID else { throw CancellationError() }
        do {
            let result = try await MatrixLinkService.join(client: client, request: request) {
                try self.validateRoomMutation(request.sessionID)
            }
            try validateRoomMutation(request.sessionID)
            requestRefresh()
            return result
        } catch {
            try validateRoomMutation(request.sessionID)
            requestRefresh()
            throw error
        }
    }
    func invite(userID: String, roomID: String) async throws {
        let userID = try PeopleMapping.validatedID(userID)
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        try await InvitationPermissions.invite(room: room, userID: userID) {
            try Task.checkCancellation()
            guard self.sessionGeneration == account, self.connectionStopTask == nil, !self.isPreview else {
                throw CancellationError()
            }
        }
        requestRefresh()
    }
    func leaveRoom(_ roomID: String) async throws {
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        try await RoomManagementActions.leaveRoom(room: room) { try self.validateRoomMutation(account) }
        requestRefresh()
    }
    private func validateRoomMutation(_ account: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == account, connectionStopTask == nil, !isPreview else { throw CancellationError() }
    }
    func loadRoomDetails(roomID: String) async throws -> RoomDetailsSnapshot {
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        return try await RoomDetailsService.load(room: room) { try self.validateRoomMutation(account) }
    }
    func saveRoomDetails(roomID: String, name: String?, topic: String?) async throws -> RoomDetailsSaveResult {
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        try validateRoomMutation(account)
        guard roomDetailsSaves.insert(roomID).inserted else {
            throw MatrixServiceError.request("This conversation’s details are already being saved.")
        }
        defer { if sessionGeneration == account { roomDetailsSaves.remove(roomID) } }
        do {
            let result = try await RoomDetailsService.save(room: room, name: name, topic: topic) {
                try self.validateRoomMutation(account)
            }
            requestRefresh()
            return result
        } catch let partial as RoomDetailsPartialFailure {
            requestRefresh()
            throw partial
        }
    }
    func acceptInvitation(_ roomID: String) async throws -> InvitationDestination {
        try await invitation(roomID, action: .accept)
    }
    func declineInvitation(_ roomID: String) async throws { _ = try await invitation(roomID, action: .decline) }
    private func invitation(_ roomID: String, action: InvitationAction) async throws -> InvitationDestination {
        let room = try requireRoom(roomID)
        let account = sessionGeneration
        let destination = try await invitationActions.perform(room: room, action: action) { [weak self] in
            guard let self else { return false }
            return self.sessionGeneration == account && self.connectionStopTask == nil && !self.isPreview
        }
        requestRefresh()
        return destination
    }
    /// Servers honor a room mention only from someone with the power level for it; for anyone else "@room" is text.
    func mentions(_ message: ComposerFormat.Message) -> Mentions {
        Mentions(userIds: message.mentions, room: message.mentionsRoom && canMentionRoom)
    }

    private nonisolated static func membership(_ state: MembershipState) -> String {
        switch state {
        case .join: "join"
        case .invite: "invite"
        case .leave: "leave"
        case .ban: "ban"
        case .knock: "knock"
        case .custom(let value): value
        }
    }

    func loadMembers() async {
        let token = selection
        do {
            let room = try requireRoom()
            let iterator = try await room.members()
            // nextChunk is a synchronous FFI call; a large room must not stall the main thread.
            let result = await Task.detached(priority: .userInitiated) {
                var result: [ChatUser] = []
                while !Task.isCancelled, let chunk = iterator.nextChunk(chunkSize: 500), !chunk.isEmpty {
                    result += chunk.map {
                        ChatUser(
                            id: $0.userId, name: $0.displayName ?? $0.userId, avatarURL: $0.avatarUrl,
                            membership: Self.membership($0.membership))
                    }
                }
                return result
            }.value
            let canNotify = (try? await room.getPowerLevels().canOwnUserTriggerRoomNotification()) ?? false
            if token == selection {
                members = result
                canMentionRoom = canNotify
            }
        } catch { if token == selection { errorMessage = Self.safeError(error) } }
    }
    func searchMessages(query: String, roomID: String? = nil) async throws {
        cancelSearch()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if isPreview {
            searchResults = previewSearch(term, roomID: roomID)
            searchState = "ready"
            return
        }
        let client: Client
        do { client = try requireClient() } catch {
            failSearch(error)
            throw MatrixServiceError.request(Self.safeError(error))
        }
        let token = searchGeneration
        let session = sessionGeneration
        let service = client.searchService()
        activeSearch = service
        searchState = "loading"
        do {
            let resultHandle = await service.subscribeToResults(
                listener: SearchResultsObserver { [weak self] results, revision in
                    Task { @MainActor [weak self] in
                        guard let self, token == self.searchGeneration, session == self.sessionGeneration,
                            revision > self.searchResultRevision
                        else { return }
                        self.searchResultRevision = revision
                        let mapped = MatrixMapping.searchMessages(results, roomID: roomID)
                        self.searchResults = mapped
                    }
                })
            guard token == searchGeneration, session == sessionGeneration else {
                resultHandle.cancel()
                return
            }
            searchHandles.append(resultHandle)
            searchHandles.append(
                service.subscribeToPaginationStateUpdates(
                    listener: SearchPaginationObserver { [weak self] state, revision in
                        Task { @MainActor [weak self] in
                            guard let self, token == self.searchGeneration, session == self.sessionGeneration,
                                revision > self.searchPaginationRevision
                            else { return }
                            self.searchPaginationRevision = revision
                            if self.searchQueryCompleted { self.updateSearchPagination(state) }
                        }
                    }))
            try await service.setQuery(query: term)
            guard token == searchGeneration, session == sessionGeneration else { return }
            searchQueryCompleted = true
            updateSearchPagination(service.paginationState())
        } catch {
            guard token == searchGeneration, session == sessionGeneration else { return }
            failSearch(error)
            throw MatrixServiceError.request(Self.safeError(error))
        }
    }

    func loadMoreSearch() async throws {
        guard searchHasMore, searchState != "loading", let service = activeSearch else { return }
        let token = searchGeneration
        let session = sessionGeneration
        searchState = "loading"
        searchErrorMessage = nil
        do {
            try await service.paginate()
            guard token == searchGeneration, session == sessionGeneration else { return }
            updateSearchPagination(service.paginationState())
        } catch {
            guard token == searchGeneration, session == sessionGeneration else { return }
            failSearch(error)
            throw MatrixServiceError.request(Self.safeError(error))
        }
    }

    private func updateSearchPagination(_ state: SearchServicePaginationState) {
        switch state {
        case .loading: searchState = "loading"
        case .idle(let endReached):
            searchState = "ready"
            searchHasMore = !endReached
        }
    }

    private func failSearch(_ error: Error) {
        searchGeneration = UUID()
        for handle in searchHandles { handle.cancel() }
        searchHandles.removeAll()
        activeSearch = nil
        searchHasMore = false
        searchErrorMessage = Self.safeError(error)
        searchState = "error"
    }

    func cancelSearch() {
        // The SDK exposes no query-abort method. Cancel subscriptions, drop its service, and ignore any in-flight
        // completion.
        searchGeneration = UUID()
        for handle in searchHandles { handle.cancel() }
        searchHandles.removeAll()
        activeSearch = nil
        searchResultRevision = 0
        searchPaginationRevision = 0
        searchQueryCompleted = false
        searchResults = []
        searchHasMore = false
        searchState = "idle"
        searchErrorMessage = nil
    }

    func startSearchBackfill() async throws {
        let client = try requireClient()
        let account = sessionGeneration
        try validateRoomMutation(account)
        searchIndexing.start(
            makeHandle: {
                let handle = client.runSearchBackfill(strategy: .foreground)
                return SearchIndexingController.Handle(cancel: { handle.cancel() }, isFinished: { handle.isFinished() })
            },
            onUpdate: { [weak self] state in
                guard let self, self.sessionGeneration == account, self.connectionStopTask == nil else { return }
                self.searchIndexingState = state
            })
    }

    func cancelSearchBackfill(sessionID: UUID) {
        guard sessionGeneration == sessionID, connectionStopTask == nil, !isPreview else { return }
        searchIndexing.cancel()
    }

    func setTyping(_ typing: Bool, roomID: String, sessionID: UUID) async {
        guard sessionGeneration == sessionID, connectionStopTask == nil, !isPreview, !Task.isCancelled,
            !typing || selectedRoomID == roomID, let client
        else { return }
        do {
            guard let room = try client.getRoom(roomId: roomID), room.membership() == .joined else { return }
            // Capture the room before suspension. A late stop notice may clean
            // up its original room, but must never address the newly selected one.
            try await room.typingNotice(isTyping: typing)
        } catch {
            guard sessionGeneration == sessionID, connectionStopTask == nil, !isPreview,
                !Task.isCancelled, selectedRoomID == roomID
            else { return }
            errorMessage = Self.safeError(error)
        }
    }
    func setProfile(name: String) async throws {
        guard connectionStopTask == nil else { throw CancellationError() }
        let client = try requireClient()
        let generation = sessionGeneration
        do {
            try await client.setDisplayName(name: name)
            guard sessionGeneration == generation, connectionStopTask == nil else { throw CancellationError() }
            profileRevision &+= 1
            user?.name = name
        } catch {
            guard sessionGeneration == generation, connectionStopTask == nil else { throw CancellationError() }
            throw error
        }
    }
    /// Whether the account already has a cross-signing identity that another device or the recovery key can vouch
    /// for this one with. A brand-new account has nothing to confirm; a failed lookup stays unknown.
    func accountHasIdentity() async -> Bool? {
        guard let userID = user?.id, let client = try? requireClient() else { return nil }
        do {
            return try await client.encryption().userIdentity(userId: userID, fallbackToServer: true) != nil
        } catch {
            return nil
        }
    }
    func recoverEncryption(recoveryKey: String) async throws {
        try await requireClient().encryption().recover(recoveryKey: recoveryKey)
    }
    func sendFailure(for message: ChatMessage) -> MessageSendFailure? {
        sendFailures[SendQueueMessageKey(roomID: message.roomID, messageID: message.eventID)]
    }

    func isSendActionPending(for message: ChatMessage) -> Bool {
        pendingSendActions.contains(SendQueueMessageKey(roomID: message.roomID, messageID: message.eventID))
    }

    func retryMessage(_ message: ChatMessage) async throws {
        guard let context = try pendingSendContext(message) else { return }
        guard let failure = sendFailure(for: message) else {
            throw MatrixServiceError.request("This message is not waiting for a manual retry.")
        }
        try await performSendAction(context, message: message) {
            _ = try await SendQueueActions.retry(
                failure, itemID: context.itemID, room: context.room, timeline: context.timeline)
        }
    }

    // Cancels only a currently loaded own local echo. SDK cancellation can
    // remove an in-flight message after delivery; it is not a remote delete API.
    func cancelMessage(_ message: ChatMessage) async throws -> Bool {
        guard let context = try pendingSendContext(message) else { return false }
        var cancelled = false
        try await performSendAction(context, message: message) {
            cancelled = try await SendQueueActions.cancel(itemID: context.itemID, timeline: context.timeline)
        }
        return cancelled
    }

    private struct PendingSendContext {
        let itemID: EventOrTransactionId
        let room: Room
        let timeline: Timeline
        let session: UUID
        let selection: UUID
        let threadSelection: UUID?
    }

    private func pendingSendContext(_ message: ChatMessage) throws -> PendingSendContext? {
        try assertDestination(message.roomID)
        _ = try requireClient()
        guard
            let current = (messages + threadMessages).first(where: {
                $0.roomID == message.roomID && $0.eventID == message.eventID
            }), current.sendState != "sent"
        else { return nil }
        guard current.senderID == user?.id else {
            throw MatrixServiceError.request("Only your own queued messages can be retried or cancelled.")
        }
        guard let itemID = eventIDs[message.eventID], case .transactionId = itemID else { return nil }
        let target: Timeline
        let threadToken: UUID?
        if let root = current.threadRootID {
            guard root == loadedThreadRootID, let threadTimeline else {
                throw MatrixServiceError.request("Open this message’s thread before changing its queued send.")
            }
            target = threadTimeline
            threadToken = threadSelection
        } else {
            target = try requireTimeline()
            threadToken = nil
        }
        let room = try requireRoom(message.roomID)
        guard room.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation before changing its queued messages.")
        }
        return PendingSendContext(
            itemID: itemID, room: room, timeline: target, session: sessionGeneration, selection: selection,
            threadSelection: threadToken)
    }

    private func performSendAction(_ context: PendingSendContext, message: ChatMessage, action: () async throws -> Void)
        async throws
    {
        let key = SendQueueMessageKey(roomID: message.roomID, messageID: message.eventID)
        guard pendingSendActions.insert(key).inserted else {
            throw MatrixServiceError.request("This queued message is already being updated.")
        }
        defer { if sessionGeneration == context.session { pendingSendActions.remove(key) } }
        do {
            try validateSendAction(context)
            try await action()
            try validateSendAction(context)
        } catch {
            try validateSendAction(context)
            throw error
        }
    }

    private func validateSendAction(_ context: PendingSendContext) throws {
        try Task.checkCancellation()
        guard sessionGeneration == context.session, selection == context.selection,
            context.threadSelection == nil || threadSelection == context.threadSelection
        else { throw CancellationError() }
        guard context.room.membership() == .joined else {
            throw MatrixServiceError.request("You are no longer a member of this conversation.")
        }
    }

    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    static func safeError(_ error: Error) -> String {
        if let error = error as? MatrixServiceError { return error.localizedDescription }
        if let error = error as? ForwardMessageError { return error.localizedDescription }
        if let error = error as? ForwardMessageReviewChanged { return error.localizedDescription }
        if let error = error as? ServerLogoutFailure { return error.message }
        if let error = error as? RoomCreationPartialFailure { return error.warning }
        if let error = error as? RoomDetailsPartialFailure { return error.warning }
        if let error = error as? SecureSessionStore.StoreError { return error.localizedDescription }
        if let error = error as? AttachmentDraftError { return error.localizedDescription }
        if let error = error as? MediaCaptionError { return error.localizedDescription }
        if let error = error as? RoomNotificationSaveFailure { return error.warning }
        if let error = error as? AccountNotificationDefaultsSaveFailure { return error.warning }
        if let error = error as? MatrixLinkError { return error.localizedDescription }
        let raw = String(describing: error).lowercased()
        if raw.contains("invalid username or password") { return "Wrong username or password." }
        if raw.contains("forbidden") { return "You don’t have permission to do that." }
        if raw.contains("unknown_token") || raw.contains("unknowntoken") || raw.contains("softlogout") {
            return "Your session expired. Sign in again."
        }
        if raw.contains("recovery") { return "That recovery key didn’t work. Check it and try again." }
        if raw.contains("connection") || raw.contains("network") || raw.contains("dns") {
            return "Can’t reach the server. Check your connection."
        }
        return "Something went wrong. Try again."
    }
}
