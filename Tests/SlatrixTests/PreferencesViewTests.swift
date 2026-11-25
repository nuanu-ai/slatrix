import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
struct PreferencesViewTests {
    @Test("Opening Preferences on Appearance defers reading launch-at-login until the Advanced tab opens")
    func defersOpenAtLoginReadUntilAdvancedTab() async {
        let reads = Recorder<Bool>()
        let matrix = MatrixService.scratch()
        let appearance = AppearanceStore()
        func makeView(tab: PreferencesView.Tab) -> some View {
            PreferencesView(
                matrix: matrix, onClose: {}, onLogout: {}, onRecovery: {}, onEditProfile: {}, tab: tab,
                readOpenAtLogin: {
                    reads.append(true)
                    return true
                }
            ).environmentObject(appearance)
        }

        let window = offscreenWindow(NSSize(width: 900, height: 700))
        defer {
            window.contentView = nil
            window.close()
        }
        let appearanceHost = NSHostingView(rootView: makeView(tab: .appearance))
        appearanceHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = appearanceHost
        appearanceHost.layoutSubtreeIfNeeded()
        await drainMainActor()
        #expect(reads.all.isEmpty)

        let advancedHost = NSHostingView(rootView: makeView(tab: .advanced))
        advancedHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = advancedHost
        advancedHost.layoutSubtreeIfNeeded()
        #expect(await eventually { reads.all.count == 1 })
    }
}
