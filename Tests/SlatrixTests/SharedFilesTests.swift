import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Stands in for an encrypted SDK source; keeping this object keeps its key, rebuilding it from url() would not.
private final class Source: MediaSource, @unchecked Sendable {
    let address: String
    let identity: String
    init(_ address: String, identity: String = "encrypted-key-and-iv") {
        self.address = address
        self.identity = identity
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func url() -> String { address }
    override func toJson() -> String { identity }
}

private final class History: Timeline, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimelineItem]
    private var listeners: [TimelineListener] = []
    private var handles: [FakeCancellableHandle] = []
    let pages = Recorder<Void>()
    let receipts = Recorder<Void>()
    let pageGate = Gate()
    var end = false
    var allCancelled: Bool { lock.withLock { handles.allSatisfy(\.isCancelled) } }
    init(_ values: [TimelineItem]) {
        self.values = values
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func addListener(listener: TimelineListener) async -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        let snapshot = lock.withLock {
            listeners.append(listener)
            handles.append(handle)
            return values
        }
        listener.onUpdate(diff: [.reset(values: snapshot)])
        return handle
    }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        pages.append(())
        await pageGate.wait()
        return end
    }
    override func markAsRead(receiptType: ReceiptType) async throws { receipts.append(()) }
    override func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws { receipts.append(()) }
    func reset(_ values: [TimelineItem]) {
        let callbacks = lock.withLock {
            self.values = values
            return listeners
        }
        for item in callbacks { item.onUpdate(diff: [.reset(values: values)]) }
    }
}

private final class SharedRoom: Room, @unchecked Sendable {
    let history: History
    let setupGate = Gate()
    let configurations = Recorder<TimelineConfiguration>()
    var fail = false
    init(_ values: [TimelineItem]) {
        history = History(values)
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func membership() -> Membership { .joined }
    override func subscribeToRoomInfoUpdates(listener: RoomInfoListener) -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        configurations.append(configuration)
        await setupGate.wait()
        if fail { throw MatrixServiceError.request("setup failed") }
        return history
    }
}

private final class DownloadedFile: MediaFileHandle, @unchecked Sendable {
    let filename: String
    init(_ filename: String) {
        self.filename = filename
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func path() throws -> String { filename }
    deinit { try? FileManager.default.removeItem(atPath: filename) }
}

private final class SharedClient: Client, @unchecked Sendable {
    let room: SharedRoom
    let folder: URL
    let downloadGate = Gate()
    var failDownload = false
    var thumbnailBytes = Data([1, 2, 3, 4])
    let downloads = Recorder<(source: MediaSource, cached: Bool, filename: String?)>()
    let thumbnails = Recorder<MediaSource>()
    init(_ room: SharedRoom, folder: URL) {
        self.room = room
        self.folder = folder
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getRoom(roomId: String) throws -> Room? { room }
    override func userId() throws -> String { "@me:example.org" }
    override func getMediaFile(
        mediaSource: MediaSource, filename: String?, mimeType: String, useCache: Bool, tempDir: String?
    ) async throws -> MediaFileHandle {
        downloads.append((mediaSource, useCache, filename))
        await downloadGate.wait()
        if failDownload { throw MatrixServiceError.request("download failed") }
        let file = folder.appendingPathComponent("sdk-" + UUID().uuidString)
        try Data("downloaded bytes".utf8).write(to: file)
        return DownloadedFile(file.path)
    }
    override func getMediaThumbnail(mediaSource: MediaSource, width: UInt64, height: UInt64) async throws -> Data {
        thumbnails.append(mediaSource)
        return thumbnailBytes
    }
}

private func item(_ id: String, _ type: MessageType, body: String, edited: Bool = false) -> TimelineItem {
    var event = textEvent(id, body: body)
    event.content = .msgLike(
        content: MsgLikeContent(
            kind: .message(content: MessageContent(msgType: type, body: body, isEdited: edited, mentions: nil)),
            inReplyTo: nil, threadRoot: nil, threadSummary: nil))
    return FakeTimelineItem(event)
}

private enum Kind { case file, image, video, audio }

private func file(
    _ id: String, source: MediaSource, kind: Kind = .file, name: String = "../report.txt", size: UInt64? = 4,
    thumbnail: MediaSource? = nil, caption: FormattedBody? = nil, edited: Bool = false
) -> TimelineItem {
    let type: MessageType
    switch kind {
    case .image:
        type = .image(
            content: ImageMessageContent(
                filename: name, caption: nil, formattedCaption: caption, source: source,
                info: ImageInfo(
                    height: 2, width: 2, mimetype: "image/png", size: size,
                    thumbnailInfo: thumbnail.map { _ in
                        ThumbnailInfo(height: 1, width: 1, mimetype: "image/png", size: 4)
                    },
                    thumbnailSource: thumbnail, blurhash: nil, isAnimated: false)))
    case .video:
        type = .video(
            content: VideoMessageContent(
                filename: name, caption: nil, formattedCaption: caption, source: source, info: nil))
    case .audio:
        type = .audio(
            content: AudioMessageContent(
                filename: name, caption: nil, formattedCaption: caption, source: source, info: nil, audio: nil,
                voice: nil))
    case .file:
        type = .file(
            content: FileMessageContent(
                filename: name, caption: nil, formattedCaption: caption, source: source,
                info: FileInfo(mimetype: "text/plain", size: size, thumbnailInfo: nil, thumbnailSource: nil)))
    }
    return item(id, type, body: name, edited: edited)
}

private func text(_ id: String, body: String, html: String? = nil) -> TimelineItem {
    item(
        id,
        .text(content: TextMessageContent(body: body, formatted: html.map { FormattedBody(format: .html, body: $0) })),
        body: body)
}

@MainActor
final class SharedFilesTests {
    private let temp: TemporaryDirectory
    private let source = Source("mxc://example.org/encrypted-file")
    private let room: SharedRoom
    private let client: SharedClient
    private let service = SharedFilesService()

    init() throws {
        temp = try TemporaryDirectory()
        room = SharedRoom([
            file("$old", source: source), text("$plain", body: "Just a message"),
            text("$link", body: "Read https://example.org/docs"),
        ])
        client = SharedClient(room, folder: temp.url)
        service.attach(client)
    }

    private func open() async {
        await service.open(roomID: "!room:example.org")
        #expect(await eventually { !self.service.items.isEmpty })
    }
    private func show(_ values: [TimelineItem], until condition: @escaping @MainActor () -> Bool) async {
        room.history.reset(values)
        #expect(await eventually(condition))
    }
    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: temp.path(name).path)
    }

    @Test("Files lists the room's files and links from its own timeline, including threads, without sending receipts")
    func listsFromOwnTimeline() async throws {
        await open()
        #expect(await eventually { self.service.items.count == 2 })
        #expect(service.items.map(\.message.id) == ["$link", "$old"])
        let configuration = try #require(room.configurations.all.first)
        #expect(configuration.focus == .live(hideThreadedEvents: false) && configuration.filter == .all)
        #expect(configuration.trackReadReceipts == .disabled && !configuration.reportUtds)
        #expect(room.history.receipts.all.isEmpty)
    }

    @Test("A page with no new files neither ends the history nor duplicates rows; only the SDK's end flag does")
    func pagination() async {
        await open()
        #expect(service.hasMore)
        await service.loadMore()
        #expect(service.hasMore && service.items.count == 2)
        room.history.end = true
        await service.loadMore()
        #expect(!service.hasMore)
        let pages = room.history.pages.all.count
        await service.loadMore()
        #expect(room.history.pages.all.count == pages)
    }

    @Test("Load more while a page is loading does not request another page")
    func duplicateLoadMore() async {
        await open()
        let pages = room.history.pages.all.count
        room.history.pageGate.arm()
        let page = Task { await service.loadMore() }
        #expect(await eventually { self.room.history.pageGate.isWaiting })
        await service.loadMore()
        #expect(room.history.pages.all.count == pages + 1 && service.isLoadingMore)
        room.history.pageGate.release()
        await page.value
    }

    @Test("Saving downloads the original encrypted source uncached under a safe name and replaces the file atomically")
    func savesAtomically() async throws {
        await open()
        let original = try #require(service.items.first { $0.message.id == "$old" })
        let destination = temp.path("saved.txt")
        try Data("existing".utf8).write(to: destination)
        try await service.saveAttachment(original, to: destination)
        #expect(try Data(contentsOf: destination) == Data("downloaded bytes".utf8))
        let download = try #require(client.downloads.all.first)
        #expect(download.source === source && !download.cached && download.filename == "report.txt")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: temp.url.path).allSatisfy { !$0.hasPrefix(".slatrix-") }
        )
    }

    @Test("An edit replaces the row, and the old row can no longer download")
    func editReplacesRow() async throws {
        await open()
        let original = try #require(service.items.first { $0.message.id == "$old" })
        await show([file("$old", source: source, name: "edited-name.txt", edited: true)]) {
            self.service.items.first?.filename == "edited-name.txt"
        }
        #expect(service.items.count == 1 && service.items[0].message.isEdited)
        await #expect(throws: MatrixServiceError.self) {
            try await self.service.saveAttachment(original, to: self.temp.path("stale.txt"))
        }
        #expect(client.downloads.all.isEmpty)
    }

    @Test("A deleted file disappears and its old row can no longer download")
    func redactionRevokes() async throws {
        await open()
        let original = try #require(service.items.first { $0.message.id == "$old" })
        await show([FakeTimelineItem(textEvent("$old", body: "", redacted: true))]) { self.service.items.isEmpty }
        await #expect(throws: MatrixServiceError.self) {
            try await self.service.saveAttachment(original, to: self.temp.path("redacted.txt"))
        }
    }

    @Test("Images, videos and audio are listed alongside files")
    func mediaKinds() async {
        await open()
        await show([
            file("$image", source: source, kind: .image), file("$video", source: source, kind: .video),
            file("$audio", source: source, kind: .audio),
        ]) { self.service.items.count == 3 }
        #expect(Set(service.items.map(\.message.kind)) == ["m.image", "m.video", "m.audio"])
    }

    @Test("A thumbnail comes from the image's own thumbnail source, and an oversized answer is refused")
    func thumbnails() async throws {
        await open()
        let thumbnail = Source("mxc://example.org/small-thumb", identity: "thumbnail-key")
        await show([file("$image", source: source, kind: .image, thumbnail: thumbnail)]) {
            self.service.items.map(\.message.id) == ["$image"]
        }
        let image = service.items[0]
        #expect(try await service.thumbnailData(image) == Data([1, 2, 3, 4]))
        #expect(client.thumbnails.all.last === thumbnail)
        client.thumbnailBytes = Data(count: 10 * 1024 * 1024 + 1)
        await #expect(throws: MatrixServiceError.self) { _ = try await self.service.thumbnailData(image) }
    }

    @Test("An original of unknown size is never fetched as a thumbnail")
    func unknownSizeNotFetched() async {
        await open()
        await show([file("$unknown", source: source, kind: .image, size: nil)]) {
            self.service.items.map(\.message.id) == ["$unknown"]
        }
        await #expect(throws: MatrixServiceError.self) {
            _ = try await self.service.thumbnailData(self.service.items[0])
        }
        #expect(client.thumbnails.all.isEmpty)
    }

    @Test("Rich-text links are listed; spoilers and unsafe schemes are not, and a spoiler caption stays hidden")
    func links() async {
        await open()
        await show([
            text("$rich", body: "Visible link", html: "<a href='https://example.org/rich'>Visible link</a>"),
            text(
                "$spoiler", body: "https://secret.example",
                html: "<span data-mx-spoiler><a href='https://secret.example'>secret</a></span>"),
            text("$unsafe", body: "bad", html: "<a href='javascript:alert(1)'>bad</a>"),
            file(
                "$caption", source: source,
                caption: FormattedBody(format: .html, body: "<span data-mx-spoiler>https://secret.example</span>")),
        ]) { Set(self.service.items.map(\.message.id)) == ["$rich", "$caption"] }
        #expect(
            service.items.first { $0.message.id == "$rich" }?.links.map(\.absoluteString) == [
                "https://example.org/rich"
            ])
        #expect(!service.items.contains { $0.message.id == "$spoiler" || $0.message.id == "$unsafe" })
        #expect(service.items.first { $0.message.id == "$caption" }?.message.body == "[Spoiler hidden]")
    }

    @Test("A second save of the same file is refused; closing cancels the first without writing or leaving downloads")
    func closeCancelsDownload() async throws {
        await open()
        let pending = try #require(service.items.first { $0.message.id == "$old" })
        client.downloadGate.arm()
        let download = Task {
            try await service.saveAttachment(pending, to: temp.path("closed.txt"))
        }
        #expect(await eventually { self.client.downloadGate.isWaiting })
        await #expect(throws: MatrixServiceError.self) {
            try await self.service.saveAttachment(pending, to: self.temp.path("duplicate.txt"))
        }
        service.close()
        client.downloadGate.release()
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).allSatisfy { !$0.hasPrefix("sdk-") })
        #expect(
            !exists("closed.txt") && service.items.isEmpty && service.errorMessage == nil
                && service.savingItemIDs.isEmpty)
    }

    @Test("Rows from before the history was reopened cannot act")
    func reopenedScope() async throws {
        await open()
        let old = try #require(service.items.first { $0.message.id == "$old" })
        service.close()
        await open()
        await #expect(throws: MatrixServiceError.self) { _ = try await self.service.thumbnailData(old) }
    }

    @Test("Signing out during a download cancels it without writing or showing the old account's error")
    func signOutDuringDownload() async throws {
        await open()
        let current = try #require(service.items.first { $0.message.id == "$old" })
        client.downloadGate.arm()
        client.failDownload = true
        let download = Task { try await service.saveAttachment(current, to: temp.path("old.txt")) }
        #expect(await eventually { self.client.downloadGate.isWaiting })
        service.attach(nil)
        client.downloadGate.release()
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(service.errorMessage == nil && !exists("old.txt"))
    }

    @Test("Signing out during setup hides the late setup error and closes every listener without receipts")
    func signOutDuringSetup() async {
        await open()
        service.close()
        room.setupGate.arm()
        room.fail = true
        let setup = Task { await service.open(roomID: "!room:example.org") }
        #expect(await eventually { self.room.setupGate.isWaiting })
        service.attach(nil)
        room.setupGate.release()
        await setup.value
        #expect(service.state == "idle" && service.errorMessage == nil && service.items.isEmpty)
        #expect(room.history.allCancelled && room.history.receipts.all.isEmpty)
    }
}

struct SharedContentMappingTests {
    @Test("Links are de-duplicated and limited to http and https")
    func linkExtraction() {
        let rendered = RenderedMessageBody(
            runs: [
                MessageBodyRun(
                    text: "https://example.org https://example.org mailto:me@example.org",
                    link: URL(string: "https://example.org"))
            ], containsSpoilers: false, usedPlainTextFallback: false)
        #expect(SharedContentMapping.links(in: rendered) == [URL(string: "https://example.org")!])
    }

    @Test(
        "Saved filenames drop paths, traversal and control characters",
        arguments: [("..", "attachment"), ("/private/path/name\n.txt", "name.txt"), ("../report.txt", "report.txt")])
    func safeFilename(input: String, expected: String) {
        #expect(SharedContentMapping.safeFilename(input) == expected)
    }
}
