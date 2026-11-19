import Foundation

/// The system's queue of notifications set for a time to come.
@MainActor protocol LaterReminderTransport: AnyObject {
    func scheduled() async -> [String]
    func schedule(_ identifier: String, at date: Date, notification: DesktopMessageNotification) async throws
    func cancel(_ identifiers: [String])
}

/// Keeps the system's queue to Later's reminders still to come, for the account signed in, so each notifies at its
/// time even while the app is closed. A reminder another device sets is queued here too; one already due when this
/// device learns of it isn't, so it never notifies twice.
@MainActor final class LaterReminderSchedule {
    static let prefix = "later."
    private let transport: LaterReminderTransport
    /// The newest sync, the only one that changes the queue, and what it wants queued.
    private var newest = UUID()
    private var latest: Set<String> = []

    init(transport: LaterReminderTransport) { self.transport = transport }

    /// Queues what `list` has still to come for `accountID`, and withdraws everything else queued; a nil account,
    /// as when signed out or notifications are off, withdraws all. With `preview` on, `notification` reads what a
    /// reminder says; with it off the reminder is generic and the message is never read. A change to it rewrites
    /// every reminder queued.
    func sync(
        _ list: SavedMessages, accountID: String?, preview: Bool,
        notification: (SavedMessageReference) async -> DesktopMessageNotification?
    ) async {
        let wanted: [(String, SavedMessageReference, Date)] =
            accountID.map { account in
                list.reminders(after: Date()).compactMap { item in
                    item.remindAt.map {
                        let ms = Int64(($0.timeIntervalSince1970 * 1_000).rounded())
                        let shows = preview ? ".preview" : ".private"
                        return ("\(Self.prefix)\(account.utf8.count):\(account)\(item.id)@\(ms)\(shows)", item, $0)
                    }
                }
            } ?? []
        let sync = UUID()
        newest = sync
        latest = Set(wanted.map(\.0))
        let queued = Set(await transport.scheduled().filter { $0.hasPrefix(Self.prefix) })
        guard newest == sync else { return }
        transport.cancel(Array(queued.subtracting(wanted.map(\.0))))
        for (identifier, item, date) in wanted where !queued.contains(identifier) {
            let generic = accountID.flatMap {
                MatrixNotificationTarget(accountID: $0, roomID: item.roomID, eventID: item.eventID)
            }.map { DesktopMessageNotification(target: $0, title: "Slatrix", body: "Reminder", playSound: true) }
            guard !Task.isCancelled, let message = preview ? await notification(item) : generic, newest == sync,
                !Task.isCancelled
            else { return }
            try? await transport.schedule(identifier, at: date, notification: message)
            // A newer sync that read the queue before this landed couldn't withdraw it, so this one does.
            if !latest.contains(identifier) { transport.cancel([identifier]) }
        }
    }
}
