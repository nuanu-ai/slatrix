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

    /// Whose reminders the queue holds: nobody's withdraws them all. Unknown keeps the queue, except that with
    /// previews off it keeps only reminders that hide the message.
    enum Audience: Equatable {
        case unknown, nobody
        case account(String)
    }

    /// Still restoring, a restore that failed, or drafts and Later still opening is unknown, not signed out, so a
    /// reminder due meanwhile isn't withdrawn. Drafts that failed to open leave Later to the server, so that's known.
    nonisolated static func audience(
        restoring: Bool, status: ConnectionStatus, userID: String?, localReady: Bool, localFailed: Bool,
        notifications: Bool, preview: Bool
    ) -> Audience {
        if !notifications || preview { return .nobody }
        if restoring { return .unknown }
        guard let userID else { return status == .signedOut ? .nobody : .unknown }
        return localReady || localFailed ? .account(userID) : .unknown
    }

    /// Queues what `list` has still to come for the audience's account, and withdraws everything else queued;
    /// nobody, as when signed out or notifications are off, withdraws all. With `preview` on, `notification` reads what a
    /// reminder says; with it off the reminder is generic and the message is never read. A change to it rewrites
    /// every reminder queued.
    func sync(
        _ list: SavedMessages, audience: Audience, preview: Bool,
        notification: (SavedMessageReference) async -> DesktopMessageNotification?
    ) async {
        if audience == .unknown && preview { return }
        let accountID: String? = if case .account(let id) = audience { id } else { nil }
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
        if audience == .unknown { latest = queued.filter { $0.hasSuffix(".private") } }
        transport.cancel(Array(queued.subtracting(latest)))
        for (identifier, item, date) in wanted where !queued.contains(identifier) {
            let generic = accountID.flatMap {
                MatrixNotificationTarget(accountID: $0, roomID: item.roomID, eventID: item.eventID)
            }.map { DesktopMessageNotification(target: $0, title: "Slatrix", body: "Reminder", playSound: true) }
            guard !Task.isCancelled, newest == sync, let message = preview ? await notification(item) : generic,
                newest == sync, !Task.isCancelled
            else { return }
            try? await transport.schedule(identifier, at: date, notification: message)
            // A newer sync that read the queue before this landed couldn't withdraw it, so this one does.
            if !latest.contains(identifier) { transport.cancel([identifier]) }
        }
    }
}
