import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct MessageActionTests {
    @Test("Reacting to, editing and deleting a thread root go to the thread timeline that showed it")
    func threadRootActionsUseThreadTimeline() async throws {
        let f = ActionFixture()
        let root = f.message(f.rootID)
        f.service.messages = []
        f.service.threadMessages = [root]
        let target = try f.target(root, .thread(rootID: f.rootID))
        try await f.service.toggleReaction(target, key: "👍")
        try await f.service.editMessage(target, body: "Changed")
        try await f.service.deleteMessage(target)
        #expect(f.thread.writes.all == ["reaction:👍:$root", "edit:$root", "delete:$root"])
        #expect(f.main.writes.all.isEmpty)
    }

    @Test("A thread reply shown in the main timeline is acted on there even while its thread is open")
    func mainReplyUsesMainTimeline() async throws {
        let f = ActionFixture()
        let reply = f.message("$reply", inThread: true)
        f.service.messages = [reply]
        f.service.threadMessages = [f.message(f.rootID), reply]
        let target = try f.target(reply, .conversation)
        try await f.service.toggleReaction(target, key: "✅")
        try await f.service.deleteMessage(target)
        #expect(f.main.writes.all == ["reaction:✅:$reply", "delete:$reply"])
        #expect(f.thread.writes.all.isEmpty)
    }

    @Test("Adding a reaction makes its emoji the most recent and saves it to the account; taking one back does not")
    func reactionsUpdateRecentEmoji() async throws {
        let f = ActionFixture()
        f.client.storedRecentEmoji = [RecentEmoji(emoji: "🔥", count: 2), RecentEmoji(emoji: "👍", count: 1)]
        await f.service.loadRecentEmoji()
        #expect(f.service.recentEmoji == ["🔥", "👍"])
        var message = f.message("$one")
        message.reactions = [MessageReaction(key: "🎉", count: 1, mine: true, senders: [f.userID])]
        f.service.messages = [message]
        let target = try f.target(message, .conversation)
        try await f.service.toggleReaction(target, key: "👍")
        try await f.service.toggleReaction(target, key: "🎉")
        #expect(f.service.recentEmoji == ["👍", "🔥"])
        #expect(await eventually { f.client.recentEmoji.all == ["👍"] })
    }

    @Test("A thread that has not loaded offers no actions")
    func unloadedThreadOffersNoActions() {
        let f = ActionFixture(threadReady: false)
        let root = f.message(f.rootID)
        f.service.threadMessages = [root]
        #expect(f.service.captureMessageAction(message: root, surface: .thread(rootID: f.rootID)) == nil)
    }

    enum Staleness: String, CaseIterable, CustomTestStringConvertible {
        case session, left, deleted, removed, threadReopened
        var testDescription: String { rawValue }
    }

    @Test("An action captured before its context went stale makes no SDK write", arguments: Staleness.allCases)
    func staleActionMakesNoWrite(change: Staleness) async throws {
        let f = ActionFixture()
        let reply = f.message("$reply", inThread: true)
        f.service.messages = [reply]
        f.service.threadMessages = [f.message(f.rootID), reply]
        let surface: MessageActionTarget.Surface = change == .threadReopened ? .thread(rootID: f.rootID) : .conversation
        let target = try f.target(reply, surface)
        switch change {
        case .session: f.apply(.session)
        case .left: f.apply(.left)
        case .threadReopened: f.apply(.threadReopened)
        case .deleted: f.service.messages[0].isRedacted = true
        case .removed: f.service.messages = []
        }
        await #expect(throws: CancellationError.self) { try await f.service.toggleReaction(target, key: "👀") }
        #expect(f.main.writes.all.isEmpty && f.thread.writes.all.isEmpty)
    }

    @Test("A delete still succeeds when its sync echo removes the row before the SDK call returns")
    func deleteSurvivesItsOwnEcho() async throws {
        let f = ActionFixture()
        f.service.messages = [f.message("$reply")]
        let target = try f.target(f.service.messages[0], .conversation)
        f.main.gate.arm()
        let deleting = Task { try await f.service.deleteMessage(target) }
        #expect(await eventually { f.main.gate.isWaiting })
        f.service.messages = []
        f.main.gate.release()
        try await deleting.value
        #expect(f.main.writes.all == ["delete:$reply"])
    }

    @Test("A late result from a previous session ends quietly without a second write", arguments: [false, true])
    func lateResultAfterSessionChange(fails: Bool) async throws {
        let f = ActionFixture()
        f.service.messages = [f.message("$reply")]
        f.main.failsWrites = fails
        let target = try f.target(f.service.messages[0], .conversation)
        f.main.gate.arm()
        let pending = Task { try await f.service.toggleReaction(target, key: "🤝") }
        #expect(await eventually { f.main.gate.isWaiting })
        f.apply(.session)
        f.main.gate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(f.main.writes.all == ["reaction:🤝:$reply"] && f.thread.writes.all.isEmpty)
        #expect(f.service.errorMessage == nil)
    }

    // MARK: Reply previews

    private func quotingRoot(_ f: ActionFixture) -> ChatMessage {
        var root = f.message(f.rootID)
        root.replyToID = "$quoted"
        root.replyPreview = ChatReplyPreview(state: .unavailable, eventID: "$quoted")
        return root
    }

    @Test("A failed reply preview marks only the pane that asked, and Retry fetches it again")
    func replyPreviewFailureAndRetry() async throws {
        let f = ActionFixture()
        let root = quotingRoot(f)
        f.service.messages = [root]
        f.service.threadMessages = [root]
        f.thread.failsWrites = true
        let target = try f.target(root, .thread(rootID: f.rootID))
        await f.service.loadReplyPreview(for: target)
        #expect(f.service.threadMessages[0].replyPreview?.state == .failed)
        #expect(f.service.messages[0].replyPreview?.state == .unavailable)
        await f.service.loadReplyPreview(for: target)
        #expect(f.thread.writes.all == ["details:$root", "details:$root"])
        #expect(f.main.writes.all.isEmpty)
    }

    @Test("A historical reply in the main timeline loads its preview there and leaves the thread pane alone")
    func mainReplyPreviewUsesMain() async throws {
        let f = ActionFixture()
        var reply = quotingRoot(f)
        reply.id = "$historical"
        reply.threadRootID = f.rootID
        f.service.messages = [reply]
        f.service.threadMessages = [quotingRoot(f), reply]
        f.main.failsWrites = true
        await f.service.loadReplyPreview(for: try f.target(reply, .conversation))
        #expect(f.main.writes.all == ["details:$historical"] && f.thread.writes.all.isEmpty)
        #expect(f.service.messages[0].replyPreview?.state == .failed)
        #expect(f.service.threadMessages[1].replyPreview?.state == .unavailable)
    }

    @Test("Asking again while a reply preview loads shares the request in flight")
    func duplicateReplyPreviewSharesRequest() async throws {
        let f = ActionFixture()
        let root = quotingRoot(f)
        f.service.threadMessages = [root]
        let target = try f.target(root, .thread(rootID: f.rootID))
        f.thread.gate.arm()
        let pending = Task { await f.service.loadReplyPreview(for: target) }
        #expect(await eventually { f.thread.gate.isWaiting })
        await f.service.loadReplyPreview(for: target)
        f.thread.gate.release()
        await pending.value
        #expect(f.thread.writes.all == ["details:$root"])
    }

    @Test("A late fetch error never downgrades a preview the SDK already filled in")
    func lateErrorKeepsReadyPreview() async throws {
        let f = ActionFixture()
        let root = quotingRoot(f)
        f.service.threadMessages = [root]
        f.thread.failsWrites = true
        let target = try f.target(root, .thread(rootID: f.rootID))
        f.thread.gate.arm()
        let pending = Task { await f.service.loadReplyPreview(for: target) }
        #expect(await eventually { f.thread.gate.isWaiting })
        f.service.threadMessages[0].replyPreview = ChatReplyPreview(state: .ready, eventID: "$quoted", body: "Quoted")
        f.thread.gate.release()
        await pending.value
        #expect(f.service.threadMessages[0].replyPreview?.state == .ready)
    }

    enum PreviewChange: String, CaseIterable, CustomTestStringConvertible {
        case quoteReplaced, session, cancelled
        var testDescription: String { rawValue }
    }

    @Test(
        "A late reply preview error after the row or context changed writes nothing", arguments: PreviewChange.allCases)
    func lateReplyPreviewErrorIsDropped(change: PreviewChange) async throws {
        let f = ActionFixture()
        let root = quotingRoot(f)
        f.service.threadMessages = [root]
        f.thread.failsWrites = true
        let target = try f.target(root, .thread(rootID: f.rootID))
        f.thread.gate.arm()
        let pending = Task { await f.service.loadReplyPreview(for: target) }
        #expect(await eventually { f.thread.gate.isWaiting })
        switch change {
        case .quoteReplaced:
            f.service.threadMessages[0].replyToID = "$new-quote"
            f.service.threadMessages[0].replyPreview = ChatReplyPreview(state: .unavailable, eventID: "$new-quote")
        case .session: f.apply(.session)
        case .cancelled: pending.cancel()
        }
        let expected = f.service.threadMessages
        f.thread.gate.release()
        await pending.value
        #expect(f.service.threadMessages == expected)
        #expect(f.service.errorMessage == nil)
    }

    @Test("A queued reply preview whose quote changed under the same event fetches nothing")
    func changedQuoteFetchesNothing() async throws {
        let f = ActionFixture()
        let root = quotingRoot(f)
        f.service.threadMessages = [root]
        let target = try f.target(root, .thread(rootID: f.rootID))
        f.service.threadMessages[0].replyToID = "$replacement"
        await f.service.loadReplyPreview(for: target)
        #expect(f.thread.writes.all.isEmpty)
        f.service.threadMessages[0].replyToID = "$quoted"
        await f.service.loadReplyPreview(for: target)
        #expect(f.thread.writes.all == ["details:$root"])
    }
}
