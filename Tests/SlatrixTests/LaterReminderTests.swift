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

    @Test("A reminder an older build queued is rebuilt once, so it says what the preview setting says now")
    func olderBuildRebuilt() async throws {
        let queue = Queue()
        let schedule = LaterReminderSchedule(transport: queue)
        let due = Date(timeIntervalSince1970: 4_000_000_000)
        let list = SavedMessages().reminding(roomID: room, eventID: "$one", at: due, now: Date())
        let item = try #require(list.reminders(after: Date()).first)
        let generic = try #require(notification(item))
        // How builds before the preview marker named a reminder.
        queue.queued["later.18:@owner:example.org19:!design:example.org$one@4000000000000"] = (due, generic)
        await schedule.sync(list, accountID: owner, preview: true) {
            notification($0, body: "Reminder: launch moves to Friday")
        }
        #expect(queue.queued.values.map(\.1.body) == ["Reminder: launch moves to Friday"])
    }
}

/// Whose reminders the queue holds while the app finds out who is signed in.
struct LaterReminderAudienceTests {
    struct Case: CustomTestStringConvertible, Sendable {
        var name: String
        var restoring = false
        var status = ConnectionStatus.ready
        var user: String? = "@owner:example.org"
        var laterLoaded = true
        var notifications = true
        var preview = false
        var expected: LaterReminderSchedule.Audience
        var testDescription: String { name }
    }

    @Test(
        "Reminders sync only for whoever is known to be signed in, and stay queued while that's unknown",
        arguments: [
            Case(name: "Still restoring", restoring: true, status: .connecting, user: nil, expected: .unknown),
            Case(name: "Restore failed with no one signed in", status: .error, user: nil, expected: .unknown),
            Case(name: "Signed in, Later not loaded yet", laterLoaded: false, expected: .unknown),
            Case(name: "Signed out", status: .signedOut, user: nil, expected: .nobody),
            Case(name: "Notifications off", notifications: false, expected: .nobody),
            Case(name: "The sample workspace", user: "preview.you", preview: true, expected: .nobody),
            Case(name: "Signed in and loaded", expected: .account("@owner:example.org")),
        ])
    func audience(_ spec: Case) {
        #expect(
            LaterReminderSchedule.audience(
                restoring: spec.restoring, status: spec.status, userID: spec.user, laterLoaded: spec.laterLoaded,
                notifications: spec.notifications, preview: spec.preview) == spec.expected)
    }
}
