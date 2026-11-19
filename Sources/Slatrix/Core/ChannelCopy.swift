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

/// Waits for a send to reach the server, for its event ID: the copy needs it. It follows the send's own transaction
/// through its room's send queue, so nothing else sent with the same words, before it or from another device, is ever
/// taken for it.
///
/// shortcut: the wait lives in memory, so a reply still queued when the app quits reaches its thread without its copy;
/// keep pending copies with the drafts if that turns out to matter.
final class SentEcho: SendQueueListener, @unchecked Sendable {
    private enum Outcome {
        case sent(String)
        case lost
    }

    private let lock = NSLock()
    private var transaction: String?
    /// What the queue said before the send handed out its transaction.
    private var heard: [String: Outcome] = [:]
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<String?, Never>] = []
    private var handle: TaskHandle?

    /// Starts listening before the message is sent, so its outcome is never missed.
    init(_ room: Room) async throws {
        let handle = try await room.subscribeToSendQueueUpdates(listener: self)
        let finished = lock.withLock {
            self.handle = handle
            return outcome != nil
        }
        if finished { handle.cancel() }
    }

    /// The send this follows, by the transaction its handle carries.
    func follow(_ transaction: String) {
        let known: Outcome? = lock.withLock {
            self.transaction = transaction
            defer { heard = [:] }
            return heard[transaction]
        }
        if let known { finish(known) }
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

    func onUpdate(update: RoomSendQueueUpdate) {
        let id: String
        let result: Outcome
        switch update {
        case .sentEvent(let transaction, let eventID): (id, result) = (transaction, .sent(eventID))
        case .cancelledLocalEvent(let transaction): (id, result) = (transaction, .lost)
        default: return
        }
        let mine: Bool = lock.withLock {
            guard let transaction else {
                heard[id] = result
                return false
            }
            return transaction == id
        }
        if mine { finish(result) }
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
