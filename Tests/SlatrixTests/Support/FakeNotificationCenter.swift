import Foundation

@testable import Slatrix

/// The OS notification center, which allows alerts, records the events it was handed and shows each banner until it
/// is removed.
@MainActor final class FakeNotificationCenter: DesktopNotificationTransport {
    private(set) var asked = 0
    private(set) var added: [String?] = []
    private(set) var shown: [DeliveredNotification] = []
    func isAuthorized() async throws -> Bool {
        asked += 1
        return true
    }
    func add(_ request: DesktopNotificationRequest) async throws {
        added.append(request.message.target.eventID)
        shown.append(
            DeliveredNotification(
                identifier: request.identifier, target: request.message.target,
                date: Date(timeIntervalSince1970: Double(added.count))))
    }
    func remove(_ identifier: String) { shown.removeAll { $0.identifier == identifier } }
    func clear() { shown = [] }
    func deliveredNotifications() async -> [DeliveredNotification] { shown }
}
