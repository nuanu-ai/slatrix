import Foundation
import MatrixRustSDK
import Observation

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

    /// "Shared by Alice in #design · Oct 24", as a Files row reads; a direct message needs no place.
    static func caption(
        sender: String, room: ChatRoom?, date: Date, now: Date = .now, calendar: Calendar = .current
    ) -> String {
        let place = room.flatMap { $0.isDirect ? nil : " in #\($0.name)" } ?? ""
        var day = Date.FormatStyle(
            date: .omitted, time: .omitted, locale: calendar.locale ?? .current, calendar: calendar,
            timeZone: calendar.timeZone
        ).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { day = day.year() }
        return "Shared by \(sender)\(place) · \(date.formatted(day))"
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
    var snapshot: (values: [TimelineItem], revision: Int) { lock.withLock { (values, revision) } }
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
@Observable final class SharedFilesService {
    private(set) var roomID: String?
    private(set) var items: [SharedContentItem] = []
    private(set) var state = "idle"
    private(set) var isLoadingMore = false
    private(set) var hasMore = false
    private(set) var errorMessage: String?
    private(set) var historyLoads = 0
    private(set) var unavailableEncryptedCount = 0

    private struct Media {
        let message: ChatMessage
        let source: MediaSource
        let thumbnail: MediaSource?
        let thumbnailSize: UInt64?
        let fingerprint: Data
    }
    /// A list left while it was whole, still following its timeline, so coming back shows its rows at once.
    private struct Kept {
        let scope: UUID
        let room: Room
        let timeline: Timeline
        let observer: SharedFilesTimelineObserver
        let timelineHandle: TaskHandle
        let roomHandle: TaskHandle?
        let items: [SharedContentItem]
        let media: [String: Media]
        let hasMore: Bool
        let historyLoads: Int
        func cancel() {
            timelineHandle.cancel()
            roomHandle?.cancel()
        }
    }
    private var client: Client?
    private var room: Room?
    private var timeline: Timeline?
    private var observer: SharedFilesTimelineObserver?
    private var timelineHandle: TaskHandle?
    private var roomHandle: TaskHandle?
    private var kept = RecentTimelines<Kept>()
    private var account = UUID()
    private var scope = UUID()
    private var revision = 0
    private var media: [String: Media] = [:]
    private var projection: Task<Void, Never>?
    private let mediaFiles = MediaFileCache()
    private let limit = ConcurrencyLimit(slots: 2)

    func attach(_ client: Client?) {
        close()
        // Another account's lists never come back.
        for entry in kept.removeAll() { entry.cancel() }
        account = UUID()
        self.client = client
    }

    func close() {
        // A page still loading would finish into the kept list, and coming back could start another beside it.
        if let roomID, let room, let timeline, let observer, let timelineHandle, state == "ready", !isLoadingMore,
            room.membership() == .joined
        {
            let entry = Kept(
                scope: scope, room: room, timeline: timeline, observer: observer,
                timelineHandle: timelineHandle, roomHandle: roomHandle, items: items, media: media, hasMore: hasMore,
                historyLoads: historyLoads)
            for dropped in kept.keep(entry, for: roomID) { dropped.cancel() }
        } else {
            timelineHandle?.cancel()
            roomHandle?.cancel()
        }
        mediaFiles.removeAll()
        scope = UUID()
        projection?.cancel()
        projection = nil
        timelineHandle = nil
        roomHandle = nil
        timeline = nil
        observer = nil
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
    }

    /// The sample workspace's files, which have no timeline behind them.
    func openPreview(roomID id: String, messages: [ChatMessage]) {
        close()
        roomID = id
        state = "ready"
        items = messages.reversed().filter { $0.attachment != nil }.map {
            SharedContentItem(id: $0.eventID, message: $0, links: [], scopeID: scope)
        }
    }

    /// The row still showing this message's file, if any.
    func item(for message: ChatMessage) -> SharedContentItem? {
        items.first {
            $0.message.eventID == message.eventID && $0.message.roomID == message.roomID
                && $0.message.attachment == message.attachment
        }
    }

    func open(roomID id: String) async {
        close()
        if let entry = kept.take(id) {
            if entry.room.membership() == .joined { return restore(entry, roomID: id) }
            entry.cancel()
        }
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
            let listener = SharedFilesTimelineObserver { [weak self] values, revision in
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
            }
            let handle = await created.addListener(listener: listener)
            do { try validate(session, token) } catch {
                handle.cancel()
                throw error
            }
            timelineHandle = handle
            observer = listener
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

    /// Refresh: the conversation's timeline read again, not its kept list.
    func reload(roomID id: String) async {
        close()
        kept.take(id)?.cancel()
        await open(roomID: id)
    }

    private func restore(_ entry: Kept, roomID id: String) {
        scope = entry.scope
        roomID = id
        room = entry.room
        timeline = entry.timeline
        observer = entry.observer
        timelineHandle = entry.timelineHandle
        roomHandle = entry.roomHandle
        items = entry.items
        media = entry.media
        hasMore = entry.hasMore
        historyLoads = entry.historyLoads
        state = "ready"
        // Whatever changed while the list was away lands quietly over the kept rows.
        let snapshot = entry.observer.snapshot
        receive(
            snapshot.values, revision: snapshot.revision, roomID: id, ownID: try? client?.userId(), session: account,
            token: scope)
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
        // A video's own file is no picture, so it has a poster only when the sender attached one.
        guard record.message.kind != "m.video" || record.thumbnail != nil else {
            throw MatrixServiceError.request("This video has no poster.")
        }
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
        do {
            return try await mediaFiles.file(
                source: media.source, identity: String(decoding: media.fingerprint, as: UTF8.self),
                attachment: attachment, client: client
            ) { [weak self] in
                (try? self?.currentMedia(item, session, token))?.fingerprint == media.fingerprint
            }
        } catch {
            // A failure from before a sign-out or a reopened list belongs to nobody.
            guard (try? currentMedia(item, session, token)) != nil else { throw CancellationError() }
            throw error
        }
    }

    func permalink(_ item: SharedContentItem) async throws -> String {
        let session = account
        let token = scope
        try validate(session, token)
        guard let room, items.contains(item) else { throw CancellationError() }
        let link = try await room.matrixToEventPermalink(eventId: item.message.eventID)
        try validate(session, token)
        return link
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
}
