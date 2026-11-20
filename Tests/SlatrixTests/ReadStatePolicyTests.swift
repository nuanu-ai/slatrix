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
        ("covered by a pane, the media viewer or a dialog", { $0.isCovered = true }),
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

    struct Shown: CustomTestStringConvertible, Sendable {
        var testDescription: String
        var roomID = "!room:example.org"
        var threadRootID: String?
        var conversation: Change = { _ in }
        var thread: @Sendable (inout ThreadReadContext) -> Void = { _ in }
        var shown: Bool
    }
    static let shown: [Shown] = [
        Shown(testDescription: "a message in the conversation", shown: true),
        Shown(testDescription: "the conversation scrolled up", conversation: { $0.isAtBottom = false }, shown: true),
        Shown(
            testDescription: "the conversation opened at an older message", conversation: { $0.isLiveTimeline = false },
            shown: true),
        Shown(
            testDescription: "a pane in the conversation's place", conversation: { $0.isCovered = true },
            shown: false),
        Shown(
            testDescription: "a window the reader can't read", conversation: { $0.isWindowActive = false },
            shown: false),
        Shown(testDescription: "another conversation", roomID: "!other:example.org", shown: false),
        Shown(testDescription: "a reply in the open thread", threadRootID: "$root", shown: true),
        Shown(
            testDescription: "a reply to a closed thread, its conversation shown", threadRootID: "$root",
            thread: {
                $0.identity = nil
                $0.isPresented = false
            }, shown: false),
        Shown(testDescription: "a reply to another thread", threadRootID: "$other", shown: false),
        Shown(
            testDescription: "the open thread scrolled up", threadRootID: "$root", thread: { $0.isAtBottom = false },
            shown: true),
        Shown(
            testDescription: "the media viewer over the open thread", threadRootID: "$root",
            thread: { $0.isCovered = true }, shown: false),
    ]

    // capability: notifications.alert
    @Test("A message's conversation or thread is shown only where the reader can see it", arguments: shown)
    func paneShown(shown: Shown) {
        var conversation = Self.visible
        shown.conversation(&conversation)
        var thread = ThreadReadContext(
            identity: ThreadReadIdentity(
                accountID: "@reader:example.org", sessionID: UUID(), roomID: "!room:example.org", timelineID: UUID(),
                rootID: "$root", threadSelectionID: UUID(), presentationID: UUID()),
            eventID: "$reply", isPresented: true, isReady: true, isAtBottom: true, isWindowActive: true,
            isWindowVisible: true, isWindowUnoccluded: true)
        shown.thread(&thread)
        #expect(
            ReadStatePolicy.isShown(
                roomID: shown.roomID, threadRootID: shown.threadRootID, conversation: conversation, thread: thread)
                == shown.shown)
    }

    struct Seen: CustomTestStringConvertible, Sendable {
        var testDescription: String
        var event: String
        var shown = true
        var newestInView: String?
        var laidOut: String? = "$c"
        var seen: Bool?
    }
    static let seen: [Seen] = [
        Seen(testDescription: "the newest message in view", event: "$c", newestInView: "$c", seen: true),
        Seen(testDescription: "a message above the newest in view", event: "$a", newestInView: "$b", seen: true),
        Seen(testDescription: "a message below the newest in view", event: "$c", newestInView: "$b", seen: false),
        Seen(testDescription: "nothing in view", event: "$a", seen: false),
        Seen(testDescription: "a message its pane has yet to lay out", event: "$d", newestInView: "$c", seen: nil),
        Seen(testDescription: "a pane that hasn't reported", event: "$a", laidOut: nil, seen: nil),
        Seen(
            testDescription: "a message in a pane that isn't shown", event: "$c", shown: false, newestInView: "$c",
            seen: false),
    ]

    // capability: notifications.alert
    @Test("A message is seen once its shown pane has it at or before the newest message in view", arguments: seen)
    func messageSeen(seen: Seen) {
        #expect(
            ReadStatePolicy.seen(
                seen.event, shown: seen.shown, in: ReadStatePolicy.positions(["$a", "$b", "$c", "$d"]),
                report: seen.laidOut.map { PaneReport(newestInView: seen.newestInView, laidOut: $0) }) == seen.seen)
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
