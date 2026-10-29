import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class FieldPowers: RoomPowerLevels, @unchecked Sendable {
    let name: Bool
    let topic: Bool
    init(name: Bool, topic: Bool) {
        self.name = name
        self.topic = topic
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    override func canOwnUserSendState(stateEvent: StateEventType) -> Bool {
        switch stateEvent {
        case .roomName: name
        case .roomTopic: topic
        default: false
        }
    }
}

/// A room named "Original" with topic "Old topic". `lagsEcho` keeps RoomInfo on the old values after a save,
/// as sync does until the echo arrives.
private final class DetailsRoom: Room, @unchecked Sendable {
    var joined = true
    var space = false
    var name = "Original"
    var topic = "Old topic"
    var allowsName = true
    var allowsTopic = true
    var failsName = false
    var failsTopic = false
    var failsPowers = false
    var failsInfo = false
    var lagsEcho = false
    var revokesTopicAfterName = false
    var breaksInfoAfterTopic = false
    let nameGate = Gate()
    let powersGate = Gate()
    let writes = Recorder<String>()
    init() { super.init(noHandle: .init()) }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }

    override func id() -> String { "!details:example.org" }
    override func isSpace() -> Bool { space }
    override func membership() -> Membership { joined ? .joined : .left }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        await powersGate.wait()
        if failsPowers { throw MatrixServiceError.request("Fixture powers unavailable") }
        return FieldPowers(name: allowsName, topic: allowsTopic)
    }
    override func setName(name: String) async throws {
        writes.append("name:\(name)")
        await nameGate.wait()
        if failsName { throw MatrixServiceError.request("Fixture name failed") }
        self.name = name
        if revokesTopicAfterName { allowsTopic = false }
    }
    override func setTopic(topic: String) async throws {
        writes.append("topic:\(topic)")
        if failsTopic { throw MatrixServiceError.request("Fixture topic failed") }
        self.topic = topic
        if breaksInfoAfterTopic { failsInfo = true }
    }
    override func roomInfo() async throws -> RoomInfo {
        if failsInfo { throw MatrixServiceError.request("Fixture room info unavailable") }
        var info = SlatrixTests.roomInfo(id: id(), name: name, membership: membership(), isSpace: space)
        info.rawName = lagsEcho ? "Original" : name
        info.topic = lagsEcho ? "Old topic" : topic
        return info
    }
}

@MainActor
struct RoomDetailsTests {
    // capability: channel.details
    @Test("Loading details reads the name and topic and asks the SDK which of them the user may edit")
    func loadsDetailsAndPermissions() async throws {
        let room = DetailsRoom()
        room.space = true
        room.allowsTopic = false
        let details = try await RoomDetailsService.load(room: room, validate: {})
        #expect(details.roomID == room.id() && details.isSpace)
        #expect(details.name == "Original" && details.topic == "Old topic")
        #expect(details.canEditName && !details.canEditTopic)
    }

    @Test("A room the user has left cannot be loaded for editing")
    func leftRoomCannotBeLoaded() async throws {
        let room = DetailsRoom()
        room.joined = false
        await #expect(throws: MatrixServiceError.self) { try await RoomDetailsService.load(room: room, validate: {}) }
    }

    @Test("A save that includes a field the user cannot edit changes neither field")
    func deniedFieldBlocksWholeSave() async throws {
        let room = DetailsRoom()
        room.allowsTopic = false
        await #expect(throws: MatrixServiceError.self) {
            try await RoomDetailsService.save(room: room, name: "Changed", topic: "Changed", validate: {})
        }
        #expect(room.writes.all.isEmpty)
    }

    @Test("Unchanged or omitted fields are not sent")
    func unchangedFieldsAreNotSent() async throws {
        let room = DetailsRoom()
        let result = try await RoomDetailsService.save(room: room, name: "Original", topic: nil, validate: {})
        #expect(result.savedFields.isEmpty && room.writes.all.isEmpty)
    }

    @Test("A blank name is refused before anything is sent")
    func blankNameIsRefused() async throws {
        let room = DetailsRoom()
        await #expect(throws: MatrixServiceError.self) {
            try await RoomDetailsService.save(room: room, name: "  ", topic: nil, validate: {})
        }
        #expect(room.writes.all.isEmpty)
    }

    @Test("When the topic fails after the name saved, the error reports the saved name and only the topic is retried")
    func partialSaveReportsSavedField() async throws {
        let room = DetailsRoom()
        room.failsTopic = true
        room.lagsEcho = true
        do {
            _ = try await RoomDetailsService.save(room: room, name: "Accepted", topic: "Pending", validate: {})
            Issue.record("a failed topic must be reported")
        } catch let partial as RoomDetailsPartialFailure {
            #expect(partial.result.savedFields == [.name] && partial.failedField == .topic)
            #expect(partial.result.snapshot.name == "Accepted" && partial.result.snapshot.topic == "Old topic")
            #expect(MatrixService.safeError(partial) == partial.warning)
        }
        room.failsTopic = false
        let retried = try await RoomDetailsService.save(room: room, name: nil, topic: "Pending", validate: {})
        #expect(retried.savedFields == [.topic] && retried.snapshot.topic == "Pending")
        #expect(room.writes.all == ["name:Accepted", "topic:Pending", "topic:Pending"])
    }

    @Test("When the name fails, the topic is not sent and nothing is reported as saved")
    func failedNameStopsSave() async throws {
        let room = DetailsRoom()
        room.failsName = true
        await #expect(throws: MatrixServiceError.self) {
            try await RoomDetailsService.save(room: room, name: "Changed", topic: "Changed", validate: {})
        }
        #expect(room.writes.all == ["name:Changed"])
    }

    @Test("Permission revoked between the two changes stops the topic and reports the name as saved")
    func revokedPermissionStopsTopic() async throws {
        let room = DetailsRoom()
        room.revokesTopicAfterName = true
        do {
            _ = try await RoomDetailsService.save(room: room, name: "Accepted", topic: "Forbidden", validate: {})
            Issue.record("a revoked permission must be reported")
        } catch let partial as RoomDetailsPartialFailure {
            #expect(partial.result.savedFields == [.name] && !partial.result.snapshot.canEditTopic)
        }
        #expect(room.writes.all == ["name:Accepted"])
    }

    @Test("Both changes count as saved even if room info is unavailable after the last one, and a topic can be cleared")
    func savedChangesStaySaved() async throws {
        let room = DetailsRoom()
        room.lagsEcho = true
        room.breaksInfoAfterTopic = true
        let result = try await RoomDetailsService.save(room: room, name: "Both", topic: "", validate: {})
        #expect(result.savedFields == [.name, .topic])
        #expect(result.snapshot.name == "Both" && result.snapshot.topic == "")
        #expect(room.writes.all == ["name:Both", "topic:"])
    }

    @Test("A permission error that arrives after switching account is quiet")
    func stalePermissionErrorIsQuiet() async throws {
        let room = DetailsRoom()
        room.powersGate.arm()
        var current = true
        let loading = Task {
            try await RoomDetailsService.load(room: room) { guard current else { throw CancellationError() } }
        }
        #expect(await eventually { room.powersGate.isWaiting })
        current = false
        room.failsPowers = true
        room.powersGate.release()
        await #expect(throws: CancellationError.self) { try await loading.value }
    }

    @Test("Switching account while the name saves stops the topic and reports no partial result")
    func accountChangeStopsSecondField() async throws {
        let room = DetailsRoom()
        room.nameGate.arm()
        var current = true
        let saving = Task {
            try await RoomDetailsService.save(room: room, name: "First", topic: "Never sent") {
                guard current else { throw CancellationError() }
            }
        }
        #expect(await eventually { room.nameGate.isWaiting })
        current = false
        room.nameGate.release()
        await #expect(throws: CancellationError.self) { try await saving.value }
        #expect(room.writes.all == ["name:First"])
    }

    @Test("Leaving the room while the name saves stops the topic")
    func leavingStopsSecondField() async throws {
        let room = DetailsRoom()
        room.nameGate.arm()
        let saving = Task {
            try await RoomDetailsService.save(room: room, name: "First", topic: "Never sent", validate: {})
        }
        #expect(await eventually { room.nameGate.isWaiting })
        room.joined = false
        room.nameGate.release()
        await #expect(throws: MatrixServiceError.self) { try await saving.value }
        #expect(room.writes.all == ["name:First"])
    }
}
