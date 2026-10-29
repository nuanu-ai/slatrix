import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
@Suite("Themes")
struct ThemeTests {
    // capability: app.appearance
    @Test(
        "A theme picked before Slack's names came in stays picked",
        arguments: zip(["slate", "aubergine", "ocean", "forest"], [SidebarPalette.gray, .aubergine, .lagoon, .jade]))
    func savedThemeStays(saved: String, theme: SidebarPalette) {
        #expect(SidebarPalette(rawValue: saved) == theme)
    }

    @Test("Every theme keeps the sidebar and rail readable", arguments: SidebarPalette.allCases, [false, true])
    func readable(palette: SidebarPalette, dark: Bool) {
        let colors = AppColors(dark: dark, palette: palette)
        // WCAG AA for text.
        #expect(contrast(colors.selectionText, colors.selectionStrong) >= 4.5)
        #expect(contrast(colors.textPrimary, colors.selection) >= 4.5)
        #expect(contrast(colors.textSecondary, colors.frame) >= 4.5)
        #expect(contrast(colors.textSecondary, colors.sidebar) >= 4.5)
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
