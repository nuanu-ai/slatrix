import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A square cropped from a photo picked for your profile, scaled down: avatars draw a few hundred points wide at most,
/// and a photo straight from a phone uploads slowly and is too large for the avatar cache to show.
struct ProfilePhoto: Equatable, Sendable {
    private static let maximumPixels = 1_024
    let data: Data
    let mimeType: String

    struct Failure: Error {
        let message = "Choose an image file."
    }

    /// The picked file upright, at twice the upload size, so a crop of half of it still makes a sharp photo.
    static func image(contentsOf url: URL) throws -> CGImage {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2 * maximumPixels,
                ] as CFDictionary)
        else { throw Failure() }
        return image
    }

    /// The square `crop` of `image`, in its pixels from the top-left.
    init(_ image: CGImage, crop: CGRect) throws {
        // JPEG is far smaller for a photo, but would turn a transparent logo's background black.
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        guard let square = image.cropping(to: crop) else { throw Failure() }
        let side = min(square.width, square.height, Self.maximumPixels)
        guard
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        else { throw Failure() }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        let type = opaque ? UTType.jpeg : .png
        let output = NSMutableData()
        guard let scaled = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        else { throw Failure() }
        CGImageDestinationAddImage(
            destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let mimeType = type.preferredMIMEType else { throw Failure() }
        data = output as Data
        self.mimeType = mimeType
    }
}

/// Slack's crop frame: a square over the photo, in the photo's pixels from its top-left, that moves and resizes from a
/// corner without leaving the photo.
enum PhotoCrop {
    enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var right: Bool { self == .topRight || self == .bottomRight }
        var bottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    /// The largest square in the middle, which Save uses untouched.
    static func centered(in size: CGSize) -> CGRect {
        let side = min(size.width, size.height)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    static func moved(_ square: CGRect, by offset: CGSize, in size: CGSize) -> CGRect {
        CGRect(
            x: min(max(square.minX + offset.width, 0), size.width - square.width),
            y: min(max(square.minY + offset.height, 0), size.height - square.height),
            width: square.width, height: square.height)
    }

    /// `corner` dragged by `offset` while the opposite corner stays put. The frame keeps to a quarter of the photo's
    /// short side at least, so its corners stay apart enough to grab.
    static func resized(_ square: CGRect, from corner: Corner, by offset: CGSize, in size: CGSize) -> CGRect {
        let anchor = CGPoint(x: corner.right ? square.minX : square.maxX, y: corner.bottom ? square.minY : square.maxY)
        // How far the drag goes along the frame's diagonal.
        let growth = ((corner.right ? 1 : -1) * offset.width + (corner.bottom ? 1 : -1) * offset.height) / 2
        let room = min(
            corner.right ? size.width - anchor.x : anchor.x, corner.bottom ? size.height - anchor.y : anchor.y)
        let side = min(max(square.width + growth, min(size.width, size.height) / 4), room)
        return CGRect(
            x: corner.right ? anchor.x : anchor.x - side, y: corner.bottom ? anchor.y : anchor.y - side, width: side,
            height: side)
    }
}
