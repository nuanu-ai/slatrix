import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
@Suite("Themes")
struct ThemeTests {
    // capability: app.appearance
    @Test("Text stays readable on the window and the sidebar in both themes", arguments: [false, true])
    func readable(dark: Bool) {
        let colors = AppColors(dark: dark, accent: AppColors.resolve(.systemBlue, dark: dark))
        // WCAG AA for text.
        for surface in [colors.canvas, colors.sidebar] {
            #expect(contrast(colors.textPrimary, surface) >= 4.5)
            #expect(contrast(colors.textSecondary, surface) >= 4.5)
        }
        #expect(contrast(colors.accent, colors.canvas) >= 4.5)
    }

    private func contrast(_ first: Color, _ second: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722
                * linear(rgb.blueComponent)
        }
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
