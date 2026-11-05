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

    init(transport: LaterReminderTransport) { self.transport = transport }

    /// Queues what `list` has still to come for `accountID`, and withdraws everything else queued; a nil account,
    /// as when signed out or notifications are off, withdraws all. `notification` reads what a reminder says.
    func sync(
        _ list: SavedMessages, accountID: String?,
        notification: (SavedMessageReference) async -> DesktopMessageNotification?
    ) async {
        let wanted: [(String, SavedMessageReference, Date)] =
            accountID.map { account in
                list.reminders(after: Date()).compactMap { item in
                    item.remindAt.map {
                        let ms = Int64(($0.timeIntervalSince1970 * 1_000).rounded())
                        return ("\(Self.prefix)\(account.utf8.count):\(account)\(item.id)@\(ms)", item, $0)
                    }
                }
            } ?? []
        let queued = Set(await transport.scheduled().filter { $0.hasPrefix(Self.prefix) })
        transport.cancel(Array(queued.subtracting(wanted.map(\.0))))
        for (identifier, item, date) in wanted where !queued.contains(identifier) {
            guard !Task.isCancelled, let message = await notification(item), !Task.isCancelled else { return }
            try? await transport.schedule(identifier, at: date, notification: message)
        }
    }
}
