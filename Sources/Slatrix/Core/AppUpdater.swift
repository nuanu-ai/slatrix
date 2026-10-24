import Foundation
import Sparkle

/// Sparkle checks every hour, downloads in the background and installs when Slatrix quits. Instead of alerts it
/// raises `updateAvailable`, which the title bar shows as the Update pill; the pill opens Sparkle's update window.
@MainActor final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var updateAvailable = false
    private var installsOnQuit = false
    private var controller: SPUStandardUpdaterController?

    private override init() {
        super.init()
        // A `swift run` binary has no app bundle to replace, and Sparkle alerts when it cannot start.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var canCheckForUpdates: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}

extension AppUpdater: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installsOnQuit = true
        updateAvailable = true
        return false
    }
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate { updateAvailable = true }
    }

    // A dismissed reminder returns on Sparkle's schedule; a downloaded update still installs on quit.
    func standardUserDriverWillFinishUpdateSession() { updateAvailable = installsOnQuit }
}
