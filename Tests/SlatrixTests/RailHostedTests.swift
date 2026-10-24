import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The production rail in a real offscreen window; needs an awake display.
@MainActor
@Suite(
    .serialized, .tags(.hosted), .enabled(if: ProcessInfo.processInfo.environment["SLATRIX_HOSTED_UI_CHECKS"] != nil))
struct RailHostedTests {
    @Test("The rail fits a 900 pt window at 150% and scrolls only beyond", arguments: [(1.5, false), (2, true)])
    func fits(zoom: Double, scrolls: Bool) async throws {
        _ = NSApplication.shared
        let matrix = MatrixService()
        matrix.enterPreview()
        let metrics = Metrics(zoom: zoom)
        let hosting = NSHostingView(
            rootView: RootView(matrix: matrix).environmentObject(AppearanceStore()).environment(\.metrics, metrics))
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 1_440, height: 900),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }

        // The conversation list's scroll view sits right of the rail, so its presence means the rail has laid out.
        func scrollViews() -> [NSScrollView] {
            func collect(_ node: NSView) -> [NSScrollView] {
                (node as? NSScrollView).map { [$0] } ?? node.subviews.flatMap(collect)
            }
            return collect(hosting)
        }
        let laidOut = await eventually {
            hosting.layoutSubtreeIfNeeded()
            return scrollViews().contains { $0.convert($0.bounds, to: hosting).minX >= metrics.rail }
        }
        #expect(laidOut)
        let rail = scrollViews().filter { $0.convert($0.bounds, to: hosting).maxX <= metrics.rail }
        let overflows = rail.contains { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 0.5 }
        #expect(overflows == scrolls)
    }
}
