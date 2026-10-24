import Foundation
import UserNotifications

enum DesktopNotificationAuthorization: Hashable {
    case notDetermined, denied, authorized, provisional, unknown
    init(_ value: UNAuthorizationStatus) {
        switch value {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        @unknown default: self = .unknown
        }
    }
}

enum DesktopNotificationSetting: Hashable {
    case enabled, disabled, notSupported, unknown
    init(_ value: UNNotificationSetting) {
        switch value {
        case .enabled: self = .enabled
        case .disabled: self = .disabled
        case .notSupported: self = .notSupported
        @unknown default: self = .unknown
        }
    }
}

enum DesktopNotificationPreviews: Hashable {
    case always, whenAuthenticated, never, unknown
    init(_ value: UNShowPreviewsSetting) {
        switch value {
        case .always: self = .always
        case .whenAuthenticated: self = .whenAuthenticated
        case .never: self = .never
        @unknown default: self = .unknown
        }
    }
}

struct DesktopNotificationStatus: Hashable {
    let authorization: DesktopNotificationAuthorization
    let alerts: DesktopNotificationSetting
    let sounds: DesktopNotificationSetting
    let badges: DesktopNotificationSetting
    let previews: DesktopNotificationPreviews

    init(
        authorizationStatus: UNAuthorizationStatus, alertSetting: UNNotificationSetting,
        soundSetting: UNNotificationSetting, badgeSetting: UNNotificationSetting,
        showPreviewsSetting: UNShowPreviewsSetting
    ) {
        authorization = DesktopNotificationAuthorization(authorizationStatus)
        alerts = DesktopNotificationSetting(alertSetting)
        sounds = DesktopNotificationSetting(soundSetting)
        badges = DesktopNotificationSetting(badgeSetting)
        previews = DesktopNotificationPreviews(showPreviewsSetting)
    }

    init(_ settings: UNNotificationSettings) {
        self.init(
            authorizationStatus: settings.authorizationStatus, alertSetting: settings.alertSetting,
            soundSetting: settings.soundSetting, badgeSetting: settings.badgeSetting,
            showPreviewsSetting: settings.showPreviewsSetting)
    }
}
