import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The sample Design channel's attachments, drawn on the spot so they look real without a server.
@MainActor enum PreviewMedia {
    static let roomID = "preview.room.2"

    static func messages(roomID: String, members: [ChatUser], now: Date) -> [ChatMessage] {
        func media(
            _ id: String, _ sender: Int, kind: String, caption: String? = nil, _ attachment: MessageAttachment,
            _ minutes: Double
        ) -> ChatMessage {
            ChatMessage(
                id: id, roomID: roomID, senderID: members[sender].id, senderName: members[sender].name,
                body: caption ?? attachment.name, timestamp: now.addingTimeInterval(-minutes * 60), kind: kind,
                attachment: attachment, mediaCaption: caption)
        }
        return [
            media(
                "preview.photo", 1, kind: "m.image", caption: "First pass at the launch hero. Thoughts?",
                MessageAttachment(
                    name: "launch-hero.png", url: "preview://launch-hero.png", mimeType: "image/png", size: 1_840_000,
                    width: 1_600, height: 900), 95),
            media(
                "preview.gif", 2, kind: "m.image", caption: "When the build goes green",
                MessageAttachment(
                    name: "bounce.gif", url: "preview://bounce.gif", mimeType: "image/gif", size: 220_000, width: 480,
                    height: 270, animated: true), 80),
            media(
                "preview.video", 0, kind: "m.video",
                MessageAttachment(
                    name: "onboarding-walkthrough.mov", url: "preview://walkthrough.mov", mimeType: "video/quicktime",
                    size: 48_200_000, width: 1_280, height: 720, duration: 83), 60),
            media(
                "preview.pdf", 1, kind: "m.file",
                MessageAttachment(
                    name: "Brand guidelines.pdf", url: "preview://guidelines.pdf", mimeType: "application/pdf",
                    size: 2_400_000), 45),
            media(
                "preview.zip", 3, kind: "m.file",
                MessageAttachment(
                    name: "icons-export.zip", url: "preview://icons.zip", mimeType: "application/zip",
                    size: 18_300_000), 30),
        ]
    }

    /// The sample's thumbnail: the GIF itself, a photo or a video poster.
    static func thumbnail(_ attachment: MessageAttachment) -> Data? {
        switch attachment.url {
        case "preview://launch-hero.png": png(landscape(width: 960, height: 540))
        case "preview://bounce.gif": gif
        case "preview://walkthrough.mov": png(poster(width: 960, height: 540))
        default: nil
        }
    }

    /// The sample as a downloaded file; the video has none.
    static func file(_ attachment: MessageAttachment) -> URL? {
        let data: Data? =
            switch attachment.url {
            case "preview://launch-hero.png": png(landscape(width: 1_600, height: 900))
            case "preview://bounce.gif": gif
            case "preview://guidelines.pdf": pdf
            // An empty archive.
            case "preview://icons.zip": Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
            default: nil
            }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Slatrix Preview")
        let url = directory.appendingPathComponent(attachment.name)
        guard let data,
            (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
            (try? data.write(to: url)) != nil
        else { return nil }
        return url
    }

    private static func drawing(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(context)
        return context.makeImage()
    }

    private static func color(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    private static func gradient(_ context: CGContext, top: UInt32, bottom: UInt32, height: Int) {
        guard
            let gradient = CGGradient(colorsSpace: nil, colors: [color(bottom), color(top)] as CFArray, locations: nil)
        else { return }
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    }

    /// A shape rising from the bottom edge through `peaks`, given as fractions of the canvas.
    private static func ridge(_ context: CGContext, _ fill: UInt32, _ peaks: [(CGFloat, CGFloat)], in size: CGSize) {
        context.setFillColor(color(fill))
        let points = [(0, 0)] + peaks + [(1, 0)]
        context.addLines(between: points.map { CGPoint(x: $0.0 * size.width, y: $0.1 * size.height) })
        context.closePath()
        context.fillPath()
    }

    /// Dusk over hills.
    private static func landscape(width: Int, height: Int) -> CGImage? {
        drawing(width: width, height: height) { context in
            let size = CGSize(width: width, height: height)
            gradient(context, top: 0x6f7bd9, bottom: 0xf7b48a, height: height)
            context.setFillColor(color(0xffe2a8))
            context.fillEllipse(
                in: CGRect(
                    x: size.width * 0.62, y: size.height * 0.4, width: size.height * 0.24, height: size.height * 0.24))
            ridge(context, 0x8e6fb5, [(0, 0.35), (0.3, 0.68), (0.55, 0.42), (1, 0.6)], in: size)
            ridge(context, 0x4f4a8c, [(0, 0.22), (0.4, 0.45), (0.75, 0.25), (1, 0.36)], in: size)
            ridge(context, 0x2c2f5e, [(0, 0.12), (0.5, 0.2), (1, 0.1)], in: size)
        }
    }

    /// A paused frame of an app walkthrough: a window on a dark desk.
    private static func poster(width: Int, height: Int) -> CGImage? {
        drawing(width: width, height: height) { context in
            let w = CGFloat(width)
            let h = CGFloat(height)
            gradient(context, top: 0x1d2b4a, bottom: 0x0e1424, height: height)
            let window = CGRect(x: w * 0.15, y: h * 0.12, width: w * 0.7, height: h * 0.76)
            context.setFillColor(color(0xf4f5f7))
            context.fill(window)
            context.setFillColor(color(0x3f0e40))
            context.fill(CGRect(x: window.minX, y: window.minY, width: window.width * 0.24, height: window.height))
            context.setFillColor(color(0xd0d3da))
            for row in 0..<6 {
                context.fill(
                    CGRect(
                        x: window.minX + window.width * 0.3,
                        y: window.maxY - window.height * (0.16 + CGFloat(row) * 0.13),
                        width: window.width * 0.55, height: h * 0.025))
            }
        }
    }

    private static func png(_ image: CGImage?) -> Data? { image.flatMap { encode([$0], as: .png, delay: nil) } }

    /// A ball bouncing in three frames, slow enough that a snapshot settles between them.
    private static let gif: Data? = encode(
        [0.15, 0.55, 0.3].compactMap { lift in
            drawing(width: 480, height: 270) { context in
                gradient(context, top: 0x2bac76, bottom: 0x1f8f55, height: 270)
                context.setFillColor(color(0xffffff))
                context.fillEllipse(in: CGRect(x: 190, y: 30 + 140 * lift, width: 100, height: 100))
            }
        }, as: .gif, delay: 2)

    private static func encode(_ images: [CGImage], as type: UTType, delay: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)
        else { return nil }
        if delay != nil {
            CGImageDestinationSetProperties(
                destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for image in images {
            let frame = delay.map { [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: $0]] }
            CGImageDestinationAddImage(destination, image, frame as CFDictionary?)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// One page: a red title band over lines of text.
    private static let pdf: Data? = {
        let data = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &page, nil)
        else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(color(0xd93a3a))
        context.fill(CGRect(x: 0, y: 652, width: 612, height: 140))
        context.setFillColor(color(0xd0d3da))
        for line in 0..<18 {
            context.fill(CGRect(x: 72, y: 590 - CGFloat(line) * 28, width: line % 5 == 4 ? 300 : 468, height: 10))
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }()
}
