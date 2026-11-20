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
    /// The banners still in Notification Center.
    func deliveredIdentifiers() async -> [String]
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
    /// Shown banners by their message's Activity key, oldest first, as many as Activity keeps.
    private var banners: [(key: String, identifier: String, roomID: String, eventID: String)] = []
    /// Messages whose banner is on its way. Deleting one takes it out, and its banner never stays.
    private var delivering = Set<String>()

    init(transport: DesktopNotificationTransport) { self.transport = transport }

    func useAccount(_ accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        clear()
    }

    func clear() {
        generation = UUID()
        banners = []
        transport.clear()
    }

    /// Takes back a deleted message's banner, shown or on its way.
    func withdraw(roomID: String, eventID: String) {
        let key = ActivityService.key(roomID: roomID, eventID: eventID)
        delivering.remove(key)
        for banner in banners where banner.key == key { transport.remove(banner.identifier) }
        banners.removeAll { $0.key == key }
    }

    /// Whether the message with Activity key `key` has a banner that wasn't taken back.
    func holds(_ key: String) -> Bool { banners.contains { $0.key == key } }

    /// The messages whose banners are still in Notification Center, newest first.
    func delivered() async -> [(roomID: String, eventID: String)] {
        let shown = Set(await transport.deliveredIdentifiers())
        return banners.reversed().filter { shown.contains($0.identifier) }.map { ($0.roomID, $0.eventID) }
    }

    /// `stillAnnounce` decides once the OS has answered, and nothing after it but the checks above can stop the alert,
    /// so a message the reader has seen by then goes quietly.
    @discardableResult func deliver(
        _ message: DesktopMessageNotification, stillAnnounce: () async -> Bool = { true }
    ) async throws -> Bool {
        guard message.target.accountID == accountID else { return false }
        let token = generation
        let key = message.target.eventID.map { ActivityService.key(roomID: message.target.roomID, eventID: $0) }
        if let key { delivering.insert(key) }
        defer { if let key { delivering.remove(key) } }
        func due() -> Bool {
            token == generation && message.target.accountID == accountID && !Task.isCancelled
                && key.map(delivering.contains) ?? true
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
        if let key, let eventID = message.target.eventID {
            banners.append((key, request.identifier, message.target.roomID, eventID))
            if banners.count > ActivityService.maximumItems { banners.removeFirst() }
        }
        return true
    }
}
