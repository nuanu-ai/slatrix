import AppKit
import MatrixRustSDK
import SwiftUI
import Testing

@testable import Slatrix

/// A timeline with nothing more to load either way.
private final class EndedTimeline: Timeline, @unchecked Sendable {
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool { true }
    override func paginateForwards(numEvents: UInt16) async throws -> Bool { true }
}

/// Random runs of what a busy channel does, checking after each change that every row on screen is as tall as its
/// content and drawn where its row is: the overlaps and gaps readers saw came from orders of changes no one wrote down.
/// It takes a minute and fills the process log the timeline's other tests read, so it runs on its own:
/// `SLATRIX_TIMELINE_FUZZ=1 scripts/test.sh --filter TimelineFuzzHostedTests`.
@MainActor
@Suite(.serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_TIMELINE_FUZZ"] != nil))
struct TimelineFuzzHostedTests {
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static let room = ChatRoom(id: "!fuzz:example.org", name: "Fuzz")
    static let other = ChatRoom(id: "!other:example.org", name: "Other")
    static let people = (0..<4).map { "@person-\($0)-with-a-long-id:a-long-homeserver-name.example.org" }

    struct Fixture: View {
        let service: MatrixService
        let room: ChatRoom
        let appearance: AppearanceStore
        let popovers: Popovers
        var zoom: CGFloat = 1
        var body: some View {
            TimelineView(
                matrix: service, room: room, savedIDs: [], onThread: { _ in }, onReply: { _ in }, onEdit: { _ in },
                onSave: { _ in }, onBottomVisibilityChange: { _ in },
                insets: EdgeInsets(top: 52, leading: 0, bottom: 100, trailing: 0)
            )
            .id(room.id)
            .environmentObject(appearance).environment(\.metrics, Metrics(zoom: zoom)).environment(popovers)
        }
    }

    static func body(_ rng: inout RNG, _ n: Int) -> (String, String?) {
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: return ("Short \(n)", nil)
        case 1:
            let text = String(
                repeating: "Words that wrap across the column. ", count: Int.random(in: 2..<12, using: &rng))
            return (text, nil)
        case 2:
            let who = people[Int.random(in: 0..<people.count, using: &rng)]
            let html =
                "<a href=\"https://matrix.to/#/\(who)\">\(who)</a>: " + String(repeating: "status text ", count: 6)
            return ("\(who): status", html)
        case 3:
            let items = (0..<Int.random(in: 2..<6, using: &rng)).map {
                "<li>Point \($0) with <code>inline code</code> and more words to wrap the line</li>"
            }
            return ("list", "<p>Intro \(n)</p><ul>\(items.joined())</ul>")
        case 4:
            return (
                "code",
                "<pre><code>"
                    + (0..<Int.random(in: 1..<8, using: &rng)).map { "line \($0)" }.joined(separator: "\n")
                    + "</code></pre>"
            )
        default:
            let who = people[Int.random(in: 0..<people.count, using: &rng)]
            return (
                "mention",
                (0..<5).map { _ in "<a href=\"https://matrix.to/#/\(who)\">\(who)</a>" }.joined(separator: " ")
            )
        }
    }

    static func message(_ rng: inout RNG, _ n: Int, at time: Double) -> ChatMessage {
        let sender = Int.random(in: 0..<3, using: &rng) == 0 ? "@reader:example.org" : people[n % people.count]
        let (body, html) = body(&rng, n)
        var message = ChatMessage(
            id: "fuzz-\(n)", roomID: room.id, senderID: sender, senderName: sender, body: body,
            timestamp: Date(timeIntervalSince1970: time))
        message.formattedBody = html
        if Int.random(in: 0..<5, using: &rng) == 0 {
            message.attachment = MessageAttachment(
                name: "file-\(n).json", url: "mxc://x/\(n)", mimeType: "application/json", size: 15_000)
            message.kind = "m.file"
        }
        return message
    }

    /// Visible rows that break the invariant, described.
    static func violations(_ hosting: NSView) -> [String] {
        guard
            let scroll = views(in: hosting).compactMap({ $0 as? TimelineScrollView }).first(where: {
                $0.window != nil
            }
            ),
            let table = scroll.documentView as? NSTableView
        else { return [] }
        guard let shown = Range(table.rows(in: scroll.contentView.bounds)) else { return [] }
        var problems: [String] = []
        for row in shown {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell,
                let shownRow = cell.row
            else { continue }
            switch shownRow.entry.kind {
            case .spacer, .end, .loading: continue
            default: break
            }
            let rect = table.rect(ofRow: row)
            let frame = cell.convert(cell.bounds, to: table)
            let fresh = TimelineCell(identifier: .init("fresh"))
            fresh.show(shownRow, commands: nil)
            let content = ceil(fresh.height(width: rect.width))
            if abs(rect.height - content) > 0.5 {
                problems.append("row \(shownRow.entry.id) height \(rect.height) content \(content)")
            }
            if abs(frame.minY - rect.minY) > 0.5 || abs(frame.height - rect.height) > 0.5 {
                problems.append("cell \(shownRow.entry.id) at \(frame) on row \(rect)")
            }
            if abs(cell.content.frame.height - cell.bounds.height) > 0.5 {
                problems.append("host \(shownRow.entry.id) \(cell.content.frame.height) in \(cell.bounds.height)")
            }
        }
        return problems
    }

    static func views(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    @Test(
        "Rows stay as tall as their content and on their rows through a busy channel's changes", arguments: 0..<10)
    func fuzz(seed: Int) async throws {
        var rng = RNG(state: UInt64(seed) &* 7919 &+ 17)
        let service = MatrixService()
        let appearance = AppearanceStore()
        let popovers = Popovers()
        let client = FakeClient(rooms: [FakeRoom(roomInfo(id: Self.room.id))])
        let user = ChatUser(id: "@reader:example.org", name: "Reader")
        service.user = user
        service.rooms = [Self.room, Self.other]
        service.selectedRoomID = Self.room.id
        service.configureMessageActionsForChecks(
            client: client, main: EndedTimeline(noHandle: .init()), thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        var time = 1_761_192_000.0
        var counter = 0
        var messages: [ChatMessage] = (0..<25).map { _ in
            counter += 1
            time += Double.random(in: 30..<4_000, using: &rng)
            return Self.message(&rng, counter, at: time)
        }
        service.messages = messages
        let window = offscreenWindow(NSSize(width: 900, height: 700))
        var fixture = Fixture(service: service, room: Self.room, appearance: appearance, popovers: popovers)
        let hosting = NSHostingView(rootView: fixture)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        var log: [String] = []
        func settle() async {
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                await drainMainActor()
            }
        }
        await settle()
        for step in 0..<30 {
            let op = Int.random(in: 0..<10, using: &rng)
            switch op {
            case 0, 1:
                counter += 1
                time += Double.random(in: 30..<9_000, using: &rng)
                messages.append(Self.message(&rng, counter, at: time))
                service.messages = messages
                log.append("append \(messages.last!.id)")
            case 2:
                let i = Int.random(in: 0..<messages.count, using: &rng)
                let (body, html) = Self.body(&rng, i)
                messages[i].body = body
                messages[i].formattedBody = html
                messages[i].isEdited = true
                service.messages = messages
                log.append("edit \(messages[i].id)")
            case 3:
                let i = Int.random(in: 0..<messages.count, using: &rng)
                messages[i].reactions =
                    messages[i].reactions.isEmpty
                    ? [MessageReaction(key: "👍", count: 1, mine: false, senders: [Self.people[0]])] : []
                service.messages = messages
                log.append("react \(messages[i].id)")
            case 4:
                service.members =
                    service.members.isEmpty ? Self.people.enumerated().map { ChatUser(id: $1, name: "P\($0)") } : []
                log.append("members \(service.members.count)")
            case 5:
                let scroll = Self.views(in: hosting).compactMap { $0 as? TimelineScrollView }.first!
                let clip = scroll.contentView
                clip.setBoundsOrigin(
                    NSPoint(x: 0, y: max(0, clip.bounds.minY + CGFloat.random(in: -900..<600, using: &rng))))
                scroll.reflectScrolledClipView(clip)
                log.append("scroll")
            case 6:
                let width = CGFloat.random(in: 520..<1_200, using: &rng).rounded()
                window.setContentSize(NSSize(width: width, height: 700))
                log.append("width \(width)")
            case 7:
                fixture.zoom = [1, 1.15, 0.9][Int.random(in: 0..<3, using: &rng)]
                hosting.rootView = fixture
                log.append("zoom \(fixture.zoom)")
            case 8:
                hosting.rootView = Fixture(
                    service: service, room: Self.other, appearance: appearance, popovers: popovers,
                    zoom: fixture.zoom)
                await settle()
                hosting.rootView = fixture
                log.append("away and back")
            default:
                counter += 1
                time += 1
                let older = (0..<5).map { k -> ChatMessage in
                    var m = Self.message(
                        &rng, counter * 100 + k,
                        at: messages[0].timestamp.timeIntervalSince1970 - Double(5 - k) * 60)
                    m.id = "older-\(counter)-\(k)"
                    return m
                }
                messages = older + messages
                service.messages = messages
                log.append("older")
            }
            await settle()
            let settled = await eventually(timeout: .milliseconds(600)) {
                // Lets AppKit finish anything it runs from the run loop, as the app's would.
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                hosting.layoutSubtreeIfNeeded()
                return Self.violations(hosting).isEmpty
            }
            if !settled {
                Issue.record(
                    "seed \(seed) step \(step) after \(log.suffix(4)): \(Self.violations(hosting).prefix(3))")
                return
            }
        }
    }
}
