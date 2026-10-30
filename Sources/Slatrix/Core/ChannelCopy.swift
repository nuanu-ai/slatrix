import Foundation
import MatrixRustSDK

/// Slack's "Also send to #channel" for a thread reply: the channel gets a rich reply to it without rel_type m.thread,
/// which MSC3440 lets clients show in the main timeline to advertise a thread message.
enum ChannelCopy {
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

/// Waits for the reader's next own message in a timeline to reach the server, for its event ID: the copy needs it,
/// and the send queue hands out none. Holding this keeps the timeline alive after its pane closes.
final class SentEcho: TimelineListener, @unchecked Sendable {
    private let lock = NSLock()
    private let timeline: Timeline
    private var items: [TimelineItem] = []
    private var before: Set<String>?
    private var echo: String?
    private var outcome: String??
    private var waiter: CheckedContinuation<String?, Never>?
    private var handle: TaskHandle?

    /// Starts watching before the message is sent, so an echo already there is never taken for it.
    init(_ timeline: Timeline) async {
        self.timeline = timeline
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
            let ready: String?? = lock.withLock {
                if outcome == nil { waiter = continuation }
                return outcome
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// For a message that never made it into the send queue.
    func cancel() { finish(nil) }

    func onUpdate(diff: [TimelineDiff]) {
        let sent: String?? = lock.withLock {
            guard outcome == nil else { return nil }
            items.apply(diff.map(\.change))
            // The listener's first update is the timeline as it was before the send.
            guard let before else {
                before = Set(items.map { $0.uniqueId().id })
                return nil
            }
            if echo == nil {
                echo =
                    items.first {
                        guard let event = $0.asEvent(), event.isOwn, case .transactionId = event.eventOrTransactionId
                        else { return false }
                        return !before.contains($0.uniqueId().id)
                    }?.uniqueId().id
            }
            guard let echo else { return nil }
            // Gone means its sending was cancelled.
            guard let item = items.first(where: { $0.uniqueId().id == echo }) else { return .some(nil) }
            guard case .eventId(let id) = item.asEvent()?.eventOrTransactionId else { return nil }
            return id
        }
        if let sent { finish(sent) }
    }

    private func finish(_ eventID: String?) {
        let (waiter, handle): (CheckedContinuation<String?, Never>?, TaskHandle?) = lock.withLock {
            guard outcome == nil else { return (nil, nil) }
            outcome = .some(eventID)
            defer { waiter = nil }
            return (waiter, handle)
        }
        handle?.cancel()
        waiter?.resume(returning: eventID)
    }
}
