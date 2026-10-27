import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
struct TooltipTests {
    /// WCAG relative luminance.
    private func luminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        func linear(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.040_45 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }

    @Test(
        "A tooltip is a dark bubble with light text in both themes, darker than the conversation in dark mode",
        arguments: [false, true])
    func darkBubble(dark: Bool) {
        let colors = AppColors(dark: dark, palette: .slate)
        let bubble = luminance(colors.tooltip)
        #expect(bubble < luminance(colors.canvas))
        // WCAG AAA for small text.
        #expect((luminance(colors.onTooltip) + 0.05) / (bubble + 0.05) >= 7)
    }

    private func size(_ text: String, zoom: CGFloat) -> NSSize {
        NSHostingView(
            rootView: Tooltip(text).environmentObject(AppearanceStore()).environment(\.metrics, Metrics(zoom: zoom))
        ).fittingSize
    }

    @Test("A long tooltip wraps at its width; a short one stays one line as wide as its words", arguments: [1.0, 1.5])
    func wraps(zoom: CGFloat) {
        let m = Metrics(zoom: zoom)
        let short = size("Alice reacted with :+1:", zoom: zoom)
        let long = size(
            "Alice, Bob, Carol, Dmitry, Eve, Frank, Grace, Heidi, Ivan, Judy and 12 others reacted with :+1:",
            zoom: zoom)
        #expect(short.width < m.tooltipText)
        #expect(long.width <= m.tooltipText + 2 * m.sp8)
        #expect(long.height > short.height)
    }
}
