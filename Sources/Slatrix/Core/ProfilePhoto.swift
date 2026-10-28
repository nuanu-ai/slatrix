import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo picked for your profile, scaled down first: avatars draw a few hundred points wide at most, and a photo
/// straight from a phone uploads slowly and is too large for the avatar cache to show.
struct ProfilePhoto: Equatable, Sendable {
    private static let maximumPixels = 1_024
    let data: Data
    let mimeType: String

    struct Failure: Error {
        let message = "Choose an image file."
    }

    init(contentsOf url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maximumPixels,
                ] as CFDictionary)
        else { throw Failure() }
        // JPEG is far smaller for a photo, but would turn a transparent logo's background black.
        let type = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo) ? UTType.jpeg : .png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
            throw Failure()
        }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let mimeType = type.preferredMIMEType else { throw Failure() }
        data = output as Data
        self.mimeType = mimeType
    }
}
