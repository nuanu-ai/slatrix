import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// Switching conversations in the whole window, offscreen, against SDK fakes whose timelines the test holds back;
/// needs an awake display. A recorder samples the window after every run-loop pass, once Core Animation has committed
/// it: which conversation the header shows, which conversation's rows are on screen and where, whether placeholder rows
/// or a spinner show, which table shows the rows, and how many rows the pass measured. The header and the placeholder
/// rows are read from the window's pixels, as drawn.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ConversationSwitchHostedTests {
    struct Frame: CustomStringConvertible {
        var at: Duration
        var date = Date()
        /// The conversation whose header the frame shows, told apart by its pixels once the recording ends.
        var header: String?
        var headerPixels: [Int] = []
        /// Visible message rows by event ID, with their top in the window.
        var rows: [String: CGFloat]
        var rooms: Set<String>
        var loading: Bool
        /// Placeholder rows drawn in the message pane, holding the place of rows being read.
        var placeholder = false
        /// The conversation's introduction, which tops one read back to its start.
        var intro = false
        /// The timeline's table; a new one builds its cells and measures every row it shows afresh.
        var table: ObjectIdentifier?
        /// Rows measured in the pass that drew this frame.
        var measured = 0
        var description: String {
            let ms = Int((at / .milliseconds(1)).rounded())
            let table = table.map { String(UInt(bitPattern: $0.hashValue) % 10_000) } ?? "-"
            return
                "\(ms) ms header=\(header ?? "-") rows=\(rows.count) of \(rooms.sorted()) loading=\(loading) placeholder=\(placeholder) intro=\(intro) table=\(table) measured=\(measured)"
        }
    }

    @MainActor final class Harness {
        let rooms: [FakeOpenRoom]
        /// Credentials and vaults of its own, so the window never reaches the development build's.
        private let folder: TemporaryDirectory
        let matrix: MatrixService
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        var frames: [Frame] = []
        /// What the app logged about its speed from the click on.
        var log: [String] = []
        private var observer: CFRunLoopObserver?
        private var clicked = ContinuousClock.now
        private var clickDate = Date()
        private var passes = 0

        init() throws {
            _ = NSApplication.shared
            folder = try TemporaryDirectory()
            let credentials = SecureSessionStore(file: folder.path("credentials.json"))
            // Signed in as far as the drafts vault can tell, so it can make the account's key.
            try credentials.save(
                StoredSession(
                    accessToken: "synthetic-token", userId: "@me:example.org", deviceId: "FIXTURE",
                    homeserverUrl: "https://example.org", storeID: UUID().uuidString,
                    storeKey: Data(repeating: 0x31, count: 32)))
            let key: @Sendable (String) async throws -> Data = { try credentials.localStateKey(accountID: $0) }
            matrix = MatrixService(
                credentials: credentials, storeRoots: [folder.path("support"), folder.path("caches")])
            // Every window opens as it first would, on the first conversation.
            for key in ["layout.paneWidth", "layout.sidebarHidden", "room.@me:example.org"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
            let rooms = (0..<4).map { index in
                FakeOpenRoom(
                    "!switch\(index):example.org",
                    cached: (0..<40).map { message in
                        FakeTimelineItem(
                            textEvent(
                                "$s\(index)-\(message)",
                                body: "Room \(index) message \(message). "
                                    + String(repeating: "Words that wrap the line. ", count: message % 4 * 3),
                                sender: message % 3 == 0 ? "@alice:example.org" : "@bob:example.org",
                                timestamp: 1_700_000_000_000 + UInt64(message) * 60_000))
                    })
            }
            self.rooms = rooms
            // Older pages wait on the server throughout, so the rows only change when the switch changes them.
            for room in rooms { room.pageGate.arm() }
            matrix.configureRoomOpenForChecks(
                client: FakeClient(rooms: rooms), roomList: FakeRoomListService(),
                user: ChatUser(id: "@me:example.org", name: "Me"))
            matrix.status = .ready
            hosting = NSHostingView(
                rootView: AnyView(
                    RootView(
                        matrix: matrix,
                        localStore: ProtectedLocalStateStore(
                            directory: ProtectedLocalStateStore.directory(in: folder.url), keyProvider: key),
                        attachmentDrafts: AttachmentDraftStore(
                            directory: AttachmentDraftStore.directory(in: folder.url), keyProvider: key)
                    ).environmentObject(AppearanceStore())
                        .environment(\.metrics, Metrics(zoom: 1))))
            window = offscreenWindow(
                NSSize(width: 1_440, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = hosting
            window.orderFrontRegardless()
            hosting.layoutSubtreeIfNeeded()
            // As sync delivers them, once the window is up.
            matrix.rooms = rooms.indices.map { ChatRoom(id: rooms[$0].id(), name: "room-\($0)") }
            matrix.roomsLoaded = true
        }

        func close() {
            for room in rooms { room.pageGate.release() }
            if let observer { CFRunLoopObserverInvalidate(observer) }
            window.contentView = nil
            window.close()
        }

        func name(_ index: Int) -> String { "room-\(index)" }

        static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

        /// What the window shows now, without laying anything out.
        func sample() -> Frame {
            let views = Self.views(in: hosting).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            var rows: [String: CGFloat] = [:]
            var rooms = Set<String>()
            var intro = false
            for case let cell as TimelineCell in views {
                guard let scroll = cell.enclosingScrollView, cell.frame.height > 1,
                    cell.convert(cell.bounds, to: nil).intersects(scroll.convert(scroll.bounds, to: nil))
                else { continue }
                switch cell.entry?.kind {
                case .message(let entry):
                    rows[entry.message.eventID] = cell.convert(cell.bounds, to: nil).minY
                    rooms.insert(entry.message.roomID)
                case .welcome: intro = true
                default: break
                }
            }
            // The timeline's own; the composer has a spinner of its own.
            let loading = views.contains { $0 is NSProgressIndicator && $0.enclosingScrollView is TimelineScrollView }
            var frame = Frame(
                at: ContinuousClock.now - clicked, rows: rows, rooms: rooms, loading: loading, intro: intro,
                table: views.first { $0 is TimelineTableView }.map(ObjectIdentifier.init))
            // The header runs over the timeline's top and the composer over its bottom; between them is the pane.
            if let scroll = views.first(where: { $0 is TimelineScrollView }) as? NSScrollView {
                let column = scroll.convert(scroll.bounds, to: nil)
                let insets = scroll.contentInsets
                // Its left part, the conversation's name, without the controls whose state changes as one moves about.
                frame.headerPixels = pixels(
                    in: CGRect(
                        x: column.minX, y: column.maxY - insets.top, width: column.width * 0.4, height: insets.top),
                    every: 1)
                if rows.isEmpty {
                    let pane = pixels(
                        in: CGRect(
                            x: column.minX, y: column.minY + insets.bottom, width: column.width,
                            height: column.height - insets.top - insets.bottom), every: 4)
                    // Eight placeholder rows tint about 4% of it.
                    frame.placeholder = Self.tinted(pane) > 0.02
                }
            }
            return frame
        }

        /// The window's pixels in `rect`, a frame in the window, as drawn, one every `points`: red, green and blue, a
        /// byte each.
        func pixels(in rect: CGRect, every points: Int) -> [Int] {
            let local = hosting.convert(rect, from: nil).integral
            // Drawn at one pixel to the step, as drawing the whole pane at the screen's scale takes several frames.
            guard local.width >= CGFloat(points), local.height >= CGFloat(points),
                let image = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(local.width) / points,
                    pixelsHigh: Int(local.height) / points, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB,
                    bytesPerRow: 0, bitsPerPixel: 0),
                let data = image.bitmapData
            else { return [] }
            image.size = local.size
            hosting.cacheDisplay(in: local, to: image)
            let bytes = image.bitsPerPixel / 8
            var pixels: [Int] = []
            pixels.reserveCapacity(image.pixelsHigh * image.pixelsWide)
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    let at = y * image.bytesPerRow + x * bytes
                    pixels.append(Int(data[at]) << 16 | Int(data[at + 1]) << 8 | Int(data[at + 2]))
                }
            }
            return pixels
        }

        /// How far apart two pixels are in each channel: the furthest and the nearest.
        static func apart(_ a: Int, _ b: Int) -> (most: Int, least: Int) {
            let red = abs(a >> 16 - b >> 16)
            let green = abs((a >> 8 & 0xFF) - (b >> 8 & 0xFF))
            let blue = abs((a & 0xFF) - (b & 0xFF))
            return (max(red, green, blue), min(red, green, blue))
        }

        /// The share of `pixels` tinted a shade off the background, the commonest one, as placeholder rows are filled;
        /// text, banners and cards stand out further.
        static func tinted(_ pixels: [Int]) -> Double {
            var counts: [Int: Int] = [:]
            for index in stride(from: 0, to: pixels.count, by: 16) { counts[pixels[index], default: 0] += 1 }
            guard let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
            let tinted = pixels.count { pixel in
                let apart = apart(pixel, background)
                return apart.least >= 4 && apart.most <= 24
            }
            return Double(tinted) / Double(pixels.count)
        }

        /// The header's pixels for each conversation, read when the window settles on it.
        private var headers: [String: [Int]] = [:]

        /// Samples the window after every run-loop pass from now on.
        func record() {
            frames = []
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
            ) { [weak self] _, _ in
                MainActor.assumeIsolated { if let self { self.frames.append(self.sample()) } }
            }
            self.observer = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }

        /// Records a few more passes, for anything that lands late, then counts the rows each pass measured from the
        /// app's performance log.
        func stop() async -> [Frame] {
            let count = frames.count
            _ = await eventually { frames.count >= count + 10 }
            if let observer { CFRunLoopObserverInvalidate(observer) }
            observer = nil
            let start = clickDate
            frames.removeAll { $0.date < start }
            let messages = await performanceMessages(since: start)
            log = messages.map(\.message)
            let measures = messages.filter { $0.message.hasPrefix("interval=rows.measure ") }
            var previous = start
            for index in frames.indices {
                frames[index].header = header(frames[index].headerPixels)
                frames[index].measured = measures.filter { $0.date > previous && $0.date <= frames[index].date }
                    .compactMap { $0.message.split(separator: " ").first { $0.hasPrefix("rows=") } }
                    .compactMap { Int($0.dropFirst(5)) }.reduce(0, +)
                previous = frames[index].date
            }
            return frames
        }

        /// As the app's menu sends it, woken from the run loop's wait as an event is: main-actor work the action queues
        /// runs before the frame is drawn, as after a real click. Sent from a main-actor job instead, that work would
        /// wait for the frame after.
        func menu(_ action: String) {
            let click = Timer(timeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    self.clicked = .now
                    self.clickDate = Date()
                    NotificationCenter.default.post(name: .menuAction, object: nil, userInfo: ["action": action])
                }
            }
            RunLoop.main.add(click, forMode: .common)
        }

        /// Clicks a notification for `eventID` in conversation `index`, as the OS hands its payload back.
        func notify(_ index: Int, _ eventID: String) throws {
            let sent = try #require(
                MatrixNotificationTarget(accountID: "@me:example.org", roomID: rooms[index].id(), eventID: eventID))
            PlatformIntegration.shared.open(try #require(MatrixNotificationTarget(userInfo: sent.userInfo)))
        }

        /// Until ten run-loop passes go by without a row measured, so the rows measured after a click are the click's
        /// and not those the conversation on screen was still preparing for a scroll.
        func idle() async {
            let counter = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
            ) { [weak self] _, _ in MainActor.assumeIsolated { self?.passes += 1 } }
            CFRunLoopAddObserver(CFRunLoopGetMain(), counter, .commonModes)
            defer { CFRunLoopObserverInvalidate(counter) }
            for _ in 0..<20 {
                let since = Date()
                let start = passes
                _ = await eventually { passes >= start + 10 }
                let measured = await performanceMessages(since: since).contains {
                    $0.message.hasPrefix("interval=rows.measure ")
                }
                if !measured { return }
            }
        }

        /// Until the window shows `index`'s newest message and nothing more is loading, then keeps its header.
        func settled(on index: Int) async -> Bool {
            let newest = "$s\(index)-39"
            var frame = sample()
            let settled = await eventually(timeout: .seconds(20)) {
                frame = sample()
                return frame.rows[newest] != nil && frame.rooms.count == 1 && !frame.loading
                    && Self.views(in: hosting).contains { ($0 as? NSTextView)?.isEditable == true }
            }
            headers[name(index)] = frame.headerPixels
            return settled
        }

        /// The conversation whose header `pixels` are closest to.
        private func header(_ pixels: [Int]) -> String? {
            headers.filter { $0.value.count == pixels.count }.min { a, b in
                distance(a.value, pixels) < distance(b.value, pixels)
            }?.key
        }

        private func distance(_ a: [Int], _ b: [Int]) -> Int {
            zip(a, b).reduce(0) { $0 + Self.apart($1.0, $1.1).most }
        }
    }

    /// What the reader would see wrong in `frames`, a switch to `to`.
    static func faults(_ frames: [Frame], to: String, held: Bool) -> [String] {
        func roomID(_ name: String?) -> String? { name.map { "!switch\($0.dropFirst(5)):example.org" } }
        var faults: [String] = []
        var firstSeen: [String: CGFloat] = [:]
        var loadingSince: Duration?
        for frame in frames {
            if Set([roomID(frame.header)].compactMap { $0 }).union(frame.rooms).count > 1 {
                faults.append("mixes conversations: \(frame)")
            }
            if frame.intro && frame.rows.isEmpty {
                faults.append("introduces a conversation it has not read: \(frame)")
            }
            // A conversation not held goes up empty, and placeholder rows hold its rows' place only past the delay
            // any loading state waits, which most reads never reach.
            let delay = LoadingPresentation.indicatorDelay
            if frame.rows.isEmpty && held {
                faults.append("empty pane: \(frame)")
            } else if frame.rows.isEmpty && frame.placeholder && frame.at < delay {
                faults.append("placeholder rows before the loading delay: \(frame)")
            } else if frame.rows.isEmpty, !frame.placeholder, !frame.loading, frame.at > delay + .milliseconds(100) {
                faults.append("empty pane past the loading delay: \(frame)")
            }
            for (id, top) in frame.rows where frame.header == to {
                if let first = firstSeen[id], abs(first - top) > 0.5 {
                    faults.append("\(id) moved \(Int(top - first)) pt: \(frame)")
                }
                firstSeen[id] = firstSeen[id] ?? top
            }
            if frame.loading {
                loadingSince = loadingSince ?? frame.at
            } else if let since = loadingSince {
                if frame.at - since < LoadingPresentation.indicatorDelay {
                    faults.append("loading state for \(Int((frame.at - since) / .milliseconds(1))) ms: \(frame)")
                }
                loadingSince = nil
            }
        }
        for (before, after) in zip(frames, frames.dropFirst())
        where before.header == after.header && before.table != nil && before.table != after.table {
            faults.append("a new table for the conversation on screen: \(after)")
        }
        // The click's frame shows the next conversation.
        if let click = frames.first, click.header != to {
            faults.append("the click's frame still shows the previous conversation: \(click)")
        }
        if frames.isEmpty { faults.append("no frame recorded") }
        // Rows already held come with their heights; others are measured for the first screen only, once they are read.
        if let click = frames.first, click.rows.isEmpty, click.measured > 0 {
            faults.append("measured \(click.measured) rows before any were read: \(click)")
        }
        if let first = frames.first(where: { $0.header == to && !$0.rows.isEmpty }),
            first.measured > (held ? 0 : first.rows.count + 2)
        {
            faults.append("measured \(first.measured) rows to show \(first.rows.count): \(first)")
        }
        return faults
    }

    static func report(_ faults: [String], _ frames: [Frame]) -> Comment {
        "\(faults.joined(separator: "\n"))\nframes:\n\(frames.map(\.description).joined(separator: "\n"))"
    }

    @Test("Coming back to a conversation still open shows it whole in the frame of the click, and nothing moves")
    func heldSwitch() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(await harness.settled(on: 0))
        harness.menu("next-conversation")
        try #require(await harness.settled(on: 1))
        await harness.idle()
        harness.record()
        harness.menu("back")
        #expect(await harness.settled(on: 0))
        let frames = await harness.stop()
        let faults = Self.faults(frames, to: harness.name(0), held: true)
        #expect(faults.isEmpty, Self.report(faults, frames))
        // The performance report counts it too.
        #expect(harness.log.contains { $0.hasPrefix("interval=room.open ") && $0.hasSuffix(" measured=0") })
    }

    /// A cache read of a few frames, as on disk, and a slow one.
    @Test(
        "Opening a conversation not held shows it at once, and its rows land where they stay",
        arguments: [200, 600])
    func coldSwitch(read milliseconds: Int) async throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(await harness.settled(on: 0))
        await harness.idle()
        harness.rooms[1].buildGate.arm()
        harness.record()
        harness.menu("next-conversation")
        let read = ContinuousClock.now + .milliseconds(milliseconds)
        _ = await eventually { ContinuousClock.now >= read }
        harness.rooms[1].buildGate.release()
        #expect(await harness.settled(on: 1))
        let frames = await harness.stop()
        let faults = Self.faults(frames, to: harness.name(1), held: false)
        #expect(faults.isEmpty, Self.report(faults, frames))
        // Frames drawn while the read was held, with placeholder rows once it outlasted the loading delay.
        let reading = frames.filter { $0.at < .milliseconds(milliseconds) && $0.rows.isEmpty }
        let outlasted = Duration.milliseconds(milliseconds) > LoadingPresentation.indicatorDelay
        #expect(!reading.isEmpty && reading.contains(where: \.placeholder) == outlasted, Self.report([], frames))
    }

    @Test("A jump to a message the conversation on screen lacks keeps its table while it checks the live timeline")
    func jumpKeepsPane() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(await harness.settled(on: 0))
        await harness.idle()
        let before = harness.sample()
        let room = harness.rooms[0]
        room.focusedItems = [FakeTimelineItem(textEvent("$far", body: "Far back"))]
        room.buildGate.arm()
        let jumping = Task { await harness.matrix.jumpToMessage(roomID: room.id(), eventID: "$far") }
        #expect(await eventually { room.buildGate.isWaiting })
        // Long enough for the window to draw whatever the jump changed.
        await harness.idle()
        let held = harness.sample()
        #expect(before.table != nil && held.table == before.table && held.rows == before.rows, "\(before)\n\(held)")
        room.buildGate.release()
        await jumping.value
    }

    /// Room `index` with a thread on its message `root` holding `$reply`.
    private func thread(_ harness: Harness, _ index: Int, root: String) {
        let room = harness.rooms[index]
        room.threadRoots["$reply"] = root
        room.threadItems = [
            FakeTimelineItem(textEvent(root, body: "Root")), FakeTimelineItem(textEvent("$reply", body: "Reply")),
        ]
    }

    // capability: thread.from-notification
    @Test("A notification for a thread reply opens its conversation with the reply in its thread beside it")
    func notificationOpensReply() async throws {
        let harness = try Harness()
        defer { harness.close() }
        try #require(await harness.settled(on: 0))
        thread(harness, 1, root: "$s1-30")
        try harness.notify(1, "$reply")
        #expect(await eventually(timeout: .seconds(20)) { harness.sample().rows["$reply"] != nil })
        #expect(harness.matrix.selectedRoomID == harness.rooms[1].id())
    }
}
