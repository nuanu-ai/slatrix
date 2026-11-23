import Foundation
import MatrixRustSDK
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
        let service = MatrixService.scratch()
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
        let service = MatrixService.scratch()
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
        let service = MatrixService.scratch()
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

    @Test("An incoming DM preview in rooms leaves selectedRoom alone so RootView does not redraw")
    func openRoomLatestLeavesSelectedRoomAlone() {
        let service = MatrixService.scratch()
        service.rooms = [ChatRoom(id: "!dm:example.org", name: "Alex", isDirect: true)]
        service.selectedRoomID = "!dm:example.org"
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = service.selectedRoom
        } onChange: {
            changes.append(())
        }
        service.rooms[0].latest = LatestMessage(body: "Ping", timestamp: .now, isOwn: false)
        #expect(changes.all.isEmpty)
        service.rooms[0].topic = "Updated"
        #expect(service.selectedRoom?.topic == "Updated")
    }

    @Test("Updating only replyCount or lastReply on a thread root in messages does not invalidate threadMessages")
    func replySummaryUpdateLeavesThreadRootAlone() {
        let service = MatrixService.scratch()
        var root = ChatMessage(
            id: "$root", roomID: "!open:example.org", senderID: "@ana:example.org", senderName: "Ana", body: "Start",
            timestamp: .now)
        service.messages = [root]
        service.threadOpening = ("$root", nil)
        service.threadMessages = [root]
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = service.threadMessages
        } onChange: {
            changes.append(())
        }
        root.replyCount = 3
        root.lastReply = ThreadReply(senderID: "@bob:example.org", senderName: "Bob", avatarURL: nil, timestamp: .now)
        service.messages = [root]
        #expect(changes.all.isEmpty)

        // A real edit to the root body still propagates to the thread pane.
        root.body = "Edited start"
        service.messages = [root]
        #expect(!changes.all.isEmpty && service.threadMessages.first?.body == "Edited start")
    }

    @Test("hasLockedMessages checks thread messages too and ignores permanent non-unlockable UTDs")
    func lockedMessagesIncludeThreadsAndRespectUnlockability() {
        let service = MatrixService.scratch()
        var permanent = ChatMessage(
            id: "$prejoin", roomID: "!open:example.org", senderID: "@ana:example.org", senderName: "Ana",
            body: "Sent before you joined", timestamp: .now)
        permanent.kind = "m.room.encrypted"
        permanent.isUnlockable = false
        service.messages = [permanent]
        #expect(!service.hasLockedMessages)

        var threadLocked = ChatMessage(
            id: "$reply", roomID: "!open:example.org", senderID: "@ana:example.org", senderName: "Ana",
            body: "Verify this device to read", timestamp: .now)
        threadLocked.kind = "m.room.encrypted"
        threadLocked.isUnlockable = true
        service.threadMessages = [threadLocked]
        #expect(service.hasLockedMessages)

        service.threadMessages = []
        #expect(!service.hasLockedMessages)
    }

    @Test("Upload progress ticks update UploadProgressStore without invalidating timeline messages")
    func uploadProgressDoesNotInvalidateMessages() {
        let service = MatrixService.scratch()
        var pending = ChatMessage(
            id: "tx-1", roomID: "!open:example.org", senderID: "@me:example.org", senderName: "Me",
            body: "photo.png", timestamp: .now)
        pending.sendState = "sending"
        service.messages = [pending]

        let messageChanges = Recorder<Void>()
        let failureChanges = Recorder<Void>()
        withObservationTracking {
            _ = service.messages
        } onChange: {
            messageChanges.append(())
        }
        withObservationTracking {
            _ = service.hasExternalSendFailure(in: "!open:example.org", visibleIDs: ["tx-1"])
        } onChange: {
            failureChanges.append(())
        }
        service.handleSendQueueUpdate(
            roomID: "!open:example.org",
            update: .mediaUpload(
                relatedTo: "tx-1", file: nil, index: 0, progress: AbstractProgress(current: 40, total: 100)))
        service.handleSendQueueUpdate(
            roomID: "!other:example.org",
            update: .mediaUpload(
                relatedTo: "tx-other", file: nil, index: 0, progress: AbstractProgress(current: 60, total: 100)))
        #expect(messageChanges.all.isEmpty)
        #expect(failureChanges.all.isEmpty)
        #expect(service.uploadProgress.progress(roomID: "!open:example.org", messageID: "tx-1") == 0.4)

        service.handleSendQueueUpdate(
            roomID: "!open:example.org", update: .sentEvent(transactionId: "tx-1", eventId: "$sent"))
        #expect(service.uploadProgress.progress(roomID: "!open:example.org", messageID: "tx-1") == nil)
    }

    @Test("Unchanged member reloads and identical timeline projections do not emit observation notifications")
    func unchangedWritesDoNotNotify() async throws {
        let room = FakeOpenRoom(
            "!quiet:example.org", cached: [FakeTimelineItem(textEvent("$m1", body: "Hello"), uniqueID: "m1")])
        room.memberList = [roomMember("@alice:example.org", name: "Alice")]
        let service = MatrixService.scratch()
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
        await service.selectRoom(room.id())
        await service.loadMembers()
        let timeline = try #require(room.timelines.all.first)
        let firstMessage = try #require(service.messages.first)

        let memberChanges = Recorder<Void>()
        withObservationTracking {
            _ = service.members
        } onChange: {
            memberChanges.append(())
        }
        await service.loadMembers()
        #expect(memberChanges.all.isEmpty)

        let messageChanges = Recorder<Void>()
        let mediaChanges = Recorder<Void>()
        let unreadChanges = Recorder<Void>()
        let failureChanges = Recorder<Void>()
        withObservationTracking {
            _ = service.messages
        } onChange: {
            messageChanges.append(())
        }
        withObservationTracking {
            _ = service.attachmentSourceRevision(firstMessage)
        } onChange: {
            mediaChanges.append(())
        }
        withObservationTracking {
            _ = service.firstUnreadEventID
        } onChange: {
            unreadChanges.append(())
        }
        withObservationTracking {
            _ = service.sendFailures
        } onChange: {
            failureChanges.append(())
        }

        // A timeline update that projects the exact same visible message, media, unread marker and failures.
        timeline.emit([.set(index: 0, value: FakeTimelineItem(textEvent("$m1", body: "Hello"), uniqueID: "m1"))])
        await drainMainActor()
        #expect(messageChanges.all.isEmpty)
        #expect(mediaChanges.all.isEmpty)
        #expect(unreadChanges.all.isEmpty)
        #expect(failureChanges.all.isEmpty)
    }

    @Test(
        "Evaluating a resting TimelineRow body does not subscribe to messages, threadMessages or messageActionContext")
    func timelineRowDoesNotObserveMessagesOrActionContext() throws {
        let room = ChatRoom(id: "!open:example.org", name: "Open")
        let client = FakeClient(rooms: [FakeRoom(roomInfo(id: room.id))])
        let service = MatrixService.scratch()
        service.user = ChatUser(id: "@me:example.org", name: "Me")
        service.rooms = [room]
        service.selectedRoomID = room.id
        let message = ChatMessage(
            id: "$m1", roomID: room.id, senderID: "@ana:example.org", senderName: "Ana", body: "Hello",
            timestamp: .now)
        service.configureMessageActionsForChecks(
            client: client, main: FakeLiveTimeline([]), thread: nil, rootID: nil, sessionID: UUID(),
            selectionID: UUID(), threadID: UUID())
        service.messages = [message]
        let context = TimelineRowContext()
        context.matrix = service
        context.appearance = AppearanceStore()
        context.canAct = true
        var reacted: (eventID: String, emoji: String)?
        var forwarded: String?
        context.onReact = { reacted = ($0.message.eventID, $1) }
        context.onForward = { forwarded = $0.message.eventID }
        let messageEntry = TimelineMessageEntry(
            message: message, grouped: false, time: "10:00 AM", saved: false, pinned: false,
            highlighted: false, sendBusy: false)
        let entry = TimelineEntry(id: message.id, kind: .message(messageEntry))
        let row = TimelineRow(entry: entry, hovered: false, context: context)
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = row.body
        } onChange: {
            changes.append(())
        }
        service.messages.append(
            ChatMessage(
                id: "$m2", roomID: room.id, senderID: "@bob:example.org", senderName: "Bob", body: "Later",
                timestamp: .now))
        service.threadMessages.append(message)
        service.setMessageActionThread(rootID: "$m1")
        service.setMessageActionThread(rootID: nil)
        #expect(changes.all.isEmpty)

        // Triggering lazy row actions still captures the live action target when invoked.
        let actions = context.rowActions(for: messageEntry)
        let react = try #require(actions.react)
        let forward = try #require(actions.forward)
        react("👍")
        forward()
        #expect(reacted?.eventID == "$m1" && reacted?.emoji == "👍")
        #expect(forwarded == "$m1")
        context.canAct = false
        let disabled = context.rowActions(for: messageEntry)
        #expect(disabled.react == nil && disabled.openReactions == nil && disabled.forward == nil)
    }

    @Test("A thread TimelineView's reachedStart does not observe the main conversation's hasMoreHistory")
    func threadTimelineIgnoresMainHasMoreHistory() async throws {
        let room = FakeOpenRoom(
            "!open:example.org", cached: [FakeTimelineItem(textEvent("$m1", body: "Hello"), uniqueID: "m1")])
        room.pageGate.arm()
        defer { room.pageGate.release() }
        let service = MatrixService.scratch()
        service.configureRoomOpenForChecks(
            client: FakeClient(rooms: [room]), roomList: FakeRoomListService(),
            user: ChatUser(id: "@me:example.org", name: "Me"))
        await service.selectRoom(room.id())
        let timeline = try #require(room.timelines.all.first)
        timeline.startReached = true
        let chatRoom = ChatRoom(id: room.id(), name: "Open")
        let view = TimelineView(
            matrix: service, room: chatRoom, thread: true, threadRootID: "$m1", savedIDs: [],
            onThread: { _ in }, onReply: { _ in }, onEdit: { _ in }, onSave: { _ in }, onShowReply: { _ in })
        let changes = Recorder<Void>()
        withObservationTracking {
            _ = view.reachedStart
        } onChange: {
            changes.append(())
        }
        #expect(!view.reachedStart)
        room.pageGate.release()
        #expect(await eventually { !service.hasMoreHistory })
        #expect(changes.all.isEmpty)
    }

    @Test("Flipping canPin updates a mounted hover toolbar without invalidating resting TimelineRow bodies")
    func hoverToolbarObservesPinPermissionWithoutInvalidatingRows() {
        let room = ChatRoom(id: "!open:example.org", name: "Open")
        let service = MatrixService.scratch()
        service.user = ChatUser(id: "@me:example.org", name: "Me")
        service.rooms = [room]
        service.selectedRoomID = room.id
        let message = ChatMessage(
            id: "$m1", roomID: room.id, senderID: "@ana:example.org", senderName: "Ana", body: "Hello",
            timestamp: .now)
        let context = TimelineRowContext()
        context.matrix = service
        context.appearance = AppearanceStore()
        context.onTogglePin = { _ in }
        context.canPin = false
        let messageEntry = TimelineMessageEntry(
            message: message, grouped: false, time: "10:00 AM", saved: false, pinned: false,
            highlighted: false, sendBusy: false)
        let row = TimelineRow(
            entry: TimelineEntry(id: message.id, kind: .message(messageEntry)), hovered: false, context: context)
        let toolbar = HoveredMessageToolbar(entry: messageEntry, context: context)

        let rowChanges = Recorder<Void>()
        let toolbarChanges = Recorder<Void>()
        withObservationTracking {
            _ = row.body
        } onChange: {
            rowChanges.append(())
        }
        withObservationTracking {
            _ = toolbar.body
        } onChange: {
            toolbarChanges.append(())
        }
        let beforePin = context.actions(for: messageEntry, target: nil).menu().first { $0.id == "pin" }
        #expect(beforePin?.isEnabled == false)

        context.canPin = true
        #expect(rowChanges.all.isEmpty)
        #expect(!toolbarChanges.all.isEmpty)
        let afterPin = context.actions(for: messageEntry, target: nil).menu().first { $0.id == "pin" }
        #expect(afterPin?.isEnabled == true)
    }
}
