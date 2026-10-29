import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class ReceiptTimeline: Timeline, @unchecked Sendable {
    let writes = Recorder<String>()
    let readGate = Gate()
    let forwardGate = Gate()
    var failure: ReceiptType?
    var forwardEnd = false
    override func sendReadReceipt(receiptType: ReceiptType, eventId: String) async throws {
        writes.append("\(receiptType == .read ? "read" : "fully"):\(eventId)")
        if receiptType == .read { await readGate.wait() }
        if failure == receiptType { throw MatrixServiceError.request("receipt failed") }
    }
    override func paginateForwards(numEvents: UInt16) async throws -> Bool {
        await forwardGate.wait()
        return forwardEnd
    }
}

private final class ReceiptRoom: Room, @unchecked Sendable {
    let writes = Recorder<String>()
    let readGate = Gate()
    override func markAsRead(receiptType: ReceiptType) async throws {
        writes.append(receiptType == .read ? "read" : "fully")
        if receiptType == .read { await readGate.wait() }
    }
}

private let roomID = "!unread:example.org"
private let marker = FakeTimelineItem(virtual: .readMarker)

private func remote(_ id: String) -> FakeTimelineItem { FakeTimelineItem(textEvent(id, body: "Message")) }

/// The shared cases in `spec/unread-line.json`.
struct UnreadLineSpec: Decodable {
    struct Line: Decodable, CustomTestStringConvertible {
        var name: String
        var items: [String]
        var line: String?
        var testDescription: String { name }
    }
    struct Room: Decodable {
        var messages, notifications: Int?
        var markedUnread: Bool?
        var membership, fullyRead: String?
    }
    struct Resume: Decodable, CustomTestStringConvertible {
        var name: String
        var room: Room
        var anchor: String?
        var testDescription: String { name }
    }
    var line: [Line]
    var resume: [Resume]
}

struct UnreadMappingTests {
    // capability: conversation.unread-line
    @Test("The first unread message is the next remote message after the SDK's read marker")
    func firstAfterMarker() {
        var local = textEvent("$misleading-local", body: "Local")
        local.isRemote = false
        local.eventOrTransactionId = .transactionId(transactionId: "local")
        var state = textEvent("$state", body: "")
        state.content = .roomMembership(userId: "@member:example.org", userDisplayName: nil, change: nil, reason: nil)
        let items = [
            remote("$read"), marker, FakeTimelineItem(virtual: .dateDivider(ts: 0)), FakeTimelineItem(local),
            FakeTimelineItem(state),
            remote("$first"),
        ]
        #expect(UnreadMapping.firstUnreadEventID(in: items, roomID: roomID, ownUserID: nil) == "$first")
    }

    @Test("Where the New line goes", arguments: try SharedSpec.decode("spec/unread-line.json", as: UnreadLineSpec.self).line)
    func line(spec: UnreadLineSpec.Line) {
        let marks = spec.items.map { item in
            switch item {
            case "marker": UnreadMapping.Mark(isReadMarker: true)
            case "hidden": UnreadMapping.Mark()
            default: UnreadMapping.Mark(shownEventID: item)
            }
        }
        #expect(UnreadMapping.firstUnreadEventID(in: marks) == spec.line)
    }

    @Test("A deleted message after the marker is still the boundary")
    func deletedMessageIsBoundary() {
        let items = [marker, FakeTimelineItem(textEvent("$deleted", body: "", redacted: true))]
        #expect(UnreadMapping.firstUnreadEventID(in: items, roomID: roomID, ownUserID: nil) == "$deleted")
    }
}

struct UnreadNavigationTests {
    private let room = ChatRoom(id: roomID, name: "Room", unreadMessages: 4, fullyReadEventID: "$anchor")

    private func anchor(
        _ room: ChatRoom?, selected: String? = nil, explicit: String? = nil, thread: Bool = false
    ) -> String? {
        UnreadNavigation.resumeAnchor(
            for: room, selectedRoomID: selected, explicitEventID: explicit, opensThread: thread)
    }

    @Test("Where an unread conversation opens", arguments: try SharedSpec.decode("spec/unread-line.json", as: UnreadLineSpec.self).resume)
    func resume(spec: UnreadLineSpec.Resume) {
        var room = ChatRoom(id: roomID, name: "Room")
        room.unreadMessages = spec.room.messages ?? 0
        room.unread = spec.room.notifications ?? 0
        room.isMarkedUnread = spec.room.markedUnread ?? false
        room.membership = spec.room.membership ?? "join"
        room.fullyReadEventID = spec.room.fullyRead
        #expect(anchor(room) == spec.anchor)
    }

    @Test("Re-selecting the room, a search target or a thread overrides the resume point")
    func overrides() {
        #expect(anchor(room, selected: roomID) == nil)
        #expect(anchor(room, explicit: "$target") == nil)
        #expect(anchor(room, thread: true) == nil)
    }

    @Test("An anchor too long to be an event ID is never replaced by a guess")
    func overlongAnchor() {
        let id = String(repeating: "$", count: 2_049)
        var broken = room
        broken.fullyReadEventID = id
        #expect(anchor(broken) == nil)
    }

    @Test("No room means no anchor")
    func noRoom() {
        #expect(anchor(nil) == nil)
    }
}

@MainActor
struct UnreadSDKActionsTests {
    private let timeline = ReceiptTimeline(noHandle: .init())

    // capability: conversation.read
    @Test("Reading a message sends the read receipt, then moves the fully-read marker to the same event")
    func acknowledgeOrder() async throws {
        try await UnreadSDKActions.acknowledge(timeline: timeline, eventID: "$visible") {}
        #expect(timeline.writes.all == ["read:$visible", "fully:$visible"])
    }

    @Test("A failed read receipt fails and never moves the fully-read marker")
    func failedRead() async {
        timeline.failure = .read
        await #expect(throws: MatrixServiceError.self) {
            try await UnreadSDKActions.acknowledge(timeline: timeline, eventID: "$visible") {}
        }
        #expect(timeline.writes.all == ["read:$visible"])
    }

    @Test("A failed fully-read update fails so it can be retried")
    func failedFullyRead() async {
        timeline.failure = .fullyRead
        await #expect(throws: MatrixServiceError.self) {
            try await UnreadSDKActions.acknowledge(timeline: timeline, eventID: "$visible") {}
        }
    }

    @Test("If the account or selection changes during the read receipt, the fully-read marker stays put")
    func staleAcknowledge() async {
        timeline.readGate.arm()
        var current = true
        let old = Task {
            try await UnreadSDKActions.acknowledge(timeline: timeline, eventID: "$old") {
                guard current else { throw CancellationError() }
            }
        }
        #expect(await eventually { timeline.readGate.isWaiting })
        current = false
        timeline.readGate.release()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(timeline.writes.all == ["read:$old"])
    }

    // capability: conversation.mark-read
    @Test("Mark read sends the room's latest read receipt and fully-read marker")
    func markRoomRead() async throws {
        let room = ReceiptRoom(noHandle: .init())
        try await UnreadSDKActions.markRoomRead(room: room) {}
        #expect(room.writes.all == ["read", "fully"])
    }

    @Test("Mark read stops before the fully-read marker if the account changed in between")
    func staleMarkRoomRead() async {
        let room = ReceiptRoom(noHandle: .init())
        room.readGate.arm()
        var current = true
        let marking = Task {
            try await UnreadSDKActions.markRoomRead(room: room) { guard current else { throw CancellationError() } }
        }
        #expect(await eventually { room.readGate.isWaiting })
        current = false
        room.readGate.release()
        await #expect(throws: CancellationError.self) { try await marking.value }
        #expect(room.writes.all == ["read"])
    }

    @Test("Loading newer history reports whether the end was reached and sends no receipts", arguments: [false, true])
    func loadForward(end: Bool) async throws {
        timeline.forwardEnd = end
        #expect(try await UnreadSDKActions.loadForward(timeline: timeline) {} == end)
        #expect(timeline.writes.all.isEmpty)
    }

    @Test("A newer-history page that finishes after the focus changed is rejected")
    func staleForwardPage() async {
        timeline.forwardGate.arm()
        var current = true
        let page = Task {
            try await UnreadSDKActions.loadForward(timeline: timeline) {
                guard current else { throw CancellationError() }
            }
        }
        #expect(await eventually { timeline.forwardGate.isWaiting })
        current = false
        timeline.forwardGate.release()
        await #expect(throws: CancellationError.self) { _ = try await page.value }
    }
}
