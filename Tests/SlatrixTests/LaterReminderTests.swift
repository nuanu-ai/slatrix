import Foundation
import Testing

@testable import Slatrix

/// Later's reminders against a fake of the system's notification queue.
@MainActor
struct LaterReminderTests {
    @MainActor private final class Queue: LaterReminderTransport {
        var queued: [String: (Date, DesktopMessageNotification)] = [:]
        /// Holds the next request on its way into the queue while armed.
        let arriving = Gate()
        var holdNextSubmission = false
        /// Every request that reached the queue, in order.
        var submitted: [String] = []
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
            if holdNextSubmission {
                holdNextSubmission = false
                await arriving.wait()
            }
            submitted.append(identifier)
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
        var read = false
        await schedule.sync(list, accountID: owner, preview: false) {
            read = true
            return notification($0, body: "Reminder: launch moves to Friday")
        }
        #expect(!read)
        #expect(queue.queued.values.map { [$0.1.title, $0.1.body] } == [["Slatrix", "Reminder"]])
    }

    @Test("A reminder still on its way into the queue at sign-out is withdrawn when it lands")
    func lateArrival() async {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages().reminding(
            roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
        queue.arriving.arm()
        queue.holdNextSubmission = true
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

    @Test(
        "A reminder an older build queued is rebuilt once, so it says what the preview setting says now",
        arguments: [true, false])
    func olderBuildRebuilt(preview: Bool) async throws {
        let queue = Queue()
        let due = Date(timeIntervalSince1970: 4_000_000_000)
        let list = SavedMessages().reminding(roomID: room, eventID: "$one", at: due, now: Date())
        let item = try #require(list.reminders(after: Date()).first)
        let excerpt = try #require(notification(item, body: "Reminder: the old excerpt"))
        // How builds before the preview marker named a reminder.
        queue.queued["later.18:@owner:example.org19:!design:example.org$one@4000000000000"] = (due, excerpt)
        await LaterReminderSchedule(transport: queue).sync(list, accountID: owner, preview: preview) {
            notification($0, body: "Reminder: launch moves to Friday")
        }
        #expect(queue.queued.values.map(\.1.body) == [preview ? "Reminder: launch moves to Friday" : "Reminder"])

        let rebuilt = queue.queued.keys.sorted()
        let submitted = queue.submitted
        await LaterReminderSchedule(transport: queue).sync(list, accountID: owner, preview: preview) {
            notification($0, body: "Reminder: launch moves to Friday")
        }
        #expect(queue.queued.keys.sorted() == rebuilt)
        #expect(queue.submitted == submitted)
    }

    @Test("A sync overtaken while it queues reads no further messages")
    func overtakenReadsNoMore() async {
        @MainActor final class Reads { var ids: [String] = [] }
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let list = SavedMessages()
            .reminding(roomID: room, eventID: "$one", at: Date().addingTimeInterval(600), now: Date())
            .reminding(roomID: room, eventID: "$two", at: Date().addingTimeInterval(1_200), now: Date())
        let reads = Reads()
        queue.arriving.arm()
        queue.holdNextSubmission = true
        let older = Task {
            await schedule.sync(list, accountID: owner, preview: true) {
                reads.ids.append($0.eventID)
                return notification($0, body: "Reminder: launch moves to Friday")
            }
        }
        #expect(await eventually { queue.arriving.isWaiting })
        await schedule.sync(list, accountID: owner, preview: false, notification: notification)
        queue.arriving.release()
        await older.value
        #expect(reads.ids.count == 1)
        #expect(queue.queued.values.map(\.1.body) == ["Reminder", "Reminder"])
    }
}
