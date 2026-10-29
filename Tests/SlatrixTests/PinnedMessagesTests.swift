import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private func item(_ id: String, body: String = "Current", edited: Bool = false, redacted: Bool = false) -> TimelineItem
{
    FakeTimelineItem(textEvent(id, body: body, edited: edited, redacted: redacted))
}

private final class Powers: RoomPowerLevels, @unchecked Sendable {
    var allowed = true
    override func canOwnUserPinUnpin() -> Bool { allowed }
}

private final class PinsTimeline: Timeline, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [TimelineListener] = []
    private var handles: [FakeCancellableHandle] = []
    private let values: [TimelineItem]
    let writes = Recorder<(id: String, pin: Bool)>()
    let historyReads = Recorder<Void>()
    let writeGate = Gate()
    var allCancelled: Bool { lock.withLock { handles.allSatisfy(\.isCancelled) } }
    init(_ values: [TimelineItem]) {
        self.values = values
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func addListener(listener: TimelineListener) async -> TaskHandle {
        let handle = FakeCancellableHandle(noHandle: .init())
        lock.withLock {
            listeners.append(listener)
            handles.append(handle)
        }
        listener.onUpdate(diff: [.reset(values: values)])
        return handle
    }
    override func pinEvent(eventId: String) async throws -> Bool {
        writes.append((eventId, true))
        await writeGate.wait()
        return true
    }
    override func unpinEvent(eventId: String) async throws -> Bool {
        writes.append((eventId, false))
        return true
    }
    override func markAsRead(receiptType: ReceiptType) async throws { historyReads.append(()) }
    override func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        historyReads.append(())
        throw MatrixServiceError.request("pinned pagination unsupported")
    }
    func emit(_ diff: [TimelineDiff]) {
        for listener in lock.withLock({ listeners }) { listener.onUpdate(diff: diff) }
    }
}

private final class PinsRoom: Room, @unchecked Sendable {
    let identifier: String
    let pins: PinsTimeline
    let powers = Powers(noHandle: .init())
    /// Holds only the next call of each kind, so a panel opening meanwhile is not held too.
    let gate = Gate()
    let configurations = Recorder<TimelineConfiguration>()
    var ids: [String]
    var fail = false
    private let lock = NSLock()
    private var listeners: [RoomInfoListener] = []
    private var pausing: Set<String> = []
    init(_ id: String, values: [TimelineItem], ids: [String]) {
        identifier = id
        pins = PinsTimeline(values)
        self.ids = ids
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    func pauseNext(_ call: String) {
        lock.withLock { _ = pausing.insert(call) }
        gate.arm()
    }
    private func pause(_ call: String) async {
        if lock.withLock({ pausing.remove(call) != nil }) { await gate.wait() }
    }
    override func id() -> String { identifier }
    override func membership() -> Membership { .joined }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        await pause("powers")
        return powers
    }
    override func roomInfo() async throws -> RoomInfo {
        let snapshot = info
        await pause("info")
        return snapshot
    }
    override func subscribeToRoomInfoUpdates(listener: RoomInfoListener) -> TaskHandle {
        lock.withLock { listeners.append(listener) }
        return FakeCancellableHandle(noHandle: .init())
    }
    override func timelineWithConfiguration(configuration: TimelineConfiguration) async throws -> Timeline {
        configurations.append(configuration)
        await pause("timeline")
        if fail { throw MatrixServiceError.request("pin list unavailable") }
        return pins
    }
    func emitInfo() {
        for listener in lock.withLock({ listeners }) { listener.call(roomInfo: info) }
    }
    private var info: RoomInfo {
        var info = SlatrixTests.roomInfo(id: identifier)
        info.pinnedEventIds = ids
        info.powerLevels = powers
        return info
    }
}

private final class PinsClient: Client, @unchecked Sendable {
    let rooms: [String: PinsRoom]
    init(_ rooms: PinsRoom...) {
        self.rooms = Dictionary(uniqueKeysWithValues: rooms.map { ($0.identifier, $0) })
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func getRoom(roomId: String) throws -> Room? { rooms[roomId] }
    override func userId() throws -> String { "@me:example.org" }
}

private let roomID = "!pins:example.org"
private let otherID = "!other:example.org"

@MainActor
struct PinnedMessagesTests {
    private let room = PinsRoom(
        roomID,
        values: [
            item("$later", body: "Edited", edited: true), FakeTimelineItem(nil), item("$earlier", redacted: true),
            item("$relation"), item("$later"),
        ], ids: ["$earlier", "$later"])
    private let other = PinsRoom(otherID, values: [item("$other")], ids: ["$other"])
    private let service = PinnedMessagesService()

    init() { service.attach(PinsClient(room, other)) }

    private func open(_ id: String = roomID) async {
        await service.open(roomID: id)
        #expect(await eventually { service.state == "ready" })
    }

    struct OrderCase: Decodable, CustomTestStringConvertible {
        var name: String
        var pinned: [String]
        var events: [String]
        var shown: [String]
        var testDescription: String { name }
    }
    struct LimitCase: Decodable, CustomTestStringConvertible {
        var name: String
        var total: Int
        var note: String?
        var testDescription: String { name }
    }
    struct PinsSpec: Decodable {
        var order: [OrderCase]
        var limit: [LimitCase]
    }

    // capability: conversation.pins
    @Test(
        "Pins show in the shared cases' order",
        arguments: try SharedSpec.decode("spec/pinned-messages.json", as: PinsSpec.self).order)
    func sharedOrder(spec: OrderCase) {
        #expect(PinnedMessagesMapping.arrange(spec.events, pinned: spec.pinned) { $0 } == spec.shown)
    }

    @Test(
        "A room past the SDK's limit says how many pins show, as the shared cases say",
        arguments: try SharedSpec.decode("spec/pinned-messages.json", as: PinsSpec.self).limit)
    func sharedLimit(spec: LimitCase) {
        #expect(PinnedMessagesMapping.limitNote(total: spec.total) == spec.note)
    }

    // capability: conversation.pins
    @Test("Pins show the latest pin first with edits and deletions applied, skipping other events and duplicates")
    func opensPins() async throws {
        await open()
        #expect(service.messages.map(\.id) == ["$later", "$earlier"])
        #expect(service.messages[0].isEdited && service.messages[0].body == "Edited" && service.messages[1].isRedacted)
        let configuration = try #require(room.configurations.all.first)
        #expect(configuration.focus == .pinnedEvents && configuration.trackReadReceipts == .disabled)
        #expect(!configuration.reportUtds)
        #expect(room.pins.writes.all.isEmpty && room.pins.historyReads.all.isEmpty && service.canPinUnpin)
    }

    @Test("A pinned message deleted live shows as deleted")
    func liveRedaction() async {
        await open()
        room.pins.emit([.set(index: 0, value: item("$later", redacted: true))])
        #expect(await eventually { service.messages.first?.isRedacted == true })
        #expect(service.messages[0].body == "This message was deleted")
    }

    @Test("An unpin from the room state removes the message at once")
    func unpinFromState() async {
        await open()
        room.ids = ["$earlier"]
        room.emitInfo()
        #expect(await eventually { service.messages.map(\.id) == ["$earlier"] })
        #expect(service.totalPinned == 1)
    }

    @Test("Losing the pin permission hides the action and blocks the write")
    func permissionRevoked() async {
        await open()
        room.powers.allowed = false
        room.emitInfo()
        #expect(await eventually { !service.canPinUnpin })
        await #expect(throws: MatrixServiceError.self) { _ = try await service.pin(eventID: "$new", roomID: roomID) }
        #expect(room.pins.writes.all.isEmpty)
    }

    // capability: message.pin
    @Test("Pin and unpin use the SDK's pin methods once the current power levels allow it")
    func pinAndUnpin() async throws {
        await open()
        #expect(try await service.permissionToPin(roomID: roomID))
        _ = try await service.pin(eventID: "$new", roomID: roomID)
        _ = try await service.unpin(eventID: "$earlier", roomID: roomID)
        #expect(room.pins.writes.all.map(\.id) == ["$new", "$earlier"])
        #expect(room.pins.writes.all.map(\.pin) == [true, false])
    }

    @Test("A message that hasn't been sent cannot be pinned")
    func localEcho() async {
        await open()
        await #expect(throws: MatrixServiceError.self) {
            _ = try await service.pin(eventID: "local-transaction", roomID: roomID)
        }
    }

    @Test("A second pin change while one is in flight is refused before it writes")
    func overlappingWrites() async throws {
        await open()
        room.pins.writeGate.arm()
        let first = Task { try await service.pin(eventID: "$first", roomID: roomID) }
        #expect(await eventually { room.pins.writeGate.isWaiting })
        await #expect(throws: MatrixServiceError.self) {
            _ = try await service.pin(eventID: "$duplicate", roomID: roomID)
        }
        room.pins.writeGate.release()
        _ = try await first.value
        #expect(room.pins.writes.all.map(\.id) == ["$first"] && !service.isUpdating)
    }

    @Test("A slow room-state read after a pin cannot overwrite newer pins from the stream")
    func staleMetadataAfterPin() async throws {
        await open()
        room.pauseNext("info")
        let pinning = Task { try await service.pin(eventID: "$newest", roomID: roomID) }
        #expect(await eventually { room.gate.isWaiting })
        room.ids = ["$later"]
        room.emitInfo()
        #expect(await eventually { service.pinnedEventIDs == ["$later"] })
        room.gate.release()
        _ = try await pinning.value
        #expect(service.pinnedEventIDs == ["$later"] && service.messages.map(\.id) == ["$later"])
    }

    @Test("Many pins show a page at a time from what the SDK already loaded, never paginating history")
    func localPaging() async {
        let ids = (0..<65).map { "$page-\($0)" }
        let paged = PinsRoom("!page:example.org", values: ids.map { item($0) }, ids: ids)
        service.attach(PinsClient(paged))
        await open(paged.identifier)
        #expect(service.messages.count < 65 && service.totalLoaded == 65 && service.hasMore)
        while service.hasMore { service.loadMore() }
        #expect(service.messages.count == 65 && paged.pins.historyReads.all.isEmpty)
    }

    @Test("More pins than the SDK loads are reported instead of claiming the list is complete")
    func coverageBeyondSDKLimit() async {
        await open()
        room.ids = (0..<140).map { "$all-\($0)" }
        room.emitInfo()
        #expect(await eventually { service.totalPinned == 140 })
        #expect(service.coverageMessage != nil)
    }

    @Test("Closing stops listening and ignores late room and timeline updates")
    func closeIgnoresLateUpdates() async {
        await open()
        service.close()
        room.pins.emit([.reset(values: [item("$stale")])])
        room.emitInfo()
        await drainMainActor()
        #expect(service.messages.isEmpty && service.state == "idle" && room.pins.allCancelled)
    }

    @Test("A slow first room cannot replace the room opened after it")
    func lateFirstRoom() async {
        room.pauseNext("timeline")
        let first = Task { await service.open(roomID: roomID) }
        #expect(await eventually { room.gate.isWaiting })
        await open(otherID)
        room.gate.release()
        await first.value
        await drainMainActor()
        #expect(service.roomID == otherID && service.messages.map(\.id) == ["$other"])
    }

    @Test("A failed open shows an error, and Retry opens the pins")
    func failureAndRetry() async {
        room.fail = true
        await service.open(roomID: roomID)
        #expect(service.state == "error" && service.errorMessage != nil)
        room.fail = false
        await service.retry()
        #expect(await eventually { service.state == "ready" })
    }

    @Test("Signing out clears the pins and refuses pin changes")
    func signOut() async {
        await open()
        service.attach(nil)
        await #expect(throws: MatrixServiceError.self) { _ = try await service.pin(eventID: "$new", roomID: roomID) }
        #expect(service.messages.isEmpty && !service.canPinUnpin && service.roomID == nil)
    }

    @Test(
        "A pin started from the timeline writes once to its own room even if the panel opens meanwhile",
        arguments: ["powers", "timeline"], [true, false])
    func panelOpensDuringPin(pausedCall: String, sameRoom: Bool) async throws {
        room.pauseNext(pausedCall)
        let pinning = Task { try await service.pin(eventID: "$explicit", roomID: roomID) }
        #expect(await eventually { room.gate.isWaiting })
        await open(sameRoom ? roomID : otherID)
        let panelRoom = service.roomID
        let panelIDs = service.pinnedEventIDs
        room.gate.release()
        _ = try await pinning.value
        #expect(room.pins.writes.all.map(\.id) == ["$explicit"] && other.pins.writes.all.isEmpty)
        #expect(service.roomID == panelRoom && service.pinnedEventIDs == panelIDs && !service.isUpdating)
    }

    @Test("Switching accounts cancels a pending pin before it writes", arguments: ["powers", "timeline"])
    func accountSwitchCancelsPin(pausedCall: String) async {
        room.pauseNext(pausedCall)
        let pinning = Task { try await service.pin(eventID: "$blocked", roomID: roomID) }
        #expect(await eventually { room.gate.isWaiting })
        service.attach(PinsClient())
        room.gate.release()
        await #expect(throws: CancellationError.self) { _ = try await pinning.value }
        #expect(room.pins.writes.all.isEmpty && service.roomID == nil && !service.isUpdating)
    }
}
