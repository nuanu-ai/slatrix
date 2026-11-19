import Foundation
import Testing

@testable import Slatrix

/// Later's reminders against a fake of the system's notification queue.
@MainActor
struct LaterReminderTests {
    @MainActor private final class Queue: LaterReminderTransport {
        var queued: [String: (Date, DesktopMessageNotification)] = [:]
        /// Holds a request on its way into the queue while armed.
        let arriving = Gate()
        /// Holds the next read of the queue, with what it read, while armed.
        let reading = Gate()
        var holdNextRead = false
        func scheduled() async -> [String] {
            let keys = Array(queued.keys)
            if holdNextRead {
                holdNextRead = false
                await reading.wait()
            }
            return keys
        }
        func schedule(_ identifier: String, at date: Date, notification: DesktopMessageNotification) async throws {
            await arriving.wait()
            queued[identifier] = (date, notification)
        }
        func cancel(_ identifiers: [String]) { for identifier in identifiers { queued[identifier] = nil } }
    }

    private let owner = "@owner:example.org"
    private let room = "!design:example.org"

    private func notification(_ item: SavedMessageReference) -> DesktopMessageNotification? {
        notification(item, body: "Reminder")
    }
    private func notification(_ item: SavedMessageReference, body: String) -> DesktopMessageNotification? {
        MatrixNotificationTarget(accountID: owner, roomID: item.roomID, eventID: item.eventID).map {
            DesktopMessageNotification(target: $0, title: "#design", body: body, playSound: true)
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
        await schedule.sync(list, accountID: owner, preview: true, notification: notification)
        #expect(queue.queued.values.map(\.1.target.eventID) == ["$one"])
        #expect(abs((queue.queued.values.first?.0 ?? .distantPast).timeIntervalSince(due)) < 0.001)

        list = list.changing(roomID: room, eventID: "$one", to: .completed, at: Date())
        await schedule.sync(list, accountID: owner, preview: true, notification: notification)
        #expect(queue.queued.isEmpty)
    }

    @Test("A reminder moved to another time notifies only at the new one")
    func moved() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        await schedule.sync(list, accountID: owner, preview: true, notification: notification)
        let later = Date().addingTimeInterval(7_200)
        await schedule.sync(
            list.reminding(roomID: room, eventID: "$one", at: later, now: Date()), accountID: owner, preview: true,
            notification: notification)
        #expect(queue.queued.values.map { abs($0.0.timeIntervalSince(later)) < 0.001 } == [true])
    }

    @Test("Signing out, or turning notifications off, withdraws every reminder")
    func signOut() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        await schedule.sync(list, accountID: owner, preview: true, notification: notification)
        #expect(!queue.queued.isEmpty)
        await schedule.sync(list, accountID: nil, preview: true, notification: notification)
        #expect(queue.queued.isEmpty)
    }

    @Test("Turning message previews off rewrites a queued reminder without the message")
    func previewsOff() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        await schedule.sync(list, accountID: owner, preview: true) {
            notification($0, body: "Reminder: launch moves to Friday")
        }
        await schedule.sync(list, accountID: owner, preview: false) { notification($0) }
        #expect(queue.queued.values.map(\.1.body) == ["Reminder"])
    }

    @Test("A reminder still on its way into the queue at sign-out is withdrawn when it lands")
    func lateArrival() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        queue.arriving.arm()
        let signedIn = Task { await schedule.sync(list, accountID: owner, preview: true, notification: notification) }
        #expect(await eventually { queue.arriving.isWaiting })
        signedIn.cancel()
        await schedule.sync(list, accountID: nil, preview: true, notification: notification)
        queue.arriving.release()
        await signedIn.value
        #expect(queue.queued.isEmpty)
    }

    @Test("A sync overtaken by a newer one leaves the queue as the newer one left it")
    func overtaken() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        await schedule.sync(list, accountID: owner, preview: true, notification: notification)
        queue.reading.arm()
        queue.holdNextRead = true
        let previewsOff = Task {
            await schedule.sync(list, accountID: owner, preview: false, notification: notification)
        }
        #expect(await eventually { queue.reading.isWaiting })
        previewsOff.cancel()
        await schedule.sync(list, accountID: owner, preview: true, notification: notification)
        let kept = queue.queued.keys.sorted()
        queue.reading.release()
        await previewsOff.value
        #expect(kept.count == 1)
        #expect(queue.queued.keys.sorted() == kept)
    }
}
