import AppKit
import Combine
import ServiceManagement
import UserNotifications

extension Notification.Name {
    static let menuAction = Notification.Name("ai.nuanu.slatrix.menuAction")
}

@MainActor
final class PlatformIntegration: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PlatformIntegration()
    @Published private(set) var pendingNotification: MatrixNotificationTarget?
    private var notificationAccountConfigured = false
    private lazy var delivery = DesktopNotificationDelivery(
        transport: SystemDesktopNotificationTransport(center: notificationCenter))

    enum PlatformError: LocalizedError {
        case unsupportedLink
        case cannotOpenLink
        case appBundleRequired
        case loginApprovalRequired

        var errorDescription: String? {
            switch self {
            case .unsupportedLink: return "This kind of link can’t be opened."
            case .cannotOpenLink: return "Couldn’t open this link."
            case .appBundleRequired: return "Open the built Slatrix.app to use macOS notifications and launch at login."
            case .loginApprovalRequired:
                return
                    "macOS requires approval for Slatrix in System Settings → General → Login Items before it can open at login."
            }
        }
    }

    private var notificationCenter: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    private override init() {
        super.init()
        notificationCenter?.delegate = self
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    var openAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    var conversationWindowIsVisible: Bool {
        NSApp.isActive
            && NSApp.windows.contains {
                $0.frameAutosaveName == "SlatrixMainWindow" && $0.isVisible && !$0.isMiniaturized
                    && $0.occlusionState.contains(.visible) && $0.attachedSheet == nil
            }
    }

    func setOpenAtLogin(_ enabled: Bool) throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else { throw PlatformError.appBundleRequired }
        if enabled {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval { throw PlatformError.loginApprovalRequired }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func requestNotificationPermission() async throws -> Bool {
        guard let center = notificationCenter else { throw PlatformError.appBundleRequired }
        return try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func notificationStatus() async throws -> DesktopNotificationStatus {
        try Task.checkCancellation()
        guard let center = notificationCenter else { throw PlatformError.appBundleRequired }
        let settings = await center.notificationSettings()
        try Task.checkCancellation()
        return DesktopNotificationStatus(settings)
    }

    func setNotificationAccount(_ accountID: String?) {
        if !notificationAccountConfigured && accountID == nil { delivery.clear() }
        notificationAccountConfigured = true
        delivery.useAccount(accountID)
        if pendingNotification?.accountID != accountID { pendingNotification = nil }
    }

    func notify(_ message: DesktopMessageNotification) async throws { try await delivery.deliver(message) }

    func consumeNotification(_ target: MatrixNotificationTarget) {
        if pendingNotification == target { pendingNotification = nil }
    }

    func setBadge(_ count: Int) {
        let count = max(0, count)
        NSApp.dockTile.badgeLabel = count > 0 ? (count > 999 ? "999+" : String(count)) : nil
    }

    func clearNotifications() {
        delivery.clear()
        setBadge(0)
    }

    func clearNotificationPreviews() { delivery.clear() }

    func activate() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !$0.isSheet }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }

    static func isSafeExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
            url.user == nil, url.password == nil,
            url.absoluteString.rangeOfCharacter(from: .controlCharacters) == nil
        else { return false }
        if scheme == "mailto" { return !url.path.isEmpty }
        return !(url.host ?? "").isEmpty
    }

    func openExternal(_ url: URL) throws {
        guard Self.isSafeExternalURL(url) else { throw PlatformError.unsupportedLink }
        guard NSWorkspace.shared.open(url) else { throw PlatformError.cannotOpenLink }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let target = MatrixNotificationTarget(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            completionHandler(target?.accountID == self.delivery.accountID && target != nil ? [.banner, .sound] : [])
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let target = MatrixNotificationTarget(userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            self.activate()
            if let target, !self.notificationAccountConfigured || target.accountID == self.delivery.accountID {
                self.pendingNotification = target
            }
            completionHandler()
        }
    }
}

@MainActor private final class SystemDesktopNotificationTransport: DesktopNotificationTransport {
    let center: UNUserNotificationCenter?
    init(center: UNUserNotificationCenter?) { self.center = center }
    func isAuthorized() async throws -> Bool {
        guard let center else { throw PlatformIntegration.PlatformError.appBundleRequired }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
    func add(_ request: DesktopNotificationRequest) async throws {
        guard let center else { throw PlatformIntegration.PlatformError.appBundleRequired }
        let message = request.message
        let content = UNMutableNotificationContent()
        content.title = String(message.title.prefix(256))
        content.body = String(message.body.prefix(4096))
        content.sound = message.playSound ? .default : nil
        content.userInfo = message.target.userInfo
        content.threadIdentifier =
            "\(message.target.accountID.utf8.count):\(message.target.accountID)\(message.target.roomID)"
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }
    func remove(_ identifier: String) {
        center?.removePendingNotificationRequests(withIdentifiers: [identifier])
        center?.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    func clear() {
        center?.removeAllDeliveredNotifications()
        center?.removeAllPendingNotificationRequests()
    }
}
