import AppKit
import SwiftUI
import Testing

@testable import Slatrix

@MainActor
struct AvatarShapeTests {
    /// Whether the pixel a tenth of the way in from the top-left corner is painted.
    private func cornerPainted(_ view: some View) throws -> Bool {
        let renderer = ImageRenderer(content: view.environmentObject(AppearanceStore()))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let inset = image.width / 10
        return (bitmap.colorAt(x: inset, y: inset)?.alphaComponent ?? 0) > 0.5
    }

    @Test("A person's avatar is a circle, and a space keeps its rounded square")
    func shapes() throws {
        #expect(try !cornerPainted(AvatarView(name: "Julia Park", size: 32)))
        #expect(try cornerPainted(AvatarView(name: "Harbor", size: 32, cornerRadius: Metrics().radiusSpace)))
    }
}
