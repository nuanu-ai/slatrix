import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// The SDK's thread timeline holds its root as first sent: an edit to the root arrives in the main timeline.
@MainActor
struct ThreadRootEditTests {
    let room = FakeOpenRoom(
        "!team:example.org",
        cached: [FakeTimelineItem(textEvent("$root", body: "After the edit", edited: true), uniqueID: "root")])
    let service = MatrixService()

    init() {
        room.threadItems = [
            FakeTimelineItem(textEvent("$root", body: "Before the edit"), uniqueID: "root"),
            FakeTimelineItem(textEvent("$reply", body: "A reply"), uniqueID: "reply"),
        ]
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
    }

    @Test("A thread opened on an edited message shows the edited text, as the channel does")
    func opensEdited() async throws {
        await service.selectRoom(room.id())
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.count == 2 })
        let root = try #require(service.threadMessages.first)
        #expect(root.body == "After the edit" && root.isEdited)
    }

    @Test("Editing a message while its thread is open changes it in the thread too")
    func followsEdit() async throws {
        await service.selectRoom(room.id())
        let main = try #require(room.timelines.all.first)
        main.emit([.reset(values: [FakeTimelineItem(textEvent("$root", body: "Before the edit"), uniqueID: "root")])])
        #expect(await eventually { service.messages.first?.body == "Before the edit" })
        try await service.loadThread(try #require(service.messages.first))
        #expect(await eventually { service.threadMessages.count == 2 })
        let edited = FakeTimelineItem(textEvent("$root", body: "After the edit", edited: true), uniqueID: "root")
        main.emit([.reset(values: [edited])])
        #expect(await eventually { service.threadMessages.first?.body == "After the edit" })
    }
}
