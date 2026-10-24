import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// The user's own captioned image or file, shown as a thread root (or, for `inThread: false`, as a reply in the
/// main timeline while its thread is open).
@MainActor
private final class Captioning {
    let f = ActionFixture(rootID: "$media")
    let inThread: Bool
    let file: Bool
    var service: MatrixService { f.service }
    var timeline: ActionTimeline { inThread ? f.thread : f.main }
    var edits: [String] { timeline.writes.all }

    init(file: Bool = false, inThread: Bool = true) throws {
        self.file = file
        self.inThread = inThread
        try publish(captionedMedia(file: file, source: actionMediaSource()))
    }
    func event(_ type: MessageType) -> EventTimelineItem {
        messageEvent("$media", type: type, thread: inThread ? nil : "$other-root")
    }
    func publish(_ type: MessageType) { publish(event(type)) }
    func publish(_ event: EventTimelineItem) {
        timeline.event = event
        service.projectMediaCaptionForChecks([FakeTimelineItem(event)], roomID: f.roomID, inThread: inThread)
    }
    func target() throws -> MessageActionTarget {
        let message = try #require((inThread ? service.threadMessages : service.messages).first)
        return try f.target(message, inThread ? .thread(rootID: "$media") : .conversation)
    }
    func snapshot() async throws -> MediaCaptionSnapshot { try await service.loadMediaCaption(target()) }
}

@MainActor
struct MediaCaptionTests {
    @Test(
        "Editing a caption starts from the typed caption and HTML the thread timeline holds", arguments: [false, true])
    func loadsTypedCaption(file: Bool) async throws {
        let c = try Captioning(file: file)
        let snapshot = try await c.snapshot()
        #expect(snapshot.message.mediaCaption == "Current caption")
        #expect(snapshot.message.formattedBody?.hasPrefix("<b>Current caption</b>") == true)
        #expect(snapshot.message.showsMessageBody)
        #expect(!c.f.thread.reads.all.isEmpty && c.f.main.reads.all.isEmpty)
    }

    @Test("Saving an unchanged caption queues no edit, so its HTML is not flattened", arguments: [false, true])
    func unchangedCaptionQueuesNothing(file: Bool) async throws {
        let c = try Captioning(file: file)
        let snapshot = try await c.snapshot()
        #expect(try await !c.service.saveMediaCaption(snapshot, caption: snapshot.caption).queued)
        #expect(c.edits.isEmpty)
    }

    @Test(
        "Replacing a caption keeps the file name, upload and media info and drops the old HTML",
        arguments: [false, true], [Optional("Plain **literal** @room"), nil])
    func replacingCaptionKeepsMedia(file: Bool, caption: String?) throws {
        let source = try actionMediaSource()
        let original = try MediaCaptionContent(
            MessageContent(
                msgType: captionedMedia(file: file, source: source), body: "", isEdited: false, mentions: nil))
        let replaced = try MediaCaptionContent(original.replacingCaption(caption))
        #expect(replaced.caption == caption && replaced.formattedCaption == nil)
        #expect(replaced.filename == original.filename)
        #expect(replaced.source.toJson() == source.toJson())
        switch replaced {
        case .image(let image):
            #expect(image.info?.height == 240 && image.info?.width == 320 && image.info?.size == 1024)
            #expect(image.info?.thumbnailSource?.toJson() == source.toJson())
            #expect(image.info?.blurhash == "fixture-blurhash")
        case .file(let file):
            #expect(file.info?.size == 72 && file.info?.mimetype == "text/plain")
        }
    }

    @Test("Saving a new caption edits the original event with a room message", arguments: [false, true])
    func savesCaption(file: Bool) async throws {
        let c = try Captioning(file: file)
        let result = try await c.service.saveMediaCaption(try await c.snapshot(), caption: "New caption")
        #expect(result.queued)
        #expect(c.edits == ["edit:$media"])
        #expect(c.service.selectedRoomID == c.f.roomID)
    }

    @Test("Removing a caption queues an edit", arguments: [false, true])
    func removesCaption(file: Bool) async throws {
        let c = try Captioning(file: file)
        #expect(try await c.service.saveMediaCaption(try await c.snapshot(), caption: nil).queued)
        #expect(c.edits == ["edit:$media"])
    }

    @Test("A caption the SDK reads back as just the file name shows no caption", arguments: [false, true])
    func fileNameOnlyShowsNoCaption(file: Bool) async throws {
        let c = try Captioning(file: file)
        c.publish(captionedMedia(file: file, source: try actionMediaSource(), caption: nil))
        let snapshot = try await c.snapshot()
        #expect(snapshot.caption == nil && !snapshot.message.showsMessageBody)
        #expect(snapshot.message.body == snapshot.filename)
    }

    @Test("A thread reply shown in the main timeline is captioned there even while its thread is open")
    func mainReplyUsesMain() async throws {
        let c = try Captioning(inThread: false)
        _ = try await c.service.saveMediaCaption(try await c.snapshot(), caption: nil)
        #expect(c.f.main.writes.all == ["edit:$media"])
        #expect(c.f.thread.reads.all.isEmpty && c.f.thread.writes.all.isEmpty)
    }

    enum Change: String, CaseIterable, CustomTestStringConvertible {
        case caption, formatting, encryptedSource
        var testDescription: String { rawValue }
    }

    @Test("A caption, formatting or upload change since review needs a fresh review", arguments: Change.allCases)
    func changeNeedsFreshReview(change: Change) async throws {
        let c = try Captioning()
        let before = try await c.snapshot()
        guard case .image(var image) = captionedMedia(file: false, source: try actionMediaSource()) else { return }
        switch change {
        case .caption: image.caption = "Changed elsewhere"
        case .formatting: image.formattedCaption = FormattedBody(format: .html, body: "<em>changed</em>")
        case .encryptedSource: image.source = try actionMediaSource(replacement: true)
        }
        c.publish(.image(content: image))
        do {
            _ = try await c.service.saveMediaCaption(before, caption: "My draft")
            Issue.record("a changed attachment must not be saved over")
        } catch let changed as MediaCaptionReviewChanged {
            #expect(changed.snapshot.revision != before.revision && c.edits.isEmpty)
            _ = try await c.service.saveMediaCaption(changed.snapshot, caption: "My draft")
            #expect(c.edits == ["edit:$media"])
        }
    }

    @Test("The SDK returning a newer upload than the timeline shows is refused")
    func newerSDKSourceIsRefused() async throws {
        let c = try Captioning()
        let target = try c.target()
        c.timeline.event = c.event(captionedMedia(file: false, source: try actionMediaSource(replacement: true)))
        await #expect(throws: (any Error).self) { try await c.service.loadMediaCaption(target) }
    }

    enum Ineligible: String, CaseIterable, CustomTestStringConvertible {
        case otherSender, otherEvent, localEcho, text, pendingEdit, pendingDeletion, notEditable, deleted
        var testDescription: String { rawValue }
    }

    @Test("Only the user's own sent image or file can have its caption edited", arguments: Ineligible.allCases)
    func refusesIneligibleSource(reason: Ineligible) async throws {
        let c = try Captioning()
        let target = try c.target()
        var event = try #require(c.timeline.event)
        switch reason {
        case .otherSender: event.sender = "@other:example.org"
        case .otherEvent: event.eventOrTransactionId = .eventId(eventId: "$wrong")
        case .localEcho: event.isRemote = false
        case .text:
            event = messageEvent("$media", type: .text(content: TextMessageContent(body: "text", formatted: nil)))
        case .pendingEdit: event.editSendState = .notSentYet(progress: nil)
        case .pendingDeletion: event.redactionSendState = .notSentYet(progress: nil)
        case .notEditable: event.isEditable = false
        case .deleted:
            event.content = .msgLike(
                content: MsgLikeContent(kind: .redacted, inReplyTo: nil, threadRoot: nil, threadSummary: nil))
        }
        c.timeline.event = event
        await #expect(throws: (any Error).self) { try await c.service.loadMediaCaption(target) }
    }

    enum Staleness: String, CaseIterable, CustomTestStringConvertible {
        case session, left, removed, cancelled
        var testDescription: String { rawValue }
    }

    @Test(
        "A caption save whose context went stale while it re-read the message edits nothing",
        arguments: Staleness.allCases)
    func staleSaveEditsNothing(change: Staleness) async throws {
        let c = try Captioning()
        let snapshot = try await c.snapshot()
        c.timeline.readGate.arm()
        let pending = Task { try await c.service.saveMediaCaption(snapshot, caption: "Draft") }
        #expect(await eventually { c.timeline.readGate.isWaiting })
        switch change {
        case .session: c.f.apply(.session)
        case .left: c.f.apply(.left)
        case .removed: c.service.threadMessages = []
        case .cancelled: pending.cancel()
        }
        c.timeline.readGate.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(c.edits.isEmpty && c.service.errorMessage == nil)
    }

    @Test("Saving the same review again while it is saving is refused as busy")
    func duplicateSaveIsBusy() async throws {
        let c = try Captioning()
        let snapshot = try await c.snapshot()
        c.timeline.gate.arm()
        let first = Task { try await c.service.saveMediaCaption(snapshot, caption: nil) }
        #expect(await eventually { c.timeline.gate.isWaiting })
        await #expect(throws: MediaCaptionError.busy) { try await c.service.saveMediaCaption(snapshot, caption: nil) }
        c.timeline.gate.release()
        _ = try await first.value
        #expect(c.edits == ["edit:$media"])
    }

    @Test("An edit the SDK rejects can be retried")
    func rejectedEditIsRetryable() async throws {
        let c = try Captioning()
        let snapshot = try await c.snapshot()
        c.timeline.failsWrites = true
        await #expect(throws: MatrixServiceError.self) { try await c.service.saveMediaCaption(snapshot, caption: nil) }
        c.timeline.failsWrites = false
        #expect(try await c.service.saveMediaCaption(snapshot, caption: nil).queued)
        #expect(c.edits == ["edit:$media", "edit:$media"])
    }

    @Test(
        "Once the SDK accepts the edit, it is reported as queued whatever happens next",
        arguments: ["session", "message deleted", "cancelled"])
    func acceptedEditStaysQueued(change: String) async throws {
        let c = try Captioning()
        let snapshot = try await c.snapshot()
        c.timeline.gate.arm()
        let pending = Task { try await c.service.saveMediaCaption(snapshot, caption: nil) }
        #expect(await eventually { c.timeline.gate.isWaiting })
        switch change {
        case "session": c.f.apply(.session)
        case "message deleted": c.service.threadMessages[0].isRedacted = true
        default: pending.cancel()
        }
        c.timeline.gate.release()
        #expect(try await pending.value.queued)
        #expect(c.edits == ["edit:$media"])
    }
}
