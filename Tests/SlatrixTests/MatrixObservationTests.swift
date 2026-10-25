import Observation
import Testing

@testable import Slatrix

/// What a view that shows the open conversation is told about: SwiftUI redraws a view when something it read
/// changes, so a change elsewhere must not reach it.
@MainActor
struct MatrixObservationTests {
    @Test(
        "A change to another room leaves the open conversation's readers alone, a change to the open one reaches them")
    func openConversationReaders() {
        let service = MatrixService()
        service.rooms = [
            ChatRoom(id: "!open:example.org", name: "Open"), ChatRoom(id: "!other:example.org", name: "Other"),
        ]
        service.selectedRoomID = "!open:example.org"
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = service.messageActionContext
        } onChange: {
            changes.append(())
        }
        service.rooms[1].unread = 3
        service.typingUsers = ["Alex"]
        #expect(changes.all.isEmpty)
        service.rooms[0].membership = "leave"
        #expect(!changes.all.isEmpty)
    }
}
