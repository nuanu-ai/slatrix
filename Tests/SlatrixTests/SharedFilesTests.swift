import AppKit
import MatrixRustSDK
import SwiftUI
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
    var joined = Membership.joined
    init(_ values: [TimelineItem]) {
        history = History(values)
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func membership() -> Membership { joined }
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
                filename: name, caption: nil, formattedCaption: caption, source: source,
                info: VideoInfo(
                    duration: 12, height: 720, width: 1_280, mimetype: "video/mp4", size: size, thumbnailInfo: nil,
                    thumbnailSource: thumbnail, blurhash: nil)))
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
    private let matrix = MatrixService()
    private var service: SharedFilesService { matrix.sharedFiles }

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

    // capability: conversation.files
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

    @Test("A row's file downloads like a conversation's while that is closed: the original, uncached, safely named")
    func servesClosedConversation() async throws {
        await open()
        let row = try #require(service.items.first { $0.message.id == "$old" })
        #expect(matrix.attachmentSourceRevision(row.message) != nil)
        let file = try await matrix.prepareAttachmentPreview(row.message)
        #expect(try Data(contentsOf: file.url) == Data("downloaded bytes".utf8))
        let download = try #require(client.downloads.all.first)
        #expect(download.source === source && !download.cached && download.filename == "report.txt")
    }

    @Test("An edit replaces the row, and the old row can no longer download")
    func editReplacesRow() async throws {
        await open()
        let original = try #require(service.items.first { $0.message.id == "$old" })
        await show([file("$old", source: source, name: "edited-name.txt", edited: true)]) {
            self.service.items.first?.filename == "edited-name.txt"
        }
        #expect(service.items.count == 1 && service.items[0].message.isEdited)
        await #expect(throws: (any Error).self) { _ = try await self.matrix.prepareAttachmentPreview(original.message) }
        #expect(client.downloads.all.isEmpty)
    }

    @Test("A deleted file disappears and its old row can no longer download")
    func redactionRevokes() async throws {
        await open()
        let original = try #require(service.items.first { $0.message.id == "$old" })
        await show([FakeTimelineItem(textEvent("$old", body: "", redacted: true))]) { self.service.items.isEmpty }
        await #expect(throws: (any Error).self) { _ = try await self.matrix.prepareAttachmentPreview(original.message) }
        #expect(client.downloads.all.isEmpty)
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

    @Test("A video without a poster is never fetched whole as its own thumbnail")
    func videoWithoutPoster() async {
        await open()
        await show([file("$video", source: source, kind: .video)]) {
            self.service.items.map(\.message.id) == ["$video"]
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

    @Test("Closing cancels a download without leaving its file")
    func closeCancelsDownload() async throws {
        await open()
        let pending = try #require(service.items.first { $0.message.id == "$old" })
        client.downloadGate.arm()
        let download = Task { try await matrix.prepareAttachmentPreview(pending.message) }
        #expect(await eventually { self.client.downloadGate.isWaiting })
        service.close()
        client.downloadGate.release()
        await #expect(throws: CancellationError.self) { _ = try await download.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).allSatisfy { !$0.hasPrefix("sdk-") })
        #expect(service.items.isEmpty && service.errorMessage == nil)
    }

    @Test("Rows from another conversation's list cannot act")
    func reopenedScope() async throws {
        await open()
        let old = try #require(service.items.first { $0.message.id == "$old" })
        service.close()
        await service.open(roomID: "!other:example.org")
        await #expect(throws: MatrixServiceError.self) { _ = try await self.service.thumbnailData(old) }
    }

    @Test("Coming back to a conversation's files shows its rows without waiting, then follows its timeline")
    func reopenShowsKeptRows() async throws {
        await open()
        #expect(await eventually { self.service.items.count == 2 })
        service.close()
        room.setupGate.arm()
        defer { room.setupGate.release() }
        let reopening = Task { await service.open(roomID: "!room:example.org") }
        #expect(await eventually { self.service.items.map(\.message.id) == ["$link", "$old"] })
        let row = try #require(service.items.first { $0.message.id == "$old" })
        #expect(matrix.attachmentSourceRevision(row.message) != nil)
        room.setupGate.release()
        await reopening.value
        await show([file("$new", source: source, name: "new.txt")]) {
            self.service.items.map(\.message.id) == ["$new"]
        }
    }

    @Test("Kept rows never show for another conversation, or after the account changes")
    func keptRowsStayTheirs() async {
        await open()
        #expect(await eventually { self.service.items.count == 2 })
        // Another conversation, then the same one under a new sign-in, each still reading its timeline.
        service.close()
        await expectNoRowsWhileOpening("!other:example.org")
        await open()
        service.attach(client)
        await expectNoRowsWhileOpening("!room:example.org")
    }

    @Test("A conversation left while its list was kept opens without the old rows")
    func keptRowsGoWhenLeft() async {
        await open()
        service.close()
        room.joined = .left
        await service.open(roomID: "!room:example.org")
        #expect(service.items.isEmpty && service.state == "error")
    }

    @Test("Refresh reads the conversation's timeline again instead of the kept list")
    func refreshRebuilds() async {
        await open()
        room.setupGate.arm()
        let refreshing = Task { await service.reload(roomID: "!room:example.org") }
        #expect(await eventually { self.room.setupGate.isWaiting })
        room.setupGate.release()
        await refreshing.value
    }

    @Test("A list left while a page was loading is read afresh, so two pages never load at once")
    func midPageNotKept() async {
        await open()
        room.history.pageGate.arm()
        let page = Task { await service.loadMore() }
        #expect(await eventually { self.room.history.pageGate.isWaiting })
        service.close()
        room.setupGate.arm()
        let opening = Task { await service.open(roomID: "!room:example.org") }
        #expect(await eventually { self.room.setupGate.isWaiting })
        room.setupGate.release()
        room.history.pageGate.release()
        await page.value
        await opening.value
    }
    private func expectNoRowsWhileOpening(_ roomID: String) async {
        room.setupGate.arm()
        let opening = Task { await service.open(roomID: roomID) }
        #expect(await eventually { self.room.setupGate.isWaiting })
        #expect(service.items.isEmpty)
        room.setupGate.release()
        await opening.value
    }

    @Test("Signing out during a download cancels it without surfacing the old account's error")
    func signOutDuringDownload() async throws {
        await open()
        let current = try #require(service.items.first { $0.message.id == "$old" })
        client.downloadGate.arm()
        client.failDownload = true
        let download = Task { try await matrix.prepareAttachmentPreview(current.message) }
        #expect(await eventually { self.client.downloadGate.isWaiting })
        service.attach(nil)
        client.downloadGate.release()
        await #expect(throws: CancellationError.self) { _ = try await download.value }
        #expect(service.errorMessage == nil)
    }

    @Test("Signing out during setup hides the late setup error and closes every listener without receipts")
    func signOutDuringSetup() async {
        await open()
        service.close()
        room.setupGate.arm()
        room.fail = true
        // Another conversation, so the first one's list is kept and signing out must close it too.
        let setup = Task { await service.open(roomID: "!other:example.org") }
        #expect(await eventually { self.room.setupGate.isWaiting })
        service.attach(nil)
        room.setupGate.release()
        await setup.value
        #expect(service.state == "idle" && service.errorMessage == nil && service.items.isEmpty)
        #expect(room.history.allCancelled && room.history.receipts.all.isEmpty)
    }
}

/// A channel's Files tab in a real offscreen window, over SDK fakes; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
final class SharedFilesReopenHostedTests {
    private let temp: TemporaryDirectory
    private let room = SharedRoom([file("$guide", source: Source("mxc://example.org/guide"), name: "guidelines.pdf")])
    private let matrix = MatrixService()

    init() throws {
        temp = try TemporaryDirectory()
        matrix.sharedFiles.attach(SharedClient(room, folder: temp.url))
    }

    @Test("Coming back to a channel's Files draws its files in the first frame")
    func reopenDrawsRowsAtOnce() async throws {
        _ = NSApplication.shared
        let window = offscreenWindow(NSSize(width: 900, height: 700))
        defer {
            room.setupGate.release()
            window.contentView = nil
            window.close()
        }
        func mount() -> NSView {
            let hosting = NSHostingView(
                rootView: SharedFilesView(
                    matrix: matrix, service: matrix.sharedFiles, workspaceID: nil, channelID: "!room:example.org",
                    onOpen: { _ in }, onOpenMedia: { _, _ in }
                ).frame(width: 900, height: 700).environmentObject(AppearanceStore()))
            window.contentView = hosting
            return hosting
        }
        let first = mount()
        #expect(await eventually { Self.drawsPDFTile(first) })

        window.contentView = nil
        // The timeline behind the list now takes as long as it likes.
        room.setupGate.arm()
        #expect(Self.drawsPDFTile(mount()))
    }

    /// Whether the view draws a clear red, as only a PDF's tile does here.
    private static func drawsPDFTile(_ view: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: image)
        return stride(from: 0, to: image.pixelsHigh, by: 2).contains { y in
            stride(from: 0, to: image.pixelsWide, by: 2).contains { x in
                guard let pixel = image.colorAt(x: x, y: y) else { return false }
                return pixel.redComponent - pixel.greenComponent > 0.4 && pixel.redComponent - pixel.blueComponent > 0.4
            }
        }
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

    @Test(
        "A Files row says who shared it, where and when: no place for a DM, no # for a private channel, an old year",
        arguments: [
            (false, false, "2026-10-24", "Shared by Alice in #design · Oct 24"),
            (true, false, "2026-10-24", "Shared by Alice · Oct 24"),
            (false, true, "2026-10-24", "Shared by Alice in design · Oct 24"),
            (false, false, "2025-03-02", "Shared by Alice in #design · Mar 2, 2025"),
        ])
    func caption(direct: Bool, isPrivate: Bool, day: String, expected: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US")
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let parse = Date.ISO8601FormatStyle().year().month().day()
        let room = ChatRoom(
            id: "!design:example.org", name: direct ? "Alice" : "design", isDirect: direct, isPrivate: isPrivate)
        #expect(
            SharedContentMapping.caption(
                sender: "Alice", room: room, date: try parse.parse(day), now: try parse.parse("2026-10-26"),
                calendar: calendar) == expected)
    }
}
