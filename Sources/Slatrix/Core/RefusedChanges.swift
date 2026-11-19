import Foundation
import MatrixRustSDK

/// A deletion or edit the server refused stays at the head of its room's send queue, and everything sent there after
/// it waits. As Slack keeps a message it couldn't delete or edit, each one is cancelled as soon as it's refused, or
/// found after a relaunch, whichever conversation is on screen: the message goes back to how the server has it.
@MainActor
final class RefusedChanges {
    struct Undone: Equatable {
        let roomID: String
        /// The thread the message is a reply in; nil for one in the channel, a thread's root included.
        let threadRootID: String?
        let target: SendTarget
    }

    private enum Update: Sendable {
        case queued(room: String, transaction: String)
        case gone(room: String, transaction: String)
        case refused(room: String)
        /// Everything queued before the subscription has been heard.
        case launched
    }

    private final class Listener: SendQueueRoomUpdateListener, @unchecked Sendable {
        let continuation: AsyncStream<Update>.Continuation
        init(_ continuation: AsyncStream<Update>.Continuation) { self.continuation = continuation }
        func onUpdate(roomId: String, update: RoomSendQueueUpdate) {
            switch update {
            case .newLocalEvent(let transaction): continuation.yield(.queued(room: roomId, transaction: transaction))
            case .sentEvent(let transaction, _), .cancelledLocalEvent(let transaction):
                continuation.yield(.gone(room: roomId, transaction: transaction))
            // A failure the queue retries by itself is still on its way.
            case .sendError(_, _, isRecoverable: false): continuation.yield(.refused(room: roomId))
            default: break
            }
        }
    }

    private final class Items: TimelineListener, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [TimelineItem] = []
        let updates: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        init() { (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
        func onUpdate(diff: [TimelineDiff]) {
            _ = lock.withLock { items.apply(diff.map(\.change)) }
            continuation.yield()
        }
        var shown: [TimelineItem] { lock.withLock { items } }
    }

    private let client: Client
    private let undone: (Undone) -> Void
    private var subscription: TaskHandle?
    private var reader: Task<Void, Never>?
    /// What each room's queue holds, by transaction.
    private var queued: [String: Set<String>] = [:]
    private var sweeps: [String: Task<Void, Never>] = [:]

    init(client: Client, undone: @escaping (Undone) -> Void) {
        self.client = client
        self.undone = undone
    }

    func start() async throws {
        let (updates, continuation) = AsyncStream.makeStream(of: Update.self)
        subscription = try await client.subscribeToSendQueueUpdates(listener: Listener(continuation))
        continuation.yield(.launched)
        reader = Task { [weak self] in
            for await update in updates {
                guard let self else { return }
                switch update {
                case .queued(let room, let transaction): queued[room, default: []].insert(transaction)
                case .gone(let room, let transaction): queued[room]?.remove(transaction)
                case .refused(let room): sweep(room)
                case .launched: for room in queued.keys { sweep(room) }
                }
            }
        }
    }

    func stop() {
        subscription?.cancel()
        reader?.cancel()
        for sweep in sweeps.values { sweep.cancel() }
        sweeps = [:]
    }

    private func sweep(_ roomID: String) {
        let previous = sweeps[roomID]
        sweeps[roomID] = Task { [weak self] in
            await previous?.value
            await self?.cancelRefused(in: roomID)
        }
    }

    /// The SDK cancels a queued change only through a timeline that shows its message, so this reads the room, thread
    /// replies included, back from the newest message until it finds one, or nothing it hasn't seen is queued.
    private func cancelRefused(in roomID: String) async {
        guard !Task.isCancelled, let room = try? client.getRoom(roomId: roomID),
            let timeline = try? await room.timelineWithConfiguration(
                configuration: TimelineConfiguration(
                    focus: .live(hideThreadedEvents: false), filter: .all, internalIdPrefix: nil,
                    dateDividerMode: .daily, trackReadReceipts: .disabled, reportUtds: false))
        else { return }
        let items = Items()
        let handle = await timeline.addListener(listener: items)
        defer { handle.cancel() }
        var updates = items.updates.makeAsyncIterator()
        while !Task.isCancelled {
            let shown = items.shown
            let refused = shown.compactMap(Self.refused)
            for (id, threadRootID, target) in refused {
                guard (try? await timeline.abortSend(itemId: id, target: target)) == true, !Task.isCancelled
                else { continue }
                undone(Undone(roomID: roomID, threadRootID: threadRootID, target: target))
            }
            // A message the server refused shows in its conversation, which offers to retry or remove it.
            let echoes = Set(
                shown.compactMap { item -> String? in
                    guard case .transactionId(let transaction) = item.asEvent()?.eventOrTransactionId else {
                        return nil
                    }
                    return transaction
                })
            guard refused.isEmpty, queued[roomID]?.isSubset(of: echoes) == false,
                !shown.contains(where: { $0.asVirtual() == .timelineStart })
            else { return }
            guard let reachedStart = try? await timeline.paginateBackwards(numEvents: 50) else { return }
            // The start of the room shows after every page before it.
            while reachedStart, !items.shown.contains(where: { $0.asVirtual() == .timelineStart }) {
                guard await updates.next() != nil else { return }
            }
        }
    }

    private static func refused(_ item: TimelineItem) -> (EventOrTransactionId, String?, SendTarget)? {
        guard let event = item.asEvent() else { return nil }
        func refused(_ state: EventSendState?) -> Bool {
            if case .sendingFailed(_, isRecoverable: false) = state { true } else { false }
        }
        let target: SendTarget
        if refused(event.redactionSendState) {
            target = .redaction
        } else if refused(event.editSendState) {
            target = .edit
        } else {
            return nil
        }
        var threadRootID: String?
        if case .msgLike(let content) = event.content { threadRootID = content.threadRoot }
        return (event.eventOrTransactionId, threadRootID, target)
    }
}
