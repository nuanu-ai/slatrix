import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The Mac draws what `design/tokens.json` says under "mac", and the file colors both apps share.
@MainActor
struct DesignTokenTests {
    private struct Tokens: Decodable {
        struct Mac: Decodable {
            var colors: [String: ColorToken]
            /// Each theme's roles that differ from `colors`.
            var themes: [String: [String: ColorToken]]
            var radius: [String: Double]
        }
        var mac: Mac
        var fileColors: [String: String]
    }

    /// One color for every theme, or a light and a dark one.
    private struct ColorToken: Decodable {
        private let light: String
        private let dark: String

        init(from decoder: Decoder) throws {
            if let color = try? decoder.singleValueContainer().decode(String.self) {
                (light, dark) = (color, color)
            } else {
                let sides = try decoder.singleValueContainer().decode([String: String].self)
                guard let light = sides["light"], let dark = sides["dark"], sides.count == 2 else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "\(sides)"))
                }
                (self.light, self.dark) = (light, dark)
            }
        }

        func color(dark: Bool) -> String { dark ? self.dark : light }
    }

    private let tokens: Tokens

    init() throws {
        tokens = try SharedSpec.decode("design/tokens.json")
    }

    @Test(
        "Every color role matches the shared tokens in light and dark, with the accent the tokens name",
        arguments: ColorTheme.allCases)
    func colors(theme: ColorTheme) throws {
        let roles: [String: KeyPath<AppColors, Color>] = [
            "textPrimary": \.textPrimary, "textBody": \.textBody, "textSecondary": \.textSecondary,
            "textTertiary": \.textTertiary, "canvas": \.canvas, "raised": \.raised, "sunken": \.sunken,
            "overlay": \.overlay, "control": \.control, "tooltip": \.tooltip, "onTooltip": \.onTooltip,
            "scrim": \.scrim, "sidebar": \.sidebar, "border": \.border, "borderStrong": \.borderStrong,
            "hover": \.hover, "pressed": \.pressed, "selection": \.selection, "highlight": \.highlight,
            "accentFill": \.accentFill, "accent": \.accent, "accentTint": \.accentTint, "accentLine": \.accentLine,
            "onAccent": \.onAccent, "success": \.success, "destructive": \.destructive, "warning": \.warning,
            "mentionText": \.mentionText, "mentionFill": \.mentionFill, "mentionYouText": \.mentionYouText,
            "mentionYouFill": \.mentionYouFill, "code": \.code, "presenceActive": \.presenceActive,
            "presenceAway": \.presenceAway, "mediaBackdrop": \.mediaBackdrop, "mediaControl": \.mediaControl,
            "mediaShade": \.mediaShade, "onMedia": \.onMedia, "onMediaEdge": \.onMediaEdge,
            "frame": \.frame, "frameEnd": \.frameEnd, "onFrame": \.onFrame.textPrimary,
            "onFrameSecondary": \.onFrame.textSecondary, "onFrameTertiary": \.onFrame.textTertiary,
            "frameSelection": \.onFrame.selection, "wallpaperDoodle": \.wallpaperDoodle,
        ]
        #expect(Set(tokens.mac.colors.keys) == Set(roles.keys))
        #expect(Set(tokens.mac.themes.keys) == Set(ColorTheme.allCases.dropFirst().map(\.rawValue)))
        let own = tokens.mac.themes[theme.rawValue] ?? [:]
        #expect(Set(own.keys).isSubset(of: roles.keys))
        for (role, keyPath) in roles {
            let token = try #require(own[role] ?? tokens.mac.colors[role], "\(role)")
            for dark in [false, true] {
                let colors = AppColors(dark: dark, accent: Self.blue(dark: dark), theme: theme)
                let drawn = colors[keyPath: keyPath]
                let expected = token.color(dark: dark)
                #expect(
                    Self.matches(drawn, expected),
                    "\(theme) \(role), \(dark ? "dark" : "light"): \(drawn.resolve(in: .init())) ≠ \(expected)")
            }
        }
    }

    // capability: app.themes
    @Test("The wallpaper draws the shared doodle board")
    func wallpaper() throws {
        struct Board: Decodable {
            var tile: Double
            var stroke: Double
            var icons: [String: String]
            var doodles: [[Doodle]]
        }
        enum Doodle: Decodable, Equatable {
            case number(Double)
            case icon(String)
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let number = try? value.decode(Double.self) {
                    self = .number(number)
                } else {
                    self = .icon(try value.decode(String.self))
                }
            }
        }
        let board: Board = try SharedSpec.decode("design/wallpaper.json")
        #expect(Double(Wallpaper.tile) == board.tile)
        #expect(Double(Wallpaper.stroke) == board.stroke)
        #expect(Wallpaper.icons == board.icons)
        #expect(
            Wallpaper.doodles.map { [.number($0.x), .number($0.y), .number($0.turn), .icon($0.icon)] }
                == board.doodles)
    }

    @Test("Each file type's tile has its shared color")
    func fileColors() throws {
        let colors = AppColors(dark: false)
        #expect(Set(tokens.fileColors.keys) == Set(FileKind.allCases.map { String(describing: $0) }))
        for kind in FileKind.allCases {
            let expected = try #require(tokens.fileColors[String(describing: kind)])
            #expect(Self.matches(colors.file(kind), expected), "\(kind)")
        }
    }

    @Test("Corner radii match the shared tokens")
    func radii() {
        let m = Metrics()
        #expect(
            tokens.mac.radius == [
                "small": Double(m.radiusSmall), "default": Double(m.radius), "large": Double(m.radiusLarge),
                "panel": Double(m.radiusPanel), "space": Double(m.radiusSpace),
            ])
    }

    /// The tokens' accent, fixed so the test doesn't follow the system blue from one macOS to the next.
    static func blue(dark: Bool) -> NSColor {
        dark
            ? NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 122 / 255, blue: 1, alpha: 1)
    }

    /// Within half a step of 8-bit color, so a token written as hex matches the value SwiftUI resolves.
    static func matches(_ color: Color, _ token: String) -> Bool {
        let parts = token.dropFirst().split(separator: "/")
        guard token.hasPrefix("#"), (1...2).contains(parts.count), parts[0].count == 6,
            let rgb = UInt32(parts[0], radix: 16), let opacity = parts.count == 2 ? Double(parts[1]) : 1
        else { return false }
        let expected = [Double(rgb >> 16 & 255) / 255, Double(rgb >> 8 & 255) / 255, Double(rgb & 255) / 255, opacity]
        let resolved = color.resolve(in: .init())
        let drawn = [resolved.red, resolved.green, resolved.blue, resolved.opacity].map(Double.init)
        return zip(drawn, expected).allSatisfy { abs($0 - $1) < 0.5 / 255 }
    }
}
