import AVFoundation
import Foundation
import ImageIO
import MatrixRustSDK
import UniformTypeIdentifiers

/// What sending a video puts in its event, as Slack's videos carry: its size as shown, its length and a poster, so others
/// can reserve its box and show it before it plays. The cases are in spec/video-upload.json.
enum VideoUpload {
    static let posterMaxPixels = 800
    static let posterAtMillis = 1_000
    static let posterMimetype = "image/jpeg"
    private static let posterQuality = 0.8

    struct Poster {
        var width: Int
        var height: Int
        var size: UInt64
    }

    /// The video's size as shown: a track turned a quarter swaps its sides.
    static func shown(width: Int?, height: Int?, rotation: Int) -> (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        return rotation % 180 != 0 ? (height, width) : (width, height)
    }

    /// When the poster is taken: a second in, or halfway through a shorter clip; the start when the length isn't known.
    static func posterAt(durationMillis: Int?) -> Int { durationMillis.map { min(posterAtMillis, $0 / 2) } ?? 0 }

    /// The poster's size: the video's shape, at most `posterMaxPixels` on its longer side and never enlarged.
    static func posterSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let scale = min(1, Double(posterMaxPixels) / Double(max(width, height)))
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static func info(
        mimetype: String, size: UInt64, shown: (width: Int, height: Int)?, durationMillis: Int?, poster: Poster?
    )
        -> VideoInfo
    {
        VideoInfo(
            duration: durationMillis.map { TimeInterval($0) / 1_000 }, height: shown.map { UInt64($0.height) },
            width: shown.map { UInt64($0.width) }, mimetype: mimetype, size: size,
            thumbnailInfo: poster.map {
                ThumbnailInfo(
                    height: UInt64($0.height), width: UInt64($0.width), mimetype: posterMimetype, size: $0.size)
            }, thumbnailSource: nil, blurhash: nil)
    }

    /// The video's info and its poster, a JPEG of a frame near the start drawn upright at the poster's size in `folder`.
    /// A video no frame can be read from goes without a poster; one that can't be read at all, as a plain video.
    static func prepare(_ url: URL, mimetype: String, size: UInt64, posterFolder folder: URL) async -> (VideoInfo, URL?)
    {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
            let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return (info(mimetype: mimetype, size: size, shown: nil, durationMillis: nil, poster: nil), nil) }
        let duration = (try? await asset.load(.duration)).flatMap {
            $0.isNumeric ? Int(($0.seconds * 1_000).rounded()) : nil
        }
        let degrees = Int((atan2(transform.b, transform.a) * 180 / .pi).rounded())
        let shown = shown(width: Int(natural.width.rounded()), height: Int(natural.height.rounded()), rotation: degrees)
        var poster: (poster: Poster, url: URL)?
        if let shown {
            poster = await posterFile(
                asset, size: posterSize(width: shown.width, height: shown.height),
                atMillis: posterAt(durationMillis: duration), folder: folder)
        }
        return (
            info(mimetype: mimetype, size: size, shown: shown, durationMillis: duration, poster: poster?.poster),
            poster?.url
        )
    }

    private static func posterFile(_ asset: AVURLAsset, size: (width: Int, height: Int), atMillis: Int, folder: URL)
        async
        -> (poster: Poster, url: URL)?
    {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width, height: size.height)
        let at = CMTime(value: CMTimeValue(atMillis), timescale: 1_000)
        var frame = try? await generator.image(at: at).image
        if frame == nil { frame = try? await generator.image(at: .zero).image }
        guard let frame,
            let context = CGContext(
                data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        // Drawn at exactly the poster's size, which the generator only bounds.
        context.interpolationQuality = .high
        context.draw(frame, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let url = folder.appendingPathComponent("poster-\(UUID().uuidString).jpg")
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: posterQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
        else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (Poster(width: size.width, height: size.height, size: bytes), url)
    }
}
