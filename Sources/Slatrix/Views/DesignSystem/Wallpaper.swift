import AppKit
import SwiftUI

/// The chat wallpaper, as Android draws it, behind the messages in a frame theme: faint doodles of the app's own icons
/// on a tile that repeats. The board is `design/wallpaper.json`'s, in points.
enum Wallpaper {
    static let tile: CGFloat = 240
    static let stroke: CGFloat = 1.5
    static let icons: [String: String] = [
        "message": "M0 3a3 3 0 0 1 3-3h16a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3H8l-5 4v-4H3a3 3 0 0 1-3-3z",
        "channel": "M2 7h16M2 13h16M8 2 6 18M14 2l-2 16",
        "mention":
            "M13.5 10a3.5 3.5 0 1 1-7 0 3.5 3.5 0 0 1 7 0zM13.5 10v1.5a2.5 2.5 0 0 0 5 0V10a8.5 8.5 0 1 0-3.4 6.8",
        "attachment": "M6 10l7-7a3.5 3.5 0 0 1 5 5l-9 9a5 5 0 0 1-7-7l8-8",
        "later": "M0 0h14v20l-7-5-7 5z",
        "reaction":
            "M9 0a9 9 0 1 1 0 18A9 9 0 0 1 9 0zM5.5 11c.9 1.2 2 1.8 3.5 1.8s2.6-.6 3.5-1.8M6.2 7h.01M11.8 7h.01",
        "read": "M0 8l5 5L15 3M9 12l1 1L20 3",
        "heart": "M10 18s-8-5-8-10a4.5 4.5 0 0 1 8-2.5A4.5 4.5 0 0 1 18 8c0 5-8 10-8 10z",
        "activity": "M3 14V9a6 6 0 0 1 12 0v5l2 2H1zM7 19a2 2 0 0 0 4 0",
        "plus": "M7 0v14M0 7h14",
        "dot": "M4 0a4 4 0 1 1 0 8 4 4 0 0 1 0-8z",
    ]
    struct Doodle {
        let x, y, turn: Double
        let icon: String
        init(_ x: Double, _ y: Double, _ turn: Double, _ icon: String) {
            (self.x, self.y, self.turn, self.icon) = (x, y, turn, icon)
        }
    }
    /// Top left corners and turns; one crossing an edge is drawn again one tile over, so it carries on in the next.
    static let doodles: [Doodle] = [
        .init(68, 26, 0, "dot"), .init(199, 151, 0, "reaction"), .init(187, 31, 10, "later"),
        .init(77, 145, -10, "message"), .init(135, 197, -12, "heart"), .init(130, 86, -6, "read"),
        .init(11, 85, 0, "reaction"), .init(14, 209, 12, "heart"), .init(20, 143, -12, "heart"),
        .init(127, 21, 12, "heart"), .init(191, 206, 0, "mention"), .init(76, 207, 0, "plus"),
        .init(195, 86, -10, "channel"), .init(4, 26, 0, "dot"), .init(133, 143, -25, "attachment"),
        .init(67, 90, 0, "reaction"), .init(164, 115, 0, "reaction"), .init(41, 179, 0, "dot"),
        .init(94, 58, 10, "later"), .init(223, 117, 0, "plus"), .init(159, -2, 12, "activity"),
        .init(167, 175, -6, "read"), .init(-10, 173, 6, "read"), .init(36, 2, 10, "channel"),
        .init(43, 59, 10, "later"), .init(219, -6, -12, "activity"), .init(156, 57, -10, "channel"),
        .init(106, 169, 0, "mention"), .init(104, 116, -10, "channel"), .init(109, 227, 0, "mention"),
        .init(51, 122, 0, "plus"), .init(217, 54, -10, "message"), .init(71, 175, 6, "read"),
        .init(49, 216, 0, "mention"), .init(80, -3, 10, "message"), .init(36, 32, -10, "message"),
        .init(13, 53, -25, "attachment"), .init(24, 111, 25, "attachment"), .init(169, 144, 12, "activity"),
        .init(127, 56, 0, "plus"), .init(222, 201, 0, "dot"), .init(96, 89, -12, "activity"),
        .init(165, 85, 10, "later"), .init(215, 23, 25, "attachment"),
    ]

    @MainActor private static var tiles: [String: CGImage] = [:]

    /// The tile in `ink`, `side` points square at `scale` pixels a point, drawn once and kept.
    @MainActor static func image(ink: NSColor, side: CGFloat, scale: CGFloat) -> CGImage? {
        let ink = ink.usingColorSpace(.sRGB) ?? ink
        let pixels = Int((side * scale).rounded())
        let hex = String(
            format: "#%02x%02x%02x", Int((ink.redComponent * 255).rounded()), Int((ink.greenComponent * 255).rounded()),
            Int((ink.blueComponent * 255).rounded()))
        let key = "\(hex) \(ink.alphaComponent) \(pixels)"
        if let tile = tiles[key] { return tile }
        let wrap = [-tile, 0, tile]
        let paths = doodles.flatMap { doodle in
            wrap.flatMap { dx in
                wrap.map { dy in
                    "<path transform=\"translate(\(doodle.x + dx) \(doodle.y + dy)) rotate(\(doodle.turn))\" "
                        + "d=\"\(icons[doodle.icon] ?? "")\"/>"
                }
            }
        }
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="\(tile)" height="\(tile)" viewBox="0 0 \(tile) \(tile)">\
            <g fill="none" stroke="\(hex)" stroke-opacity="\(ink.alphaComponent)" stroke-width="\(stroke)" \
            stroke-linecap="round" stroke-linejoin="round">\(paths.joined())</g></svg>
            """
        guard pixels > 0, let image = NSImage(data: Data(svg.utf8)),
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let tile = bitmap.cgImage
        tiles[key] = tile
        return tile
    }
}

/// The wallpaper, repeating from the top leading corner and staying put while what lies over it scrolls.
struct WallpaperBackground: View {
    let ink: Color
    @Environment(\.metrics) private var m
    @Environment(\.displayScale) private var scale

    var body: some View {
        if let tile = Wallpaper.image(ink: NSColor(ink), side: Wallpaper.tile * m.zoom, scale: scale) {
            Image(decorative: tile, scale: scale).resizable(resizingMode: .tile).accessibilityHidden(true)
        }
    }
}
