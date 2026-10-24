import Foundation

struct MatrixNotificationTarget: Hashable {
    let accountID: String
    let roomID: String
    let eventID: String?

    init?(accountID: String, roomID: String, eventID: String? = nil) {
        guard Self.valid(accountID, prefix: "@"), accountID.contains(":"), Self.valid(roomID, prefix: "!"),
            eventID.map({ Self.valid($0, prefix: "$") }) ?? true
        else { return nil }
        self.accountID = accountID
        self.roomID = roomID
        self.eventID = eventID
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["slatrixVersion"] as? String == "1",
            let account = userInfo["accountID"] as? String, let room = userInfo["roomID"] as? String,
            userInfo["eventID"] == nil || userInfo["eventID"] is String
        else { return nil }
        self.init(accountID: account, roomID: room, eventID: userInfo["eventID"] as? String)
    }

    var userInfo: [AnyHashable: Any] {
        var value: [AnyHashable: Any] = ["slatrixVersion": "1", "accountID": accountID, "roomID": roomID]
        if let eventID { value["eventID"] = eventID }
        return value
    }

    private static func valid(_ value: String, prefix: String) -> Bool { MatrixID.isValid(value, sigil: prefix) }
}

struct DesktopMessageNotification {
    var target: MatrixNotificationTarget
    var title: String
    var body: String
    var playSound: Bool

    func applyingPreviewPreference(_ enabled: Bool) -> Self {
        guard !enabled else { return self }
        var hidden = self
        hidden.title = "Slatrix"
        hidden.body = "You have a new message"
        return hidden
    }
}

struct DesktopNotificationRequest {
    let identifier: String
    let message: DesktopMessageNotification
}

@MainActor protocol DesktopNotificationTransport: AnyObject {
    func isAuthorized() async throws -> Bool
    func add(_ request: DesktopNotificationRequest) async throws
    func remove(_ identifier: String)
    func clear()
}

enum DesktopNotificationError: LocalizedError {
    case notificationsDisabled
    var errorDescription: String? {
        "Notifications are disabled for Slatrix. You can enable them in System Settings → Notifications."
    }
}

/// Permission checks and OS submission can finish after an account or privacy preference changes.
@MainActor final class DesktopNotificationDelivery {
    private let transport: DesktopNotificationTransport
    private(set) var accountID: String?
    private var generation = UUID()

    init(transport: DesktopNotificationTransport) { self.transport = transport }

    func useAccount(_ accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        clear()
    }

    func clear() {
        generation = UUID()
        transport.clear()
    }

    @discardableResult func deliver(_ message: DesktopMessageNotification) async throws -> Bool {
        guard message.target.accountID == accountID else { return false }
        let token = generation
        let allowed: Bool
        do { allowed = try await transport.isAuthorized() } catch {
            guard token == generation, message.target.accountID == accountID, !Task.isCancelled else { return false }
            throw error
        }
        guard token == generation, message.target.accountID == accountID, !Task.isCancelled else { return false }
        guard allowed else { throw DesktopNotificationError.notificationsDisabled }
        let request = DesktopNotificationRequest(identifier: UUID().uuidString, message: message)
        do { try await transport.add(request) } catch {
            guard token == generation, message.target.accountID == accountID, !Task.isCancelled else { return false }
            throw error
        }
        guard token == generation, message.target.accountID == accountID, !Task.isCancelled else {
            transport.remove(request.identifier)
            return false
        }
        return true
    }
}
