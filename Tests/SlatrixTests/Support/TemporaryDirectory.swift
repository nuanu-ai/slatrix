import CoreGraphics
import Foundation
import ImageIO

/// A private scratch folder per test, removed when the test releases it.
final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SlatrixTests-" + UUID().uuidString, isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }

    func file(_ name: String, _ contents: Data = Data("Fixture content\n".utf8)) throws -> URL {
        let file = path(name)
        try contents.write(to: file)
        return file
    }

    /// A PNG filled with one red, which a pixel check can find on screen, or blue on its right half when `halves`.
    /// `orientation` is its EXIF orientation.
    func png(_ name: String, width: Int, height: Int, orientation: Int = 1, halves: Bool = false) throws -> URL {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if halves {
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        }
        let file = path(name)
        let destination = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    /// A file that reports `bytes` in size without using the disk space.
    func sparse(_ name: String, bytes: Int) throws -> URL {
        let file = path(name)
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return file
    }
}

func posixPermissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}
