import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// Switching conversations in the whole window, offscreen, against SDK fakes whose timelines the test holds back;
/// needs an awake display. A recorder samples the window after every run-loop pass, once Core Animation has committed
/// it: which conversation the header names, which conversation's rows are on screen and where, whether a loading state
/// shows, which table shows them, and how many rows the pass measured.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ConversationSwitchHostedTests {
    struct Frame: CustomStringConvertible {
        var at: Duration
        var date = Date()
        var header: String?
        /// Visible message rows by event ID, with their top in the window.
        var rows: [String: CGFloat]
        var rooms: Set<String>
        var loading: Bool
        /// Placeholder rows holding the place of rows still being read.
        var skeleton = false
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
                "\(ms) ms header=\(header ?? "-") rows=\(rows.count) of \(rooms.sorted()) loading=\(loading) skeleton=\(skeleton) intro=\(intro) table=\(table) measured=\(measured)"
        }
    }

    @MainActor final class Harness {
        let rooms: [FakeOpenRoom]
        let matrix = MatrixService()
        let window: NSWindow
        let hosting: NSHostingView<AnyView>
        var frames: [Frame] = []
        private var observer: CFRunLoopObserver?
        private var clicked = ContinuousClock.now
        private var clickDate = Date()
        private var passes = 0

        init() {
            _ = NSApplication.shared
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
                    RootView(matrix: matrix).environmentObject(AppearanceStore())
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
            // SwiftUI draws the header and the placeholder rows from the service, in the body that hosts the timeline,
            // and has flushed that body by the time this runs.
            return Frame(
                at: ContinuousClock.now - clicked, header: matrix.selectedRoom?.name, rows: rows, rooms: rooms,
                loading: loading, skeleton: matrix.timelineLoading && matrix.messages.isEmpty, intro: intro,
                table: views.first { $0 is TimelineTableView }.map(ObjectIdentifier.init))
        }

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
            let measures = await performanceMessages(since: start).filter {
                $0.message.hasPrefix("interval=rows.measure ")
            }
            var previous = start
            for index in frames.indices {
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

        /// Until the window shows `index`'s newest message and nothing more is loading.
        func settled(on index: Int) async -> Bool {
            let newest = "$s\(index)-39"
            return await eventually(timeout: .seconds(20)) {
                let frame = sample()
                return frame.header == name(index) && frame.rows[newest] != nil && !frame.loading
            }
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
            if frame.intro && frame.skeleton {
                faults.append("introduces a conversation it has not read: \(frame)")
            }
            if frame.rows.isEmpty && (held || !(frame.skeleton || frame.loading)) {
                faults.append("empty pane: \(frame)")
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
        if let shown = frames.firstIndex(where: { $0.header == to }), shown > 0 {
            faults.append("the click's frame still shows the previous conversation: \(frames[0])")
        }
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
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settled(on: 0))
        harness.menu("next-conversation")
        #expect(await harness.settled(on: 1))
        await harness.idle()
        harness.record()
        harness.menu("back")
        #expect(await harness.settled(on: 0))
        let frames = await harness.stop()
        let faults = Self.faults(frames, to: harness.name(0), held: true)
        #expect(faults.isEmpty, Self.report(faults, frames))
    }

    /// A cache read of a few frames, as on disk, and a slow one.
    @Test(
        "Opening a conversation not held shows it at once, and its rows land where they stay",
        arguments: [200, 600])
    func coldSwitch(read milliseconds: Int) async throws {
        let harness = Harness()
        defer { harness.close() }
        #expect(await harness.settled(on: 0))
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
    }
}
