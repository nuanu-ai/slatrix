import SwiftUI

extension AppearanceStore {
    var colors: AppColors { AppColors(dark: isDark, palette: palette) }
}

struct AppColors {
    let dark: Bool
    let palette: SidebarPalette
    var canvas: Color { Color(hex: dark ? 0x1c1d21 : 0xffffff) }
    var raised: Color { Color(hex: dark ? 0x24262a : 0xf8f8f8) }
    var text: Color { Color(hex: dark ? 0xd1d2d3 : 0x1d1c1d) }
    var primaryText: Color { Color(hex: dark ? 0xf5f5f5 : 0x1d1c1d) }
    var muted: Color { Color(hex: dark ? 0xabadb1 : 0x616061) }
    var border: Color { Color(hex: dark ? 0x383a3e : 0xe3e3e3) }
    var hover: Color { Color.primary.opacity(dark ? 0.055 : 0.035) }
    var accent: Color { Color(hex: dark ? 0x8195ff : 0x334ec9) }
    var selection: Color {
        switch palette {
        case .slate: Color(hex: dark ? 0x293b94 : 0xe7ebff)
        case .aubergine: Color(hex: dark ? 0x713783 : 0xf0e6f4)
        case .ocean: Color(hex: dark ? 0x195b7c : 0xdceef8)
        case .forest: Color(hex: dark ? 0x2d6654 : 0xdeeee5)
        }
    }
    var frame: Color {
        guard dark else {
            return Color(
                hex: palette == .slate
                    ? 0xf0f0f0 : palette == .aubergine ? 0xede4ef : palette == .ocean ? 0xe2edf4 : 0xe4eee7)
        }
        return switch palette {
        case .slate: Color(hex: 0x202124)
        case .aubergine: Color(hex: 0x350d36)
        case .ocean: Color(hex: 0x0e293b)
        case .forest: Color(hex: 0x142b23)
        }
    }
    var sidebar: Color {
        guard dark else { return Color(hex: 0xf8f8f8) }
        return switch palette {
        case .slate: Color(hex: 0x17181a)
        case .aubergine: Color(hex: 0x211323)
        case .ocean: Color(hex: 0x13212b)
        case .forest: Color(hex: 0x15231d)
        }
    }
    var success: Color { Color(hex: 0x208768) }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
            blue: Double(hex & 255) / 255, opacity: 1)
    }
}

func initials(_ value: String) -> String {
    let parts = value.trimmingCharacters(in: CharacterSet(charactersIn: "@#!")).split(whereSeparator: {
        $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-"
    })
    return parts.prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
}

func avatarColor(_ name: String) -> Color {
    let hash = name.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    return Color(hex: [0x78669d, 0x447389, 0x9b6e4d, 0x5e805b, 0xa76b7c, 0x607ba3][Int(hash % 6)])
}
