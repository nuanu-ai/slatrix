import AppKit
import Testing

struct AppIconTests {
    private static let config = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Config")

    // capability: app.icon
    @Test("The icon the bundle names has every size the Dock and Finder draw, from 16 to 1024 pixels")
    func everySize() throws {
        let info = try #require(NSDictionary(contentsOf: Self.config.appendingPathComponent("Info.plist")))
        let name = try #require(info["CFBundleIconFile"] as? String)
        let icon = try #require(NSImage(contentsOf: Self.config.appendingPathComponent(name + ".icns")))
        #expect(Set(icon.representations.map(\.pixelsWide)).isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]))
    }
}
