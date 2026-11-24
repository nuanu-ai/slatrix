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
            colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard, colors.sidebar, colors.overlay,
            colors.control, over(colors.selection, colors.sidebar), over(colors.code, colors.canvas),
        ]
        for surface in surfaces {
            #expect(contrast(colors.textPrimary, surface) >= 4.5)
            #expect(contrast(colors.textSecondary, surface) >= 4.5)
        }
        for surface in [
            colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard, colors.overlay, colors.control,
        ] {
            #expect(contrast(colors.textTertiary, surface) >= 4.5, "\(theme) dark=\(dark) textTertiary")
        }
        #expect(contrast(colors.onAccent, colors.accentFill) >= 4.5, "\(theme) dark=\(dark) onAccent/accentFill")
        #expect(
            contrast(colors.onAccent, colors.destructiveFill) >= 4.5, "\(theme) dark=\(dark) onAccent/destructiveFill")
        for surface in [colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard, colors.overlay] {
            #expect(contrast(colors.destructive, surface) >= 4.5, "\(theme) dark=\(dark) destructive text")
        }
        for surface in [colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard] {
            #expect(contrast(colors.warning, surface) >= 4.5, "\(theme) dark=\(dark) warning")
            #expect(contrast(colors.success, surface) >= 4.5, "\(theme) dark=\(dark) success")
        }
        #expect(contrast(colors.accent, colors.canvas) >= 4.5)
        #expect(contrast(colors.mentionText, over(colors.mentionFill, colors.canvas)) >= 4.5)
        // Own mentions use warm amber so they stand apart from links and other mentions, readable even on highlighted rows.
        let amberFill = NSColor(colors.mentionYouFill).usingColorSpace(.sRGB)!
        #expect(
            amberFill.redComponent > amberFill.greenComponent && amberFill.greenComponent > amberFill.blueComponent,
            "\(theme) dark=\(dark) mentionYouFill must be warm amber")
        for row in [
            colors.canvas, colors.rowHover, over(colors.highlight, colors.rowHover),
            over(colors.hover, over(colors.highlight, colors.canvas)),
        ] {
            #expect(
                contrast(colors.mentionYouText, over(colors.mentionYouFill, row)) >= 4.5,
                "\(theme) dark=\(dark) mentionYou contrast")
        }
        // Soft tinted file type tiles keep crisp icon contrast without screaming as solid blocks.
        for kind in FileKind.allCases {
            let tile = over(colors.fileFill(kind), colors.surfaceCard)
            #expect(contrast(colors.fileGlyph(kind), tile) >= 3.0, "\(theme) dark=\(dark) fileGlyph \(kind)")
        }
        // Where a message crosses a doodle, and under the pointer too.
        let doodled = over(colors.wallpaperDoodle, colors.canvas)
        #expect(contrast(colors.textSecondary, over(colors.hover, doodled)) >= 4.5)
        #expect(contrast(colors.accent, doodled) >= 4.5)
        if theme.framed {
            let doodleAlpha = NSColor(colors.wallpaperDoodle).usingColorSpace(.sRGB)!.alphaComponent
            #expect((0.02...0.03).contains(doodleAlpha), "\(theme) dark=\(dark) wallpaperDoodle alpha=\(doodleAlpha)")
        }
    }

    // capability: app.themes
    @Test(
        "Surfaces form an opaque, monotonic luminance ladder so hovered rows never invert cards or bleed wallpaper",
        arguments: ColorTheme.allCases, [false, true])
    func surfaceLadder(theme: ColorTheme, dark: Bool) {
        let colors = AppColors(dark: dark, accent: AppColors.resolve(.systemBlue, dark: dark), theme: theme)
        // Opaque surfaces stop framed-theme wallpaper doodles from bleeding through hovered rows, cards and overlays.
        for (name, surface) in [
            ("canvas", colors.canvas), ("rowHover", colors.rowHover), ("raised", colors.raised),
            ("surfaceCard", colors.surfaceCard), ("overlay", colors.overlay),
        ] {
            let alpha = NSColor(surface).usingColorSpace(.sRGB)!.alphaComponent
            #expect(alpha >= 0.999, "\(theme) dark=\(dark) \(name) must be opaque, got alpha=\(alpha)")
        }
        let canvas = luminance(colors.canvas)
        let rowHover = luminance(colors.rowHover)
        let raised = luminance(colors.raised)
        let card = luminance(colors.surfaceCard)
        let overlay = luminance(colors.overlay)
        if dark {
            #expect(canvas < rowHover, "\(theme) dark: canvas < rowHover")
            #expect(rowHover < raised, "\(theme) dark: rowHover < raised")
            #expect(raised <= card, "\(theme) dark: raised <= surfaceCard")
            #expect(card < overlay, "\(theme) dark: surfaceCard < overlay")
        } else {
            #expect(canvas > rowHover, "\(theme) light: canvas > rowHover")
            #expect(rowHover > raised, "\(theme) light: rowHover > raised")
            #expect(card > rowHover, "\(theme) light: surfaceCard lifts above rowHover")
            #expect(overlay > rowHover, "\(theme) light: overlay lifts above rowHover")
        }
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
            #expect(contrast(sidebar.textTertiary, frame) >= 4.5, "\(theme) dark=\(dark) onFrameTertiary")
        }
    }

    // capability: app.appearance
    @Test("Appearance defaults to following the system color scheme")
    func defaultsToSystem() {
        let saved = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.mode") }
        UserDefaults.standard.removeObject(forKey: "appearance.mode")
        #expect(AppearanceStore().mode == .system)
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

    private func luminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> Double {
            let value = Double(value)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722
            * linear(rgb.blueComponent)
    }

    private func contrast(_ first: Color, _ second: Color) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
