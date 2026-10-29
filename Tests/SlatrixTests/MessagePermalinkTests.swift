import Foundation
import Testing

@testable import Slatrix

@MainActor
struct MessagePermalinkTests {
    private static let rootLink = "https://matrix.to/#/!actions:example.org/$root%2Fwith%23opaque?via=route.example.org"
    private static let replyLink = "https://matrix.to/#/!actions:example.org/$reply?via=route.example.org"

    /// A thread root that only the thread pane shows, and one of its replies shown in the main timeline.
    private func fixture(threadReady: Bool = true) -> (ActionFixture, root: ChatMessage, reply: ChatMessage) {
        let f = ActionFixture(rootID: "$root/with#opaque", threadReady: threadReady)
        let root = f.message(f.rootID)
        let reply = f.message("$reply", inThread: true)
        f.room.links = [root.id: Self.rootLink, reply.id: Self.replyLink]
        f.service.messages = [reply]
        f.service.threadMessages = [root, reply]
        return (f, root, reply)
    }

    // capability: message.copy-link
    @Test("Copying a thread root's link asks the SDK for that exact event and returns its link unchanged")
    func threadRootLink() async throws {
        let (f, root, _) = fixture()
        let target = try #require(f.service.captureMessagePermalink(message: root, surface: .thread(rootID: root.id)))
        #expect(try await f.service.messagePermalink(for: target) == Self.rootLink)
        #expect(f.room.linkRequests.all == [root.id])
    }

    // capability: message.copy-link
    @Test("A thread reply shown in the main timeline links to itself, not to the open thread's root")
    func mainReplyLinksItself() async throws {
        let (f, _, reply) = fixture()
        let target = try #require(f.service.captureMessagePermalink(message: reply, surface: .conversation))
        #expect(try await f.service.messagePermalink(for: target) == Self.replyLink)
    }

    @Test("A deleted message can still be linked, though it can no longer be acted on")
    func deletedMessageCanBeLinked() async throws {
        let (f, root, _) = fixture()
        f.service.threadMessages[0].isRedacted = true
        let deleted = f.service.threadMessages[0]
        let target = try #require(
            f.service.captureMessagePermalink(message: deleted, surface: .thread(rootID: root.id)))
        #expect(try await f.service.messagePermalink(for: target) == Self.rootLink)
        #expect(f.service.captureMessageAction(message: deleted, surface: .thread(rootID: root.id)) == nil)
    }

    @Test("A thread that has not loaded offers no link and never falls back to the main timeline")
    func unloadedThreadOffersNoLink() {
        let (f, root, _) = fixture(threadReady: false)
        #expect(f.service.captureMessagePermalink(message: root, surface: .thread(rootID: root.id)) == nil)
    }

    @Test("A message that has not reached the server offers no link")
    func unsentMessageOffersNoLink() {
        let (f, root, _) = fixture()
        var local = f.message("local-echo", inThread: true)
        local.sendState = "sending"
        f.service.threadMessages = [root, local]
        #expect(f.service.captureMessagePermalink(message: local, surface: .thread(rootID: root.id)) == nil)
    }

    @Test("An SDK failure reaches the caller for Retry without a global error, and Retry can succeed")
    func failureIsRetryable() async throws {
        let (f, root, _) = fixture()
        let target = try #require(f.service.captureMessagePermalink(message: root, surface: .thread(rootID: root.id)))
        f.room.failsLinks = true
        await #expect(throws: MatrixServiceError.self) { try await f.service.messagePermalink(for: target) }
        #expect(f.service.errorMessage == nil)
        f.room.failsLinks = false
        #expect(try await f.service.messagePermalink(for: target) == Self.rootLink)
    }

    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case session, selection, threadReload, threadReopened, room, removed, left, unsent, preview, account, cancelled
        var testDescription: String { rawValue }
    }

    // The permalink guard is its own copy of the action context check, so it keeps its own table.
    @Test(
        "A link that arrives after its context went stale is dropped quietly", arguments: Change.allCases,
        [false, true])
    func staleLinkIsDropped(change: Change, fails: Bool) async throws {
        let (f, root, _) = fixture()
        f.room.failsLinks = fails
        let target = try #require(f.service.captureMessagePermalink(message: root, surface: .thread(rootID: root.id)))
        f.room.linkGate.arm()
        let pending = Task { try await f.service.messagePermalink(for: target) }
        #expect(await eventually { f.room.linkGate.isWaiting })
        switch change {
        case .session: f.apply(.session)
        case .selection: f.apply(.selection)
        case .threadReload: f.apply(.threadReload)
        case .threadReopened: f.apply(.threadReopened)
        case .left: f.apply(.left)
        case .room: f.service.selectedRoomID = "!other:example.org"
        case .removed: f.service.threadMessages = []
        case .unsent: f.service.threadMessages[0].sendState = "sending"
        case .preview: f.service.isPreview = true
        case .account: f.service.user = ChatUser(id: "@other:example.org", name: "Other")
        case .cancelled: pending.cancel()
        }
        f.room.linkGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(f.service.errorMessage == nil)
    }

    @Test("A copy queued from a pane that has since closed makes no SDK request")
    func closedPaneMakesNoRequest() async throws {
        let (f, root, _) = fixture()
        let target = try #require(f.service.captureMessagePermalink(message: root, surface: .thread(rootID: root.id)))
        f.service.setMessageActionThread(rootID: nil)
        await #expect(throws: CancellationError.self) { try await f.service.messagePermalink(for: target) }
        #expect(f.room.linkRequests.all.isEmpty)
    }

    @Test("Closing and reopening a thread does not cancel a main-timeline link")
    func threadChurnKeepsMainLink() async throws {
        let (f, _, reply) = fixture()
        let target = try #require(f.service.captureMessagePermalink(message: reply, surface: .conversation))
        f.room.linkGate.arm()
        let pending = Task { try await f.service.messagePermalink(for: target) }
        #expect(await eventually { f.room.linkGate.isWaiting })
        f.apply(.threadReopened)
        f.room.linkGate.release()
        #expect(try await pending.value == Self.replyLink)
    }

    @Test("Editing a message while its link loads still links the original event")
    func editKeepsOriginalEvent() async throws {
        let (f, root, _) = fixture()
        let target = try #require(f.service.captureMessagePermalink(message: root, surface: .thread(rootID: root.id)))
        f.room.linkGate.arm()
        let pending = Task { try await f.service.messagePermalink(for: target) }
        #expect(await eventually { f.room.linkGate.isWaiting })
        f.service.threadMessages[0].body = "New edit"
        f.service.threadMessages[0].isEdited = true
        f.room.linkGate.release()
        #expect(try await pending.value == Self.rootLink)
    }
}
