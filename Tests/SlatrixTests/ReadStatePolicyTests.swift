import Foundation
import Testing

@testable import Slatrix

struct ReadStatePolicyTests {
    typealias Change = @Sendable (inout ReadStateContext) -> Void
    private static let visible = ReadStateContext(
        accountID: "@reader:example.org", sessionGeneration: UUID(), timelineGeneration: UUID(),
        roomID: "!room:example.org", selectedRoomID: "!room:example.org", latestVisibleEventID: "$rendered",
        isJoined: true, isMainTimeline: true, isLiveTimeline: true, isAtBottom: true, isWindowActive: true,
        isWindowVisible: true, isWindowUnoccluded: true)
    static let ineligible: [(String, Change)] = [
        ("preview", { $0.isPreview = true }), ("not joined", { $0.isJoined = false }),
        ("thread timeline", { $0.isMainTimeline = false }),
        ("historical or pinned focus", { $0.isLiveTimeline = false }),
        ("reading older messages", { $0.isAtBottom = false }), ("inactive app", { $0.isWindowActive = false }),
        ("closed or minimized window", { $0.isWindowVisible = false }),
        ("occluded window", { $0.isWindowUnoccluded = false }), ("modal sheet", { $0.hasModal = true }),
        ("different selected room", { $0.selectedRoomID = "!other:example.org" }),
        ("no selected room", { $0.selectedRoomID = nil }), ("signed out", { $0.accountID = nil }),
        ("invalid account", { $0.accountID = "reader:example.org" }),
        ("account without server", { $0.accountID = "@reader" }),
        ("missing session", { $0.sessionGeneration = nil }),
        ("missing timeline", { $0.timelineGeneration = nil }),
        ("no remote event", { $0.latestVisibleEventID = nil }),
        ("local transaction", { $0.latestVisibleEventID = "transaction-123" }),
        ("control character in event", { $0.latestVisibleEventID = "$event\n" }),
        ("oversized event", { $0.latestVisibleEventID = "$" + String(repeating: "é", count: 1_024) }),
        (
            "invalid room",
            {
                $0.roomID = "#alias:example.org"
                $0.selectedRoomID = $0.roomID
            }
        ),
    ]
    static let replacements: [(String, Change)] = [
        ("different account", { $0.accountID = "@other:example.org" }),
        ("new session", { $0.sessionGeneration = UUID() }), ("reopened timeline", { $0.timelineGeneration = UUID() }),
        ("another room", otherRoom), ("newer message", { $0.latestVisibleEventID = "$next-rendered" }),
    ]
    static let visitEnds: [(String, Change)] = [
        ("left the room", otherRoom), ("reopened", { $0.timelineGeneration = UUID() }),
        (
            "signed out",
            {
                $0.accountID = nil
                $0.sessionGeneration = nil
            }
        ),
    ]
    private static func changed(_ change: Change) -> ReadStateContext {
        var context = visible
        change(&context)
        return context
    }
    private static let otherRoom: Change = {
        $0.roomID = "!other:example.org"
        $0.selectedRoomID = $0.roomID
    }

    // capability: conversation.read
    @Test("The latest message you can see in the open room is marked read for your account")
    func visibleLatestEvent() throws {
        let target = try #require(ReadStatePolicy.automaticTarget(Self.visible))
        #expect(target.eventID == "$rendered")
        #expect(target.roomID == "!room:example.org" && target.accountID == "@reader:example.org")
        #expect(ReadStatePolicy.isCurrent(target, in: Self.visible))
    }

    @Test(
        "Nothing is marked read unless you are actually looking at the live bottom of a joined room",
        arguments: ineligible)
    func notEligible(reason: String, change: Change) throws {
        let target = try #require(ReadStatePolicy.automaticTarget(Self.visible))
        let context = Self.changed(change)
        #expect(ReadStatePolicy.automaticTarget(context) == nil)
        #expect(!ReadStatePolicy.isCurrent(target, in: context))
    }

    @Test(
        "A receipt queued for one view is not sent after the account, session, timeline, room or latest message changed",
        arguments: replacements)
    func replacedView(reason: String, change: Change) throws {
        let target = try #require(ReadStatePolicy.automaticTarget(Self.visible))
        let context = Self.changed(change)
        #expect(ReadStatePolicy.automaticTarget(context) != nil)
        #expect(!ReadStatePolicy.isCurrent(target, in: context))
    }

    // capability: conversation.mark-unread
    @Test("Mark unread holds even while the bottom is visible and new messages arrive")
    func holdSurvivesNewMessages() throws {
        let target = try #require(ReadStatePolicy.automaticTarget(Self.visible))
        var hold = ReadStateHold()
        hold.markUnread(Self.visible)
        #expect(ReadStatePolicy.automaticTarget(Self.visible, hold: hold) == nil)
        let newMessage = Self.changed { $0.latestVisibleEventID = "$arrived-after-mark-unread" }
        hold.observe(newMessage)
        #expect(hold.blocks(newMessage))
        #expect(!ReadStatePolicy.isCurrent(target, in: Self.visible, hold: hold))
    }

    @Test("Hiding and showing the window keeps a room marked unread")
    func holdSurvivesHiding() {
        var hold = ReadStateHold()
        hold.markUnread(Self.visible)
        hold.observe(Self.changed { $0.isWindowVisible = false })
        #expect(hold.blocks(Self.visible))
    }

    @Test("Only Mark read on the same room releases the hold")
    func explicitReadReleases() {
        var hold = ReadStateHold()
        hold.markUnread(Self.visible)
        hold.clearForExplicitRead(Self.changed(Self.otherRoom))
        #expect(hold.blocks(Self.visible))
        hold.clearForExplicitRead(Self.visible)
        #expect(ReadStatePolicy.automaticTarget(Self.visible, hold: hold) != nil)
    }

    @Test(
        "Leaving the room, reopening it or signing out ends the hold",
        arguments: visitEnds)
    func visitEndsHold(reason: String, change: Change) {
        var hold = ReadStateHold()
        hold.markUnread(Self.visible)
        let next = Self.changed(change)
        hold.observe(next)
        #expect(!hold.blocks(Self.visible) && !hold.blocks(next))
    }

    @Test("Mark unread from an incomplete view does not release an existing hold")
    func invalidMarkKeepsHold() {
        var hold = ReadStateHold()
        hold.markUnread(Self.visible)
        hold.markUnread(Self.changed { $0.sessionGeneration = nil })
        #expect(hold.blocks(Self.visible))
    }

    @Test(
        "A room shows as unread for notification counts, message counts or an explicit flag",
        arguments: [
            (ChatRoom(id: "!room", name: "Room", unread: 3), true),
            (ChatRoom(id: "!room", name: "Room", unreadMessages: 4), true),
            (ChatRoom(id: "!room", name: "Room", isMarkedUnread: true), true),
            (ChatRoom(id: "!room", name: "Room"), false),
        ])
    func roomUnread(room: ChatRoom, unread: Bool) {
        #expect(room.hasUnread == unread)
    }
}
