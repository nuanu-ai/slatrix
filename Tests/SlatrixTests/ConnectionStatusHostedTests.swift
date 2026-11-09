import AppKit
import SwiftUI
import Testing
import Vision

@testable import Slatrix

@MainActor
@Suite(.tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct ConnectionStatusHostedTests {
    // capability: app.connection-status
    @Test("Account settings show the live connection, including reconnecting")
    func accountConnectionStatus() async {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.user = ChatUser(id: "@alex:example.org", name: "Alex")
        matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        let host = NSHostingView(
            rootView: PreferencesView(
                matrix: matrix, onClose: {}, onLogout: {},
                onRecovery: {}, onEditProfile: {}, tab: .account
            ).environmentObject(AppearanceStore()))
        let window = offscreenWindow(NSSize(width: 848, height: 600))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        #expect(
            await eventually(timeout: .milliseconds(250)) {
                renderedText(host).contains("Connected")
            })
        matrix.applyConnection(
            MatrixConnectionFeedback(
                state: .offline, isRetrying: false, canRetry: true,
                errorMessage: "Reconnecting…"))
        #expect(
            await eventually(timeout: .milliseconds(250)) {
                let text = renderedText(host)
                return text.contains("Reconnecting") && !text.contains("Connected")
            })
    }

    private func renderedText(_ host: NSView) -> String {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "" }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }
}
