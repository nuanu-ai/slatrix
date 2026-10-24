import Testing
import UserNotifications

@testable import Slatrix

struct DesktopNotificationStatusTests {
    @Test("Provisional authorization stays quiet: no banners, sounds or previews are promised")
    func provisionalIsQuiet() {
        let status = DesktopNotificationStatus(
            authorizationStatus: .provisional, alertSetting: .disabled, soundSetting: .disabled,
            badgeSetting: .enabled, showPreviewsSetting: .never)
        #expect(status.authorization == .provisional)
        #expect(status.alerts == .disabled && status.sounds == .disabled && status.previews == .never)
    }

    @Test("Disabled and unsupported capabilities are not reported as enabled")
    func capabilitiesStayDistinct() {
        #expect(DesktopNotificationSetting(.disabled) == .disabled)
        #expect(DesktopNotificationSetting(.notSupported) == .notSupported)
    }

    @Test("A status value macOS adds later is reported as unknown, never as allowed")
    func futureValuesAreUnknown() throws {
        #expect(DesktopNotificationAuthorization(try #require(UNAuthorizationStatus(rawValue: 10_000))) == .unknown)
        #expect(DesktopNotificationSetting(try #require(UNNotificationSetting(rawValue: 10_000))) == .unknown)
        #expect(DesktopNotificationPreviews(try #require(UNShowPreviewsSetting(rawValue: 10_000))) == .unknown)
    }
}
