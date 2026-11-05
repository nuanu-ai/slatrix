import Foundation
import Testing

@testable import Slatrix

/// Later's reminders against a fake of the system's notification queue.
@MainActor
struct LaterReminderTests {
    @MainActor private final class Queue: LaterReminderTransport {
        var queued: [String: (Date, DesktopMessageNotification)] = [:]
        func scheduled() async -> [String] { Array(queued.keys) }
        func schedule(_ identifier: String, at date: Date, notification: DesktopMessageNotification) async throws {
            queued[identifier] = (date, notification)
        }
        func cancel(_ identifiers: [String]) { for identifier in identifiers { queued[identifier] = nil } }
    }

    private let owner = "@owner:example.org"
    private let room = "!design:example.org"

    private func notification(_ item: SavedMessageReference) -> DesktopMessageNotification? {
        MatrixNotificationTarget(accountID: owner, roomID: item.roomID, eventID: item.eventID).map {
            DesktopMessageNotification(target: $0, title: "#design", body: "Reminder", playSound: true)
        }
    }

    // capability: later.remind
    @Test("A reminder to come notifies at its time and opens its message; completing it withdraws the notification")
    func queuesAndWithdraws() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let due = Date().addingTimeInterval(3_600)
        var list = SavedMessages().reminding(roomID: room, eventID: "$one", at: due, now: Date())
            .reminding(roomID: room, eventID: "$past", at: Date().addingTimeInterval(-60), now: Date())
        await schedule.sync(list, accountID: owner, notification: notification)
        #expect(queue.queued.values.map(\.1.target.eventID) == ["$one"])
        #expect(abs((queue.queued.values.first?.0 ?? .distantPast).timeIntervalSince(due)) < 0.001)

        list = list.changing(roomID: room, eventID: "$one", to: .completed, at: Date())
        await schedule.sync(list, accountID: owner, notification: notification)
        #expect(queue.queued.isEmpty)
    }

    @Test("A reminder moved to another time notifies only at the new one")
    func moved() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        await schedule.sync(list, accountID: owner, notification: notification)
        let later = Date().addingTimeInterval(7_200)
        await schedule.sync(
            list.reminding(roomID: room, eventID: "$one", at: later, now: Date()), accountID: owner,
            notification: notification)
        #expect(queue.queued.values.map { abs($0.0.timeIntervalSince(later)) < 0.001 } == [true])
    }

    @Test("Signing out, or turning notifications off, withdraws every reminder")
    func signOut() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        await schedule.sync(list, accountID: owner, notification: notification)
        #expect(!queue.queued.isEmpty)
        await schedule.sync(list, accountID: nil, notification: notification)
        #expect(queue.queued.isEmpty)
    }
}
