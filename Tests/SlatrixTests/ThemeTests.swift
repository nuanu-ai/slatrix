import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
@Suite("Themes")
struct ThemeTests {
    private struct Variant: Sendable, CustomTestStringConvertible {
        let dark: Bool
        let highContrast: Bool
        var testDescription: String {
            "\(dark ? "dark" : "light")\(highContrast ? "+highContrast" : "")"
        }
        static let all: [Variant] = [
            .init(dark: false, highContrast: false),
            .init(dark: false, highContrast: true),
            .init(dark: true, highContrast: false),
            .init(dark: true, highContrast: true),
        ]
    }

    // capability: app.appearance
    // capability: app.themes
    @Test(
        "Text stays readable wherever it sits, in every theme, light and dark, normal and high contrast",
        arguments: ColorTheme.allCases, Variant.all)
    private func readable(theme: ColorTheme, variant: Variant) {
        let (dark, highContrast) = (variant.dark, variant.highContrast)
        let colors = AppColors(
            dark: dark, accent: AppColors.resolve(.systemBlue, dark: dark), theme: theme, highContrast: highContrast)
        // WCAG AA for text on window surfaces.
        let surfaces = [
            colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard, colors.overlay,
            colors.control, over(colors.code, colors.canvas),
        ]
        for surface in surfaces {
            #expect(contrast(colors.textPrimary, surface) >= 4.5, "\(theme) dark=\(dark) hc=\(highContrast)")
            #expect(contrast(colors.textSecondary, surface) >= 4.5, "\(theme) dark=\(dark) hc=\(highContrast)")
        }
        for surface in [
            colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard, colors.overlay, colors.control,
        ] {
            #expect(
                contrast(colors.textTertiary, surface) >= 4.5, "\(theme) dark=\(dark) hc=\(highContrast) textTertiary")
        }
        #expect(
            contrast(colors.onAccent, colors.accentFill) >= 4.5,
            "\(theme) dark=\(dark) hc=\(highContrast) onAccent/accentFill")
        #expect(
            contrast(colors.onAccent, colors.destructiveFill) >= 4.5,
            "\(theme) dark=\(dark) hc=\(highContrast) onAccent/destructiveFill")
        for surface in [colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard, colors.overlay] {
            #expect(
                contrast(colors.destructive, surface) >= 4.5,
                "\(theme) dark=\(dark) hc=\(highContrast) destructive text")
        }
        for surface in [colors.canvas, colors.rowHover, colors.raised, colors.surfaceCard] {
            #expect(contrast(colors.warning, surface) >= 4.5, "\(theme) dark=\(dark) hc=\(highContrast) warning")
            #expect(contrast(colors.success, surface) >= 4.5, "\(theme) dark=\(dark) hc=\(highContrast) success")
        }
        #expect(contrast(colors.accent, colors.canvas) >= 4.5, "\(theme) dark=\(dark) hc=\(highContrast) accent")
        #expect(
            contrast(colors.mentionText, over(colors.mentionFill, colors.canvas)) >= 4.5,
            "\(theme) dark=\(dark) hc=\(highContrast) mentionText")
        // Own mentions use warm amber so they stand apart from links and other mentions, readable even on highlighted rows.
        let amberFill = NSColor(colors.mentionYouFill).usingColorSpace(.sRGB)!
        #expect(
            amberFill.redComponent > amberFill.greenComponent && amberFill.greenComponent > amberFill.blueComponent,
            "\(theme) dark=\(dark) hc=\(highContrast) mentionYouFill must be warm amber")
        for row in [
            colors.canvas, colors.rowHover, over(colors.highlight, colors.rowHover),
            over(colors.hover, over(colors.highlight, colors.canvas)),
        ] {
            #expect(
                contrast(colors.mentionYouText, over(colors.mentionYouFill, row)) >= 4.5,
                "\(theme) dark=\(dark) hc=\(highContrast) mentionYou contrast")
        }
        // Soft tinted file type tiles keep crisp icon contrast without screaming as solid blocks.
        for kind in FileKind.allCases {
            let tile = over(colors.fileFill(kind), colors.surfaceCard)
            #expect(
                contrast(colors.fileGlyph(kind), tile) >= 3.0,
                "\(theme) dark=\(dark) hc=\(highContrast) fileGlyph \(kind)")
        }
        // Every theme defines subtle doodles at ~2.5% opacity; text and links stay readable across them.
        let doodleAlpha = NSColor(colors.wallpaperDoodle).usingColorSpace(.sRGB)!.alphaComponent
        #expect(
            (0.02...0.03).contains(doodleAlpha),
            "\(theme) dark=\(dark) hc=\(highContrast) wallpaperDoodle alpha=\(doodleAlpha)")
        let doodled = over(colors.wallpaperDoodle, colors.canvas)
        #expect(contrast(colors.textSecondary, over(colors.hover, doodled)) >= 4.5)
        #expect(contrast(colors.accent, doodled) >= 4.5)
    }

    // capability: app.themes
    @Test(
        "Increase contrast strengthens borders, deepens dark canvas, and boosts text contrast on every theme",
        arguments: ColorTheme.allCases, [false, true])
    func highContrastInvariants(theme: ColorTheme, dark: Bool) {
        let accent = AppColors.resolve(.systemBlue, dark: dark)
        let normal = AppColors(dark: dark, accent: accent, theme: theme, highContrast: false)
        let boosted = AppColors(dark: dark, accent: accent, theme: theme, highContrast: true)
        let normalBorder = NSColor(normal.border).usingColorSpace(.sRGB)!.alphaComponent
        let boostedBorder = NSColor(boosted.border).usingColorSpace(.sRGB)!.alphaComponent
        #expect(
            abs(boostedBorder - normalBorder * 2) < 0.005,
            "\(theme) dark=\(dark): border alpha \(boostedBorder) should double \(normalBorder)")
        let normalStrong = NSColor(normal.borderStrong).usingColorSpace(.sRGB)!.alphaComponent
        let boostedStrong = NSColor(boosted.borderStrong).usingColorSpace(.sRGB)!.alphaComponent
        #expect(
            abs(boostedStrong - normalStrong * 2) < 0.005,
            "\(theme) dark=\(dark): borderStrong alpha \(boostedStrong) should double \(normalStrong)")
        #expect(contrast(boosted.textPrimary, boosted.canvas) > contrast(normal.textPrimary, normal.canvas))
        #expect(contrast(boosted.textSecondary, boosted.canvas) > contrast(normal.textSecondary, normal.canvas))
        if dark {
            #expect(luminance(boosted.canvas) < luminance(normal.canvas))
            #expect(luminance(boosted.canvas) <= 0.003)
        }
    }

    // capability: app.themes
    @Test(
        "Surfaces form an opaque, monotonic luminance ladder so hovered rows never invert cards or bleed wallpaper",
        arguments: ColorTheme.allCases, Variant.all)
    private func surfaceLadder(theme: ColorTheme, variant: Variant) {
        let (dark, highContrast) = (variant.dark, variant.highContrast)
        let colors = AppColors(
            dark: dark, accent: AppColors.resolve(.systemBlue, dark: dark), theme: theme, highContrast: highContrast)
        // Opaque surfaces stop wallpaper doodles from bleeding through hovered rows, cards and overlays.
        for (name, surface) in [
            ("canvas", colors.canvas), ("rowHover", colors.rowHover), ("control", colors.control),
            ("raised", colors.raised), ("surfaceCard", colors.surfaceCard), ("overlay", colors.overlay),
        ] {
            let alpha = NSColor(surface).usingColorSpace(.sRGB)!.alphaComponent
            #expect(alpha >= 0.999, "\(theme) dark=\(dark) hc=\(highContrast) \(name) must be opaque, got \(alpha)")
        }
        let canvas = luminance(colors.canvas)
        let rowHover = luminance(colors.rowHover)
        let control = luminance(colors.control)
        let raised = luminance(colors.raised)
        let card = luminance(colors.surfaceCard)
        let overlay = luminance(colors.overlay)
        if dark {
            #expect(canvas < rowHover, "\(theme) dark hc=\(highContrast): canvas < rowHover")
            #expect(rowHover < control, "\(theme) dark hc=\(highContrast): rowHover < control")
            #expect(control < raised, "\(theme) dark hc=\(highContrast): control < raised")
            #expect(raised <= card, "\(theme) dark hc=\(highContrast): raised <= surfaceCard")
            #expect(card < overlay, "\(theme) dark hc=\(highContrast): surfaceCard < overlay")
        } else {
            #expect(canvas > rowHover, "\(theme) light hc=\(highContrast): canvas > rowHover")
            #expect(rowHover > raised, "\(theme) light hc=\(highContrast): rowHover > raised")
            #expect(card > rowHover, "\(theme) light hc=\(highContrast): surfaceCard lifts above rowHover")
            #expect(overlay > rowHover, "\(theme) light hc=\(highContrast): overlay lifts above rowHover")
        }
        if colors.coloredSidebar {
            let side = colors.onSidebar
            #expect(luminance(side.canvas) < luminance(side.rowHover))
            #expect(luminance(side.rowHover) < luminance(side.control))
            #expect(luminance(side.control) < luminance(side.raised))
            #expect(luminance(side.surfaceCard) < luminance(side.overlay))
        }
    }

    // capability: app.themes
    @Test(
        "Sidebar text stays readable on the floating sidebar, through its gradient and over any desktop",
        arguments: ColorTheme.allCases, Variant.all)
    private func readableOnSidebar(theme: ColorTheme, variant: Variant) {
        let (dark, highContrast) = (variant.dark, variant.highContrast)
        let colors = AppColors(
            dark: dark, accent: AppColors.resolve(.systemBlue, dark: dark), theme: theme, highContrast: highContrast)
        let sidebar = colors.onSidebar
        // A translucent glass sidebar lets the desktop through, so it is read over both darkest and lightest desktops.
        let surfaces = [colors.sidebar, colors.sidebarEnd].flatMap { [over($0, .black), over($0, .white)] }
        for base in surfaces {
            for surface in [base, over(sidebar.hover, base), over(sidebar.selection, base)] {
                #expect(
                    contrast(sidebar.textPrimary, surface) >= 4.5,
                    "\(theme) dark=\(dark) hc=\(highContrast) onSidebar primary")
                #expect(
                    contrast(sidebar.textSecondary, surface) >= 4.5,
                    "\(theme) dark=\(dark) hc=\(highContrast) onSidebar secondary")
            }
            #expect(
                contrast(sidebar.textTertiary, base) >= 4.5,
                "\(theme) dark=\(dark) hc=\(highContrast) onSidebar tertiary")
            #expect(
                contrast(sidebar.accent, base) >= 4.5,
                "\(theme) dark=\(dark) hc=\(highContrast) onSidebar accent")
        }
        #expect(
            contrast(sidebar.onAccent, sidebar.accentFill) >= 4.5,
            "\(theme) dark=\(dark) hc=\(highContrast) onSidebar badge")
    }

    // capability: app.themes
    @Test(
        "Colored sidebars carry a visible built-in vertical gradient, while neutral sidebars stay flat",
        arguments: ColorTheme.allCases, [false, true])
    func sidebarGradient(theme: ColorTheme, dark: Bool) throws {
        let colors = AppColors(dark: dark, theme: theme)
        let dist = try difference(colors.sidebar, colors.sidebarEnd)
        if theme.isColored {
            // About Jade's light gradient, the faintest that still reads as a gradient across the sidebar.
            #expect(dist >= 24, "\(theme) dark=\(dark) gradient distance=\(dist)")
        } else {
            #expect(dist < 0.01, "\(theme) dark=\(dark) neutral sidebar should not gradient, got \(dist)")
        }
    }

    // capability: app.themes
    @Test("Six curated themes split cleanly into Neutral and Colored groups")
    func curatedThemeGroups() {
        #expect(ColorTheme.allCases == [.glass, .neutral, .sand, .aubergine, .jade, .ocean])
        #expect(ColorTheme.Group.neutral.themes == [.glass, .neutral, .sand])
        #expect(ColorTheme.Group.colored.themes == [.aubergine, .jade, .ocean])
        #expect(ColorTheme.Group.allCases.flatMap(\.themes) == ColorTheme.allCases)
    }

    // capability: app.appearance
    // capability: app.themes
    @Test("Fresh installs default to system mode, glass theme, wallpaper on, and increase contrast off")
    func freshDefaults() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let store = AppearanceStore(defaults: defaults)
        #expect(store.mode == .system)
        #expect(store.theme == .glass)
        #expect(store.chatWallpaper == true)
        #expect(store.increaseContrast == false)
        #expect(store.workspaceThemes.isEmpty)
        #expect(store.effectiveTheme(for: nil) == .glass)
    }

    // capability: app.themes
    @Test("Legacy theme values migrate cleanly, including high contrast without clobbering explicit settings")
    func legacyMigration() throws {
        let mappings: [(String, ColorTheme, Bool)] = [
            ("standard", .neutral, false),
            ("slate", .neutral, false),
            ("lagoon", .ocean, false),
            ("midnight", .ocean, false),
            ("contrast", .neutral, true),
        ]
        for (legacy, expectedTheme, expectedContrast) in mappings {
            let (defaults, cleanup) = try scratchDefaults()
            defer { cleanup() }
            defaults.set(legacy, forKey: "appearance.theme")
            let store = AppearanceStore(defaults: defaults)
            #expect(store.theme == expectedTheme, "legacy \(legacy) -> \(store.theme)")
            #expect(
                store.increaseContrast == expectedContrast, "legacy \(legacy) contrast -> \(store.increaseContrast)")
            if expectedContrast {
                // Switching to another theme later keeps the migrated high-contrast preference across relaunch.
                store.theme = .jade
                let relaunched = AppearanceStore(defaults: defaults)
                #expect(relaunched.theme == .jade)
                #expect(relaunched.increaseContrast == true)
            }
        }
        // Explicit appearance.increaseContrast = false is never overwritten by legacy "contrast".
        let (explicitDefaults, explicitCleanup) = try scratchDefaults()
        defer { explicitCleanup() }
        explicitDefaults.set("contrast", forKey: "appearance.theme")
        explicitDefaults.set(false, forKey: "appearance.increaseContrast")
        let explicitStore = AppearanceStore(defaults: explicitDefaults)
        #expect(explicitStore.theme == .neutral)
        #expect(explicitStore.increaseContrast == false)

        // Legacy workspace overrides migrate too, ignoring unknown values.
        let (wsDefaults, wsCleanup) = try scratchDefaults()
        defer { wsCleanup() }
        wsDefaults.set(
            [
                "!a:example.org": "standard", "!b:example.org": "slate",
                "!c:example.org": "lagoon", "!d:example.org": "midnight",
                "!e:example.org": "contrast", "!f:example.org": "removed-unknown",
            ],
            forKey: "appearance.workspaceThemes")
        let wsStore = AppearanceStore(defaults: wsDefaults)
        #expect(wsStore.workspaceThemes["!a:example.org"] == .neutral)
        #expect(wsStore.workspaceThemes["!b:example.org"] == .neutral)
        #expect(wsStore.workspaceThemes["!c:example.org"] == .ocean)
        #expect(wsStore.workspaceThemes["!d:example.org"] == .ocean)
        #expect(wsStore.workspaceThemes["!e:example.org"] == .neutral)
        #expect(wsStore.workspaceThemes["!f:example.org"] == nil)
        #expect(wsStore.increaseContrast == true)
    }

    // capability: app.themes
    @Test("Chat wallpaper and increase contrast toggles persist independently and combine with macOS contrast")
    func independentToggles() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let store = AppearanceStore(defaults: defaults)
        store.theme = .sand
        store.chatWallpaper = false
        store.increaseContrast = true

        let reloaded = AppearanceStore(defaults: defaults)
        #expect(reloaded.theme == .sand)
        #expect(reloaded.chatWallpaper == false)
        #expect(reloaded.increaseContrast == true)
        #expect(reloaded.colors.highContrast == true)

        reloaded.increaseContrast = false
        reloaded.systemIncreaseContrast = false
        #expect(reloaded.effectiveIncreaseContrast == false)
        #expect(reloaded.colors.highContrast == false)

        reloaded.systemIncreaseContrast = true
        #expect(reloaded.effectiveIncreaseContrast == true)
        #expect(reloaded.colors.highContrast == true)
    }

    // capability: app.themes
    @Test("Per-workspace theme overrides persist, resolve cleanly, and fall back to global theme when cleared")
    func workspaceOverrides() throws {
        let (defaults, cleanup) = try scratchDefaults()
        defer { cleanup() }
        let store = AppearanceStore(defaults: defaults)
        store.theme = .glass
        store.setTheme(.aubergine, for: "!eng:example.org")
        store.setTheme(.jade, for: "!design:example.org")

        #expect(store.effectiveTheme(for: nil) == .glass)
        #expect(store.effectiveTheme(for: "!eng:example.org") == .aubergine)
        #expect(store.effectiveTheme(for: "!design:example.org") == .jade)
        #expect(store.effectiveTheme(for: "!other:example.org") == .glass)

        store.activeWorkspaceID = "!eng:example.org"
        #expect(store.colors.theme == .aubergine)
        store.activeWorkspaceID = "!other:example.org"
        #expect(store.colors.theme == .glass)

        let reloaded = AppearanceStore(defaults: defaults)
        #expect(reloaded.effectiveTheme(for: "!eng:example.org") == .aubergine)
        #expect(reloaded.effectiveTheme(for: "!design:example.org") == .jade)

        reloaded.clearTheme(for: "!eng:example.org")
        #expect(reloaded.effectiveTheme(for: "!eng:example.org") == .glass)
        #expect(AppearanceStore(defaults: defaults).workspaceThemes["!eng:example.org"] == nil)
    }

    private func scratchDefaults() throws -> (UserDefaults, () -> Void) {
        let name = "SlatrixThemeTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, { defaults.removePersistentDomain(forName: name) })
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
