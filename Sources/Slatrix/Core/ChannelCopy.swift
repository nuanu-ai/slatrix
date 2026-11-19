import Foundation
import MatrixRustSDK

/// Slack's "Also send to #channel" for a thread reply: the channel gets a rich reply to it without rel_type m.thread,
/// which MSC3440 lets clients show in the main timeline to advertise a thread message.
enum ChannelCopy {
    /// Whether "Also send to #channel" shows checked under the thread `threadID`, which is what a reply sent from it
    /// does. Only text is copied, so the box sits out a reply with files.
    static func isChecked(checkedRootID: String?, threadID: String?, hasFiles: Bool) -> Bool {
        threadID != nil && checkedRootID == threadID && !hasFiles
    }

    /// The copy's event content as JSON. Its m.mentions is empty, so whoever the reply mentions hears once, from the
    /// thread.
    static func content(_ message: ComposerFormat.Message, replyTo eventID: String) throws -> String {
        var content: [String: Any] = [
            "msgtype": "m.text", "body": message.body, "m.mentions": [String: Any](),
            "m.relates_to": ["m.in_reply_to": ["event_id": eventID]],
        ]
        if let html = message.html {
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = html
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
    }
}

/// Waits for the reader's message with `body` to show up in a timeline and reach the server, for its event ID: the
/// copy needs it, and the send queue hands out none. Holding this keeps the timeline alive after its pane closes.
///
/// shortcut: the wait lives in memory, so a reply still queued when the app quits reaches its thread without its copy;
/// keep pending copies with the drafts if that turns out to matter.
final class SentEcho: TimelineListener, @unchecked Sendable {
    private enum Outcome {
        case sent(String)
        case lost
    }

    private let lock = NSLock()
    private let timeline: Timeline
    private let body: String
    private var items: [TimelineItem] = []
    private var before: Set<String>?
    private var echo: String?
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var handle: TaskHandle?

    /// Starts watching before the message is sent, so a message already there is never taken for it.
    init(_ timeline: Timeline, body: String) async {
        self.timeline = timeline
        self.body = body
        let handle = await timeline.addListener(listener: self)
        let finished = lock.withLock {
            self.handle = handle
            return outcome != nil
        }
        if finished { handle.cancel() }
    }

    /// The message's event ID once sent, or nil if it never will be.
    func sentEventID() async -> String? {
        await withCheckedContinuation { continuation in
            let known: Outcome? = lock.withLock {
                if outcome == nil { waiters.append(continuation) }
                return outcome
            }
            switch known {
            case .sent(let id): continuation.resume(returning: id)
            case .lost: continuation.resume(returning: nil)
            case nil: break
            }
        }
    }

    /// For a message that never made it into the send queue, or a session that ended.
    func cancel() { finish(.lost) }

    func onUpdate(diff: [TimelineDiff]) {
        let outcome: Outcome? = lock.withLock {
            guard self.outcome == nil else { return nil }
            let changes = diff.map(\.change)
            items.apply(changes)
            // The listener's first update is the timeline as it was before the send.
            guard let before else {
                before = Set(items.map { $0.uniqueId().id })
                return nil
            }
            // Its local echo, even when the sent event replaces it in the same update. Only this device's queue makes
            // one, so the same text sent from another device is never taken for it.
            echo =
                echo
                ?? changes.lazy.flatMap(\.values).first {
                    guard let event = $0.asEvent(), event.isOwn, case .transactionId = event.eventOrTransactionId,
                        case .msgLike(let content) = event.content, case .message(let message) = content.kind
                    else { return false }
                    return message.body == body && !before.contains($0.uniqueId().id)
                }?.uniqueId().id
            guard let echo else { return nil }
            // Gone means its sending was cancelled.
            guard let item = items.first(where: { $0.uniqueId().id == echo }) else { return .lost }
            guard case .eventId(let id) = item.asEvent()?.eventOrTransactionId else { return nil }
            return .sent(id)
        }
        if let outcome { finish(outcome) }
    }

    private func finish(_ result: Outcome) {
        let (waiting, listening): ([CheckedContinuation<String?, Never>], TaskHandle?) = lock.withLock {
            guard outcome == nil else { return ([], nil) }
            outcome = result
            defer { waiters = [] }
            return (waiters, handle)
        }
        listening?.cancel()
        let id: String? = if case .sent(let id) = result { id } else { nil }
        for waiter in waiting { waiter.resume(returning: id) }
    }
}
