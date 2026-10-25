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

    @Test("The open room's unread count, which changes with every message in it, leaves the window alone")
    func openRoomUnread() {
        let service = MatrixService()
        service.rooms = [ChatRoom(id: "!open:example.org", name: "Open")]
        service.selectedRoomID = "!open:example.org"
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = service.selectedRoom
        } onChange: {
            changes.append(())
        }
        service.rooms[0].unread = 2
        service.rooms[0].unreadMessages = 2
        service.rooms[0].mentions = 1
        #expect(changes.all.isEmpty)
        service.rooms[0].name = "Renamed"
        #expect(service.selectedRoom?.name == "Renamed")
    }

    @Test("A message arriving leaves the conversation header alone until one can't be read")
    func lockedMessages() {
        let service = MatrixService()
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = service.hasLockedMessages
        } onChange: {
            changes.append(())
        }
        let message = ChatMessage(
            id: "$1", roomID: "!open:example.org", senderID: "@ana:example.org", senderName: "Ana", body: "Hi",
            timestamp: .now)
        service.messages.append(message)
        #expect(changes.all.isEmpty)
        var locked = message
        locked.id = "$2"
        locked.kind = "m.room.encrypted"
        service.messages.append(locked)
        #expect(service.hasLockedMessages)
    }
}
