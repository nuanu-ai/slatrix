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

    @Test("A small avatar's active dot and away ring stay clearly visible at 20 pt")
    func presenceReadableAtSmallSize() throws {
        let saved = UserDefaults.standard.object(forKey: "appearance.mode")
        defer { UserDefaults.standard.set(saved, forKey: "appearance.mode") }
        let appearance = AppearanceStore()
        appearance.mode = .light
        func render(_ presence: Presence?) throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(
                content: AvatarView(name: "Julia Park", size: 20, presence: presence)
                    .padding(4).background(Color.white).environmentObject(appearance))
            renderer.scale = 2
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let plain = try render(nil)
        let active = try render(.active)
        let away = try render(.away)
        // Measure the active dot's painted span in points: green stands well above red.
        var activeMinX = Int.max
        var activeMaxX = -1
        for x in 0..<active.pixelsWide {
            for y in 0..<active.pixelsHigh {
                guard let c = active.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.greenComponent - c.redComponent > 0.25 {
                    activeMinX = min(activeMinX, x)
                    activeMaxX = max(activeMaxX, x)
                }
            }
        }
        let activeDiameterPt = CGFloat(activeMaxX - activeMinX + 1) / 2
        #expect(activeDiameterPt >= 6, "Expected readable active dot (>= 6 pt), got \(activeDiameterPt)")
        // Away ring should paint a solid ring in the bottom-right corner that differs from the plain avatar.
        var awayRingPixels = 0
        for x in (away.pixelsWide / 2)..<away.pixelsWide {
            for y in (away.pixelsHigh / 2)..<away.pixelsHigh {
                guard let a = away.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                    let p = plain.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let gray = abs(a.redComponent - a.blueComponent) < 0.05 && a.brightnessComponent < 0.75
                let changed = abs(a.redComponent - p.redComponent) + abs(a.greenComponent - p.greenComponent) > 0.1
                if gray && changed { awayRingPixels += 1 }
            }
        }
        #expect(awayRingPixels >= 30, "Expected visible away ring (>= 30 px at 2x), got \(awayRingPixels)")
    }

    @Test("An avatar whose image lands in cache before its task runs still replaces its initials")
    func displaysImageCachedBeforeTaskRuns() async throws {
        // Solid sRGB green 8×8 PNG so its pixels are unmistakable over any initials background.
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let cgImage = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))

        let matrix = MatrixService.scratch()
        matrix.user = ChatUser(id: "@me:example.org", name: "Dmitry Ukhanov", avatarURL: "mxc://example.org/me")
        let gate = Gate()
        gate.arm()
        defer { gate.release() }
        // Another AvatarView has an in-flight load for the same avatar; it finishes right after this view's first
        // layout and before its .task executes.
        let inFlight = Task {
            await matrix.avatarImages.image(for: "mxc://example.org/me", pixels: 128) {
                await gate.wait()
                return png
            }
        }
        #expect(await eventually { gate.isWaiting })

        let appearance = AppearanceStore()
        let hosting = NSHostingView(
            rootView: AvatarView(
                name: "Dmitry Ukhanov", size: 28, matrix: matrix, source: "mxc://example.org/me"
            ).environmentObject(appearance))
        let window = offscreenWindow(NSSize(width: 40, height: 40))
        defer {
            window.contentView = nil
            window.close()
        }
        hosting.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        window.contentView = hosting
        // First layout renders initials while cache is still empty.
        hosting.layoutSubtreeIfNeeded()
        // The other AvatarView finishes populating the cache now.
        gate.release()
        let cached = await inFlight.value
        #expect(cached != nil)

        func centerIsGreen() -> Bool {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            guard let snap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
            hosting.cacheDisplay(in: hosting.bounds, to: snap)
            guard
                let color = snap.colorAt(x: snap.pixelsWide / 2, y: snap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            else { return false }
            return color.greenComponent > 0.9 && color.greenComponent - color.redComponent > 0.4
                && color.greenComponent - color.blueComponent > 0.5
        }
        #expect(await eventually { centerIsGreen() })
    }
}
