import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
@Suite("Themes")
struct ThemeTests {
    // capability: app.appearance
    // capability: app.themes
    @Test(
        "Text stays readable wherever it sits, in every theme, light and dark",
        arguments: ColorTheme.allCases, [false, true])
    func readable(theme: ColorTheme, dark: Bool) {
        let colors = AppColors(dark: dark, accent: AppColors.resolve(.systemBlue, dark: dark), theme: theme)
        // WCAG AA for text.
        let surfaces = [
            colors.canvas, colors.sidebar, colors.overlay, colors.control,
            over(colors.selection, colors.sidebar), over(colors.code, colors.canvas),
        ]
        for surface in surfaces {
            #expect(contrast(colors.textPrimary, surface) >= 4.5)
            #expect(contrast(colors.textSecondary, surface) >= 4.5)
        }
        #expect(contrast(colors.accent, colors.canvas) >= 4.5)
        #expect(contrast(colors.mentionYouText, over(colors.mentionYouFill, colors.canvas)) >= 4.5)
        // Where a message crosses a doodle, and under the pointer too.
        let doodled = over(colors.wallpaperDoodle, colors.canvas)
        #expect(contrast(colors.textSecondary, over(colors.hover, doodled)) >= 4.5)
        #expect(contrast(colors.accent, doodled) >= 4.5)
    }

    // capability: app.themes
    @Test(
        "The sidebar's text stays readable on the frame, through the gradient and over any desktop",
        arguments: ColorTheme.allCases, [false, true])
    func readableOnFrame(theme: ColorTheme, dark: Bool) {
        let colors = AppColors(dark: dark, theme: theme)
        let sidebar = colors.onFrame
        // A translucent frame lets the desktop through, so it is read over the darkest and lightest one.
        let frames = [colors.frame, colors.frameEnd].flatMap { [over($0, .black), over($0, .white)] }
        for frame in frames {
            for surface in [frame, over(sidebar.hover, frame), over(sidebar.selection, frame)] {
                #expect(contrast(sidebar.textPrimary, surface) >= 4.5)
                #expect(contrast(sidebar.textSecondary, surface) >= 4.5)
            }
        }
    }

    // capability: app.themes
    @Test(
        "The window gradient visibly shifts a colored frame, light and dark",
        arguments: ColorTheme.allCases.filter(\.framed), [false, true])
    func gradientShows(theme: ColorTheme, dark: Bool) throws {
        let colors = AppColors(dark: dark, theme: theme)
        // Glass has no gradient: the desktop shows through its frame instead.
        guard !colors.translucentFrame else { return }
        // About Jade's light frame, the faintest that still reads as a gradient across the window.
        #expect(try difference(colors.frame, colors.frameEnd) >= 24)
    }

    /// How far apart two colors look: CIE76's distance in Lab.
    private func difference(_ first: Color, _ second: Color) throws -> Double {
        let lab = try #require(CGColorSpace(name: CGColorSpace.genericLab))
        func components(_ color: Color) throws -> [CGFloat] {
            try #require(NSColor(color).cgColor.converted(to: lab, intent: .defaultIntent, options: nil)?.components)
        }
        let (first, second) = (try components(first), try components(second))
        return sqrt(zip(first, second).prefix(3).map { Double(($0 - $1) * ($0 - $1)) }.reduce(0, +))
    }

    /// A translucent fill as it draws on an opaque surface.
    private func over(_ top: Color, _ bottom: Color) -> Color {
        let (top, bottom) = (NSColor(top).usingColorSpace(.sRGB)!, NSColor(bottom).usingColorSpace(.sRGB)!)
        let alpha = top.alphaComponent
        func mix(_ a: CGFloat, _ b: CGFloat) -> Double { Double(a * alpha + b * (1 - alpha)) }
        return Color(
            .sRGB, red: mix(top.redComponent, bottom.redComponent),
            green: mix(top.greenComponent, bottom.greenComponent),
            blue: mix(top.blueComponent, bottom.blueComponent))
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
