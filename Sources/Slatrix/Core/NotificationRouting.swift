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
    var threadRootID: String? = nil

    /// The title and one-line text of a message, as the cases in `spec/notification-text.json` say.
    static func message(room: String, sender: String, direct: Bool, body: String, reply: Bool = false)
        -> (title: String, text: String)
    {
        let text = plain(reply ? withoutReplyFallback(body) : body)
        return direct ? (sender, text) : (room, "\(sender): \(text)")
    }

    private static let markers = [
        #"\*\*(.+?)\*\*"#, "__(.+?)__", "~~(.+?)~~", "`([^`]+)`",
        #"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, #"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// A reply's body opens with the quoted message, "> <@sender> …", and a blank line. Dropped before the body is cut
    /// to length, so a long quote can't push the reply out.
    static func withoutReplyFallback(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        if lines.first?.hasPrefix("> <") == true, let blank = lines.firstIndex(where: { !$0.hasPrefix(">") }),
            lines[blank].isEmpty
        {
            lines.removeFirst(blank + 1)
        }
        return lines.joined(separator: "\n")
    }

    private static func plain(_ body: String) -> String {
        let joined = body.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```")
        }
        .map { $0.hasPrefix(">") ? String($0.dropFirst()) : $0 }.joined(separator: " ")
        let text = markers.reduce(joined) { text, marker in
            marker.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

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
    /// The message banners still in Notification Center.
    func deliveredNotifications() async -> [DeliveredNotification]
}

struct DeliveredNotification {
    let identifier: String
    let target: MatrixNotificationTarget
    let date: Date
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
    /// Banners on their way, each by its message's Activity key. Deleting a message drops its entries, so their
    /// banners never stay.
    private var deliveries: [UUID: String] = [:]
    /// Whether a banner went up since the last clear; until one does, Notification Center holds none to take back.
    private var hasShown = false

    init(transport: DesktopNotificationTransport) { self.transport = transport }

    func useAccount(_ accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        clear()
    }

    func clear() {
        generation = UUID()
        hasShown = false
        transport.clear()
    }

    /// Takes back the banners of deleted messages, by Activity key: those on their way at once, those shown with one
    /// read of Notification Center.
    func withdraw(_ keys: Set<String>) async {
        deliveries = deliveries.filter { !keys.contains($0.value) }
        for banner in await shown() where keys.contains(Self.key(banner.target)) { transport.remove(banner.identifier) }
    }

    /// This account's message banners in Notification Center.
    func shown() async -> [DeliveredNotification] {
        guard hasShown else { return [] }
        let account = accountID
        return await transport.deliveredNotifications().filter { $0.target.accountID == account }
    }

    static func key(_ target: MatrixNotificationTarget) -> String {
        ActivityService.key(roomID: target.roomID, eventID: target.eventID ?? "")
    }

    /// `stillAnnounce` decides once the OS has answered, and nothing after it but the checks above can stop the alert,
    /// so a message the reader has seen by then goes quietly.
    @discardableResult func deliver(
        _ message: DesktopMessageNotification, stillAnnounce: () async -> Bool = { true }
    ) async throws -> Bool {
        guard message.target.accountID == accountID else { return false }
        let token = generation
        let delivery = UUID()
        deliveries[delivery] = Self.key(message.target)
        defer { deliveries[delivery] = nil }
        func due() -> Bool {
            token == generation && message.target.accountID == accountID && !Task.isCancelled
                && deliveries[delivery] != nil
        }
        let allowed: Result<Bool, Error>
        do { allowed = .success(try await transport.isAuthorized()) } catch { allowed = .failure(error) }
        // A seen message stays quiet, a failed permission check included.
        let announce = await stillAnnounce()
        guard due(), announce else { return false }
        guard try allowed.get() else { throw DesktopNotificationError.notificationsDisabled }
        let request = DesktopNotificationRequest(identifier: UUID().uuidString, message: message)
        do { try await transport.add(request) } catch {
            guard due() else { return false }
            throw error
        }
        guard due() else {
            transport.remove(request.identifier)
            return false
        }
        hasShown = true
        return true
    }
}
