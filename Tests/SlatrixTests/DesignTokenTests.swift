import SwiftUI
import Testing

@testable import Slatrix

/// The Mac app draws what `design/tokens.json` says, the file the Android app draws from too.
@MainActor
struct DesignTokenTests {
    private struct Tokens: Decodable {
        var colors: [String: ColorToken]
        var fileColors: [String: String]
        var radius: [String: Double]
    }

    /// One color for every theme, or a light and a dark one; either side may name one color per palette.
    private struct ColorToken: Decodable {
        private enum Side: Decodable {
            case one(String)
            case perPalette([String: String])

            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let color = try? value.decode(String.self) {
                    self = .one(color)
                } else {
                    self = .perPalette(try value.decode([String: String].self))
                }
            }
        }

        private let light: Side
        private let dark: Side

        init(from decoder: Decoder) throws {
            if let color = try? decoder.singleValueContainer().decode(String.self) {
                (light, dark) = (.one(color), .one(color))
            } else {
                let sides = try decoder.singleValueContainer().decode([String: Side].self)
                guard let light = sides["light"], let dark = sides["dark"], sides.count == 2 else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "\(sides)"))
                }
                (self.light, self.dark) = (light, dark)
            }
        }

        func color(dark: Bool, palette: SidebarPalette) -> String? {
            switch dark ? self.dark : light {
            case .one(let color): color
            case .perPalette(let colors): colors[String(describing: palette)]
            }
        }
    }

    private let tokens: Tokens

    init() throws {
        tokens = try SharedSpec.decode("design/tokens.json")
    }

    @Test("Every color role matches the shared tokens in both themes and every sidebar palette")
    func colors() throws {
        let roles: [String: KeyPath<AppColors, Color>] = [
            "textPrimary": \.textPrimary, "textBody": \.textBody, "textSecondary": \.textSecondary,
            "textTertiary": \.textTertiary, "canvas": \.canvas, "raised": \.raised, "sunken": \.sunken,
            "overlay": \.overlay, "tooltip": \.tooltip, "onTooltip": \.onTooltip, "scrim": \.scrim,
            "sidebar": \.sidebar, "frame": \.frame, "border": \.border, "borderStrong": \.borderStrong,
            "hover": \.hover, "pressed": \.pressed, "selection": \.selection, "selectionStrong": \.selectionStrong,
            "selectionText": \.selectionText, "highlight": \.highlight, "focusRing": \.focusRing, "accent": \.accent,
            "accentTint": \.accentTint, "onAccent": \.onAccent, "buttonPrimary": \.buttonPrimary,
            "success": \.success, "destructive": \.destructive, "warning": \.warning, "mention": \.mention,
            "mentionText": \.mentionText, "mentionFill": \.mentionFill, "mentionYouText": \.mentionYouText,
            "mentionYouFill": \.mentionYouFill, "presenceActive": \.presenceActive, "presenceAway": \.presenceAway,
            "mediaBackdrop": \.mediaBackdrop, "mediaControl": \.mediaControl, "mediaShade": \.mediaShade,
            "onMedia": \.onMedia, "onMediaEdge": \.onMediaEdge,
        ]
        #expect(Set(tokens.colors.keys) == Set(roles.keys))
        for (role, keyPath) in roles {
            let token = try #require(tokens.colors[role], "\(role)")
            for dark in [false, true] {
                for palette in SidebarPalette.allCases {
                    let drawn = AppColors(dark: dark, palette: palette)[keyPath: keyPath]
                    let expected = try #require(token.color(dark: dark, palette: palette), "\(role) \(palette)")
                    #expect(
                        Self.matches(drawn, expected),
                        "\(role), \(dark ? "dark" : "light"), \(palette): \(drawn.resolve(in: .init())) ≠ \(expected)")
                }
            }
        }
    }

    @Test("Each file type's tile has its shared color")
    func fileColors() throws {
        let colors = AppColors(dark: false, palette: .gray)
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
            tokens.radius == [
                "small": Double(m.radiusSmall), "default": Double(m.radius), "large": Double(m.radiusLarge),
                "panel": Double(m.radiusPanel),
            ])
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
