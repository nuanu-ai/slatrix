import Combine
import Foundation
import MatrixRustSDK

struct SharedContentItem: Identifiable, Hashable {
    var id: String
    var message: ChatMessage
    var links: [URL]
    var mediaRevision: Data? = nil
    fileprivate var scopeID: UUID
    var filename: String? { message.attachment.map { SharedContentMapping.safeFilename($0.name) } }
}

enum SharedContentMapping {
    static func safeFilename(_ value: String) -> String {
        let basename =
            value.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).last
            .map(String.init) ?? ""
        let clean = basename.filter { character in
            !character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != ".", clean != ".." else { return "attachment" }
        var result = ""
        for character in clean {
            if result.utf8.count + character.utf8.count > 200 { break }
            result.append(character)
        }
        return result.isEmpty ? "attachment" : result
    }

    static func links(in rendered: RenderedMessageBody) -> [URL] {
        guard !rendered.containsSpoilers else { return [] }
        var urls: [URL] = []
        var seen = Set<String>()
        func add(_ source: String) {
            guard urls.count < 32, let url = MessageBodyRenderer.safeLink(source),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url.absoluteString).inserted
            else { return }
            urls.append(url)
        }
        for run in rendered.runs { if let link = run.link { add(link.absoluteString) } }
        let text = MessageBodyRenderer.boundedLiteral(rendered.plainText)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let url = match.url { add(url.absoluteString) }
            }
        }
        return urls
    }
}

private final class SharedFilesTimelineObserver: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimelineItem] = []
    private var revision = 0
    let callback: @Sendable ([TimelineItem], Int) -> Void
    init(_ callback: @escaping @Sendable ([TimelineItem], Int) -> Void) { self.callback = callback }
    func onUpdate(diff: [TimelineDiff]) {
        lock.lock()
        values.apply(diff.map(\.change))
        revision += 1
        let snapshot = values
        let next = revision
        lock.unlock()
        callback(snapshot, next)
    }
}

private final class SharedFilesRoomObserver: RoomInfoListener, @unchecked Sendable {
    let callback: @Sendable (Membership) -> Void
    init(_ callback: @escaping @Sendable (Membership) -> Void) { self.callback = callback }
    func call(roomInfo: RoomInfo) { callback(roomInfo.membership) }
}

@MainActor
final class SharedFilesService: ObservableObject {
    @Published private(set) var roomID: String?
    @Published private(set) var items: [SharedContentItem] = []
    @Published private(set) var state = "idle"
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var historyLoads = 0
    @Published private(set) var unavailableEncryptedCount = 0
    @Published private(set) var savingItemIDs = Set<String>()

    private struct Media {
        let message: ChatMessage
        let source: MediaSource
        let thumbnail: MediaSource?
        let thumbnailSize: UInt64?
        let fingerprint: Data
    }
    private var client: Client?
    private var room: Room?
    private var timeline: Timeline?
    private var timelineHandle: TaskHandle?
    private var roomHandle: TaskHandle?
    private var account = UUID()
    private var scope = UUID()
    private var revision = 0
    private var media: [String: Media] = [:]
    private var projection: Task<Void, Never>?
    private let mediaFiles = MediaFileCache()
    private let limit = ConcurrencyLimit(slots: 2)

    func attach(_ client: Client?) {
        close()
        account = UUID()
        self.client = client
    }

    func close() {
        mediaFiles.removeAll()
        scope = UUID()
        projection?.cancel()
        projection = nil
        timelineHandle?.cancel()
        roomHandle?.cancel()
        timelineHandle = nil
        roomHandle = nil
        timeline = nil
        room = nil
        roomID = nil
        revision = 0
        media = [:]
        items = []
        state = "idle"
        isLoadingMore = false
        hasMore = false
        errorMessage = nil
        historyLoads = 0
        unavailableEncryptedCount = 0
        savingItemIDs = []
    }

    func open(roomID id: String) async {
        close()
        roomID = id
        state = "loading"
        hasMore = true
        let session = account
        let token = scope
        do {
            guard let client else { throw MatrixServiceError.signedOut }
            guard let room = try client.getRoom(roomId: id), room.membership() == .joined else {
                throw MatrixServiceError.request("Join this conversation to browse shared files and links.")
            }
            self.room = room
            roomHandle = room.subscribeToRoomInfoUpdates(
                listener: SharedFilesRoomObserver { [weak self] membership in
                    Task { @MainActor [weak self] in
                        guard let self, self.account == session, self.scope == token else { return }
                        if membership != .joined, room.membership() != .joined { self.close() }
                    }
                })
            let created = try await self.limit.run {
                try await MainActor.run { try self.validate(session, token) }
                return try await room.timelineWithConfiguration(
                    configuration: TimelineConfiguration(
                        focus: .live(hideThreadedEvents: false), filter: .all, internalIdPrefix: nil,
                        dateDividerMode: .daily, trackReadReceipts: .disabled, reportUtds: false))
            }
            try validate(session, token)
            timeline = created
            let handle = await created.addListener(
                listener: SharedFilesTimelineObserver { [weak self] values, revision in
                    Task { @MainActor [weak self] in
                        guard let self, self.account == session, self.scope == token, revision > self.revision else {
                            return
                        }
                        guard room.membership() == .joined else {
                            self.close()
                            return
                        }
                        self.receive(
                            values, revision: revision, roomID: id, ownID: try? client.userId(), session: session,
                            token: token)
                    }
                })
            do { try validate(session, token) } catch {
                handle.cancel()
                throw error
            }
            timelineHandle = handle
            await loadPage(session: session, token: token)
        } catch {
            guard account == session, scope == token else { return }
            if error is CancellationError {
                close()
                return
            }
            state = "error"
            errorMessage = MatrixService.safeError(error)
            timelineHandle?.cancel()
            roomHandle?.cancel()
            timelineHandle = nil
            roomHandle = nil
            timeline = nil
        }
    }

    func loadMore() async {
        guard timeline != nil, !isLoadingMore, hasMore else { return }
        await loadPage(session: account, token: scope)
    }

    func retry() async {
        if timeline != nil { await loadMore() } else if let roomID { await open(roomID: roomID) }
    }

    private func loadPage(session: UUID, token: UUID) async {
        guard let timeline, !isLoadingMore else { return }
        isLoadingMore = true
        errorMessage = nil
        defer { if account == session, scope == token { isLoadingMore = false } }
        do {
            let end = try await self.limit.run {
                try await MainActor.run { try self.validate(session, token) }
                return try await timeline.paginateBackwards(numEvents: 50)
            }
            try validate(session, token)
            historyLoads += 1
            hasMore = !end
            state = "ready"
        } catch {
            guard account == session, scope == token else { return }
            if error is CancellationError { return }
            state = "ready"
            errorMessage = MatrixService.safeError(error)
        }
    }

    private func receive(
        _ values: [TimelineItem], revision next: Int, roomID: String, ownID: String?, session: UUID, token: UUID
    ) {
        revision = next
        var candidates: [ChatMessage] = []
        var sources: [String: Media] = [:]
        var seen = Set<String>()
        var unavailable = 0
        for value in values {
            guard let event = value.asEvent(), event.isRemote, case .eventId(let id) = event.eventOrTransactionId,
                id.hasPrefix("$"), let projected = MatrixMapping.message(event, roomID: roomID, ownUserID: ownID),
                seen.insert(id).inserted
            else { continue }
            var message = projected
            if message.kind == "m.room.encrypted" { unavailable += 1 }
            if message.isRedacted { continue }
            if case .msgLike(let content) = event.content, case .message(let value) = content.kind {
                let source: MediaSource?
                let thumbnail: MediaSource?
                let size: UInt64?
                switch value.msgType {
                case .image(let file):
                    source = file.source
                    thumbnail = file.info?.thumbnailSource
                    size = file.info?.thumbnailInfo?.size
                    message.formattedBody = MatrixMapping.htmlBody(file.formattedCaption)
                case .file(let file):
                    source = file.source
                    thumbnail = file.info?.thumbnailSource
                    size = file.info?.thumbnailInfo?.size
                    message.formattedBody = MatrixMapping.htmlBody(file.formattedCaption)
                case .video(let file):
                    source = file.source
                    thumbnail = file.info?.thumbnailSource
                    size = file.info?.thumbnailInfo?.size
                    message.formattedBody = MatrixMapping.htmlBody(file.formattedCaption)
                case .audio(let file):
                    source = file.source
                    thumbnail = nil
                    size = nil
                    message.formattedBody = MatrixMapping.htmlBody(file.formattedCaption)
                default:
                    source = nil
                    thumbnail = nil
                    size = nil
                }
                if let source {
                    sources[id] = Media(
                        message: message, source: source, thumbnail: thumbnail, thumbnailSize: size,
                        fingerprint: Data(source.toJson().utf8))
                }
            }
            candidates.append(message)
        }
        // Immediately revoke stale media access, before asynchronous rich-text
        // parsing finishes. A removed/redacted/edited source is never cumulative.
        media = sources
        unavailableEncryptedCount = unavailable
        projection?.cancel()
        projection = Task { [weak self] in
            var projected: [SharedContentItem] = []
            for var message in candidates {
                guard let self, self.account == session, self.scope == token, self.revision == next, !Task.isCancelled
                else { return }
                let rendered = await Task.detached(priority: .utility) { [message] in
                    MessageBodyRenderer.shared.render(body: message.body, formattedBody: message.formattedBody)
                }.value
                let links = await Task.detached(priority: .utility) { SharedContentMapping.links(in: rendered) }.value
                guard self.account == session, self.scope == token, self.revision == next, !Task.isCancelled else {
                    return
                }
                if rendered.containsSpoilers {
                    message.body = "[Spoiler hidden]"
                    message.formattedBody = nil
                }
                if message.attachment != nil || !links.isEmpty {
                    projected.append(
                        SharedContentItem(
                            id: ActivityService.key(roomID: roomID, eventID: message.eventID), message: message,
                            links: links, mediaRevision: sources[message.eventID]?.fingerprint, scopeID: token))
                }
            }
            guard let self, self.account == session, self.scope == token, self.revision == next, !Task.isCancelled,
                self.room?.membership() == .joined
            else { return }
            self.items = Array(projected.reversed())
            self.projection = nil
        }
    }

    func thumbnailData(_ item: SharedContentItem) async throws -> Data {
        let session = account
        let token = scope
        let record = try currentMedia(item, session, token)
        let source: MediaSource
        if let thumbnail = record.thumbnail, thumbnail.url() != record.source.url() {
            guard MatrixMapping.permitsAutomaticOriginalPreview(size: record.thumbnailSize) else {
                throw MatrixServiceError.request("A small preview is unavailable. Download the file to view it.")
            }
            source = thumbnail
        } else {
            guard MatrixMapping.permitsAutomaticOriginalPreview(size: record.message.attachment?.size) else {
                throw MatrixServiceError.request("A small preview is unavailable. Download the file to view it.")
            }
            source = record.source
        }
        guard let client else { throw MatrixServiceError.signedOut }
        do {
            let data = try await self.limit.run {
                try await MainActor.run { try self.validateMedia(item, record, session, token) }
                return try await client.getMediaThumbnail(mediaSource: source, width: 840, height: 520)
            }
            try validateMedia(item, record, session, token)
            guard data.count <= Int(MatrixMapping.maximumAutomaticPreviewBytes) else {
                throw MatrixServiceError.request("This preview is too large. Download the file to view it.")
            }
            return data
        } catch {
            try validateMedia(item, record, session, token)
            throw error
        }
    }

    func preparePreview(_ item: SharedContentItem) async throws -> AttachmentPreviewLease {
        let session = account
        let token = scope
        let media: Media
        do { media = try currentMedia(item, session, token) } catch { throw CancellationError() }
        guard let client, let attachment = media.message.attachment else { throw MatrixServiceError.noRoom }
        return try await mediaFiles.file(
            source: media.source, identity: String(decoding: media.fingerprint, as: UTF8.self), attachment: attachment,
            client: client
        ) {
            [weak self] in
            (try? self?.currentMedia(item, session, token))?.fingerprint == media.fingerprint
        }
    }

    func saveAttachment(_ item: SharedContentItem, to destination: URL) async throws {
        let session = account
        let token = scope
        let record = try currentMedia(item, session, token)
        guard destination.isFileURL, !destination.hasDirectoryPath,
            !["", ".", ".."].contains(destination.lastPathComponent)
        else { throw MatrixServiceError.request("Choose a file destination for this attachment.") }
        guard savingItemIDs.insert(item.id).inserted else {
            throw MatrixServiceError.request("This attachment is already being saved.")
        }
        defer { if account == session, scope == token { savingItemIDs.remove(item.id) } }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        do {
            let file = try await preparePreview(item)
            try validateMedia(item, record, session, token)
            let source = file.url
            try await Task.detached(priority: .userInitiated) {
                try await MainActor.run { try self.validateMedia(item, record, session, token) }
                try Task.checkCancellation()
                try Self.copyAtomically(from: source, to: destination)
            }.value
            try validateMedia(item, record, session, token)
            withExtendedLifetime(file) {}
        } catch {
            try validateMedia(item, record, session, token)
            throw error
        }
    }

    private func currentMedia(_ item: SharedContentItem, _ session: UUID, _ token: UUID) throws -> Media {
        try validate(session, token)
        guard item.scopeID == token, item.message.roomID == roomID, let record = media[item.message.eventID],
            !item.message.isRedacted,
            record.message.attachment == item.message.attachment, record.message.attachment != nil,
            item.mediaRevision == record.fingerprint
        else {
            throw MatrixServiceError.request(
                "This attachment changed or is no longer available. Refresh the shared history.")
        }
        return record
    }

    private func validateMedia(_ item: SharedContentItem, _ record: Media, _ session: UUID, _ token: UUID) throws {
        let current = try currentMedia(item, session, token)
        guard current.fingerprint == record.fingerprint else {
            throw MatrixServiceError.request("This attachment changed. Open its current version before downloading.")
        }
    }

    private func validate(_ session: UUID, _ token: UUID) throws {
        try Task.checkCancellation()
        guard account == session, scope == token else { throw CancellationError() }
        guard client != nil, room?.membership() == .joined else {
            throw MatrixServiceError.request("Join this conversation to browse shared files and links.")
        }
    }

    private nonisolated static func copyAtomically(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".slatrix-" + UUID().uuidString)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: source, to: staged)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staged)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }
}
