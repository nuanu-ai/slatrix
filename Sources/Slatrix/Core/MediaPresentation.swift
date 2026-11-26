import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import MatrixRustSDK
import UniformTypeIdentifiers

/// What a file is, for the colored tile and the type on its card.
enum FileKind: CaseIterable {
    case pdf, document, spreadsheet, presentation, archive, code, audio, video, image, generic

    /// The extension decides, since senders often label files `application/octet-stream`; the MIME type is the
    /// fallback.
    init(name: String, mimeType: String?) {
        if let kind = Self.extensions[(name as NSString).pathExtension.lowercased()] {
            self = kind
            return
        }
        let mime = mimeType?.lowercased() ?? ""
        self = Self.mimeTypes.first { mime.contains($0.0) }?.1 ?? .generic
    }

    var label: String {
        switch self {
        case .pdf: "PDF"
        case .document: "Document"
        case .spreadsheet: "Spreadsheet"
        case .presentation: "Presentation"
        case .archive: "Archive"
        case .code: "Code"
        case .audio: "Audio"
        case .video: "Video"
        case .image: "Image"
        case .generic: "File"
        }
    }

    private static let extensions: [String: FileKind] = Dictionary(
        uniqueKeysWithValues: [
            (FileKind.pdf, "pdf"),
            (.document, "doc docx pages odt rtf txt md"),
            (.spreadsheet, "xls xlsx numbers ods csv tsv"),
            (.presentation, "ppt pptx key odp"),
            (.archive, "zip gz tgz tar rar 7z bz2 xz dmg"),
            (.code, "swift js ts py rb go rs java kt c h cpp m json yaml yml xml html css sh sql"),
            (.audio, "mp3 m4a wav aac ogg opus flac"),
            (.video, "mp4 mov m4v webm mkv avi"),
            (.image, "png jpg jpeg gif heic webp tiff bmp svg"),
        ].flatMap { kind, names in names.split(separator: " ").map { (String($0), kind) } })

    /// In order: the first fragment the MIME type contains wins.
    private static let mimeTypes: [(String, FileKind)] = [
        ("pdf", .pdf), ("spreadsheet", .spreadsheet), ("ms-excel", .spreadsheet), ("csv", .spreadsheet),
        ("presentation", .presentation), ("ms-powerpoint", .presentation), ("wordprocessing", .document),
        ("msword", .document), ("rtf", .document), ("text/plain", .document), ("zip", .archive), ("tar", .archive),
        ("rar", .archive), ("7z", .archive), ("json", .code), ("javascript", .code), ("xml", .code), ("html", .code),
        ("text/x-", .code), ("audio/", .audio), ("video/", .video), ("image/", .image),
    ]
}

enum FileName {
    /// The name cut in the middle to the longest that `fits`, as Finder cuts it, but never with the ellipsis beside a
    /// dot, where the two read as four dots.
    static func middleTruncated(_ name: String, fits: (String) -> Bool) -> String {
        guard !fits(name) else { return name }
        let characters = Array(name)
        func cut(_ kept: Int) -> String {
            var head = characters.prefix((kept + 1) / 2)
            var tail = characters.suffix(kept / 2)
            while head.last == "." { head.removeLast() }
            while tail.first == "." { tail.removeFirst() }
            return String(head) + "…" + String(tail)
        }
        var best = 0
        var (low, high) = (1, characters.count - 1)
        while low <= high {
            let kept = (low + high) / 2
            if fits(cut(kept)) {
                best = kept
                low = kept + 1
            } else {
                high = kept - 1
            }
        }
        return cut(best)
    }
}

extension MessageAttachment {
    var fileKind: FileKind { FileKind(name: name, mimeType: mimeType) }
    /// "PDF", or the extension in capitals, as a file card shows it.
    var typeLabel: String {
        let ext = (name as NSString).pathExtension
        return fileKind == .pdf || ext.isEmpty ? fileKind.label : ext.uppercased()
    }
}

extension ChatMessage {
    /// An image, GIF or video shown inline, which the media viewer steps through.
    var isViewerMedia: Bool { !isRedacted && attachment != nil && (kind == "m.image" || kind == "m.video") }
}

/// The box an inline image or video poster takes in its row, decided before anything loads.
enum MediaBox {
    /// Fits `width`×`height` pixels within `bounds` at their aspect, never enlarged. Without a size it reserves a 4:3
    /// box three quarters of the bounds' height, and the image fits inside it once it loads.
    static func fit(width: UInt64?, height: UInt64?, within bounds: CGSize) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            let height = bounds.height * 3 / 4
            return CGSize(width: min(bounds.width, height * 4 / 3), height: height)
        }
        let w = CGFloat(width)
        let h = CGFloat(height)
        if w <= bounds.width && h <= bounds.height { return CGSize(width: w, height: h) }
        if w / h > bounds.width / bounds.height {
            return CGSize(width: bounds.width, height: bounds.width * h / w)
        }
        return CGSize(width: bounds.height * w / h, height: bounds.height)
    }
}

enum MediaViewerNavigation {
    /// The file `offset` steps from `eventID`, or nil past either end: in a timeline its images and videos, in a
    /// Files list every file, since the viewer previews documents too.
    static func neighbor(of eventID: String, by offset: Int, in messages: [ChatMessage], files: Bool = false)
        -> ChatMessage?
    {
        let media = messages.filter { files ? $0.attachment != nil && !$0.isRedacted : $0.isViewerMedia }
        guard let index = media.firstIndex(where: { $0.eventID == eventID }), media.indices.contains(index + offset)
        else { return nil }
        return media[index + offset]
    }
}

/// Reload key for an open media viewer page: changes when the server event or its remote media source lands.
struct MediaViewerLoadKey: Hashable {
    let eventID: String
    let sendState: String
    let attachmentURL: String?
    let sourceRevision: Data?

    init(message: ChatMessage, sourceRevision: Data?) {
        eventID = message.eventID
        sendState = message.sendState
        attachmentURL = message.attachment?.url
        self.sourceRevision = sourceRevision
    }
}

/// The message the media viewer shows, if it is open.
@Observable @MainActor final class MediaViewerState {
    private(set) var message: ChatMessage?
    /// The window's video playing in its row, which holds while the viewer shows anything full size.
    let inlineVideo = InlineVideo()
    private(set) var surface = MessageActionTarget.Surface.conversation
    /// The Files list it was opened from, in the list's order; nil for a timeline.
    private(set) var files: [ChatMessage]?
    /// Where the row's video was as the viewer opened on it.
    @ObservationIgnored private var carried: (eventID: String, time: CMTime)?

    func open(_ message: ChatMessage, surface: MessageActionTarget.Surface) {
        carry(message)
        self.surface = surface
        files = nil
        self.message = message
    }

    func open(_ message: ChatMessage, files: [ChatMessage]) {
        carry(message)
        surface = .conversation
        self.files = files
        self.message = message
    }

    func close() { message = nil }

    /// Where the viewer starts `message`'s video: where its row left it, as Slack carries a video on, or the top.
    func videoStart(_ message: ChatMessage) -> CMTime {
        carried.flatMap { $0.eventID == message.eventID ? $0.time : nil } ?? .zero
    }

    /// Holds the row's video while the viewer shows anything, noting where it was if the viewer shows that video.
    private func carry(_ message: ChatMessage) {
        inlineVideo.pause()
        carried =
            inlineVideo.eventID == message.eventID
            ? inlineVideo.player.map { (message.eventID, $0.currentTime()) } : nil
    }

    /// The file `offset` steps away: in the Files list it came from, or else in `messages`, its timeline.
    func neighbor(_ offset: Int, in messages: [ChatMessage]) -> ChatMessage? {
        message.flatMap {
            MediaViewerNavigation.neighbor(of: $0.eventID, by: offset, in: files ?? messages, files: files != nil)
        }
    }

    /// Stays put at either end.
    func step(_ offset: Int, in messages: [ChatMessage]) {
        if let next = neighbor(offset, in: messages) { message = next }
    }

    /// Truthful placeholder copy for unsent/failed attachments in the viewer; nil when an image can show its cached still.
    static func pendingNotice(for message: ChatMessage, hasCachedStill: Bool) -> String? {
        guard message.sendState != "sent" else { return nil }
        if message.sendState == "failed" { return "Couldn’t send." }
        if !message.isViewerMedia { return "Available once sent." }
        if message.kind == "m.video" || !hasCachedStill { return "Still sending…" }
        return nil
    }

    /// Follows the message as its timeline or Files list changes, and closes once it is deleted, replaced or gone.
    func update(from messages: [ChatMessage]) {
        guard let current = message else { return }
        if let files {
            self.files = files.compactMap { file in messages.first { $0.eventID == file.eventID } }
        }
        // A pending local echo keeps its timeline `id` when its server event lands, while `eventID` switches from
        // transaction ID to server event ID and attachment URL switches from local file path to `mxc://`.
        if current.sendState != "sent",
            let found = messages.first(where: { $0.id == current.id || $0.eventID == current.eventID }),
            !found.isRedacted, found.attachment != nil
        {
            if found != current { message = found }
        } else if let found = messages.first(where: { $0.eventID == current.eventID }), !found.isRedacted,
            found.attachment == current.attachment
        {
            if found != current { message = found }
        } else {
            close()
        }
    }
}

/// Decodes image attachments to a displayable `CGImage`, using ImageIO for raster formats and AppKit's native SVG
/// renderer strictly for SVG payloads (never PDF/EPS).
enum MediaImageDecoder {
    nonisolated static func isSVGAttachment(name: String, mimeType: String?) -> Bool {
        if let mime = mimeType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
            mime == "image/svg+xml"
        {
            return true
        }
        return (name as NSString).pathExtension.lowercased() == "svg"
    }

    nonisolated static func looksLikeSVG(_ data: Data) -> Bool {
        var bytes = data.prefix(2_048)
        // Strip optional UTF-8 BOM.
        if bytes.count >= 3, bytes[bytes.startIndex] == 0xEF,
            bytes[bytes.index(after: bytes.startIndex)] == 0xBB,
            bytes[bytes.index(bytes.startIndex, offsetBy: 2)] == 0xBF
        {
            bytes = bytes.dropFirst(3)
        }
        guard let head = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .ascii) else {
            return false
        }
        let trimmed = head.drop { $0.isWhitespace }.lowercased()
        if trimmed.hasPrefix("<svg") {
            let after = trimmed.dropFirst(4).first
            return after == nil || after == ">" || after == "/" || after?.isWhitespace == true
        }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!--") || trimmed.hasPrefix("<!doctype") {
            return trimmed.range(of: #"<svg(?=[\s>/]|$)"#, options: .regularExpression) != nil
        }
        return false
    }

    nonisolated static func decodeStill(_ data: Data, maxPixels: Int = 960) -> CGImage? {
        let clamped = max(1, maxPixels)
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: clamped,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        {
            return image
        }
        guard looksLikeSVG(data) else { return nil }
        return rasterizeSVG(data, maxPixels: clamped)
    }

    nonisolated static func svgDimensions(_ url: URL) -> (width: UInt64, height: UInt64)? {
        guard url.pathExtension.lowercased() == "svg",
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size > 0, size <= Int(MatrixMapping.maximumAutomaticPreviewBytes),
            let data = try? Data(contentsOf: url), looksLikeSVG(data),
            let intrinsic = svgIntrinsicSize(data, image: NSImage(data: data))
        else { return nil }
        return (UInt64(intrinsic.width.rounded()), UInt64(intrinsic.height.rounded()))
    }

    /// Decodes a full-resolution image for `MediaViewer`: upright via EXIF transform for raster formats, animated
    /// frames preserved for multi-frame GIFs, and sharp contrast-matted rasterization for SVGs.
    nonisolated static func decodeFullImage(_ data: Data) -> NSImage? {
        if looksLikeSVG(data) {
            return rasterizeSVG(data, maxPixels: 2_048).map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0
        {
            if CGImageSourceGetCount(source) > 1 { return NSImage(data: data) }
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any]
            let width = (properties?[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (properties?[kCGImagePropertyPixelHeight] as? Int) ?? 0
            let maxSide = max(width, height)
            if maxSide > 0,
                let cg = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxSide,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
            {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSImage(data: data)
    }

    nonisolated static func isAnimatedImage(_ url: URL) -> Bool {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    /// Generates a small upright JPEG thumbnail in a temporary file so large (>10 MiB) or HEIC/TIFF uploads still
    /// display an instant preview everywhere.
    nonisolated static func imageThumbnail(of url: URL, maxPixels: Int = 960) -> (url: URL, info: ThumbnailInfo)? {
        let cgImage: CGImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
            cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels),
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        } else if url.pathExtension.lowercased() == "svg",
            let data = try? Data(contentsOf: url), looksLikeSVG(data)
        {
            cgImage = rasterizeSVG(data, maxPixels: maxPixels)
        } else {
            cgImage = nil
        }
        guard let cgImage else { return nil }
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination), encoded.length > 0, encoded.length <= 512 * 1_024 else {
            return nil
        }
        let temp = AppPaths.temporary.appendingPathComponent("slatrix-thumb-\(UUID().uuidString).jpg")
        guard
            FileManager.default.createFile(
                atPath: temp.path, contents: encoded as Data, attributes: [.posixPermissions: 0o600])
        else { return nil }
        let info = ThumbnailInfo(
            height: UInt64(cgImage.height), width: UInt64(cgImage.width), mimetype: "image/jpeg",
            size: UInt64(encoded.length))
        return (temp, info)
    }

    nonisolated private static func svgIntrinsicSize(_ data: Data, image: NSImage?) -> CGSize? {
        if let image, !image.representations.isEmpty,
            image.size.width.isFinite, image.size.height.isFinite, image.size.width > 0, image.size.height > 0
        {
            return image.size
        }
        return svgViewBoxSize(data)
    }

    nonisolated private static func svgViewBoxSize(_ data: Data) -> CGSize? {
        let head = String(decoding: data.prefix(4_096), as: UTF8.self)
        let num = #"[+-]?[\d.eE+-]+"#
        let pattern = "(?i)viewBox\\s*=\\s*[\"']\\s*\(num)[\\s,]+\(num)[\\s,]+(\(num))[\\s,]+(\(num))\\s*[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
            let wRange = Range(match.range(at: 1), in: head),
            let hRange = Range(match.range(at: 2), in: head),
            let width = Double(head[wRange]), let height = Double(head[hRange]),
            width.isFinite, height.isFinite, width > 0, height > 0
        else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func rasterizeSVG(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let image = NSImage(data: data), !image.representations.isEmpty,
            let intrinsic = svgIntrinsicSize(data, image: image)
        else { return nil }
        if image.size.width <= 0 || image.size.height <= 0 { image.size = intrinsic }
        let longest = max(intrinsic.width, intrinsic.height)
        let scale = CGFloat(maxPixels) / longest
        let width = max(1, min(maxPixels, Int((intrinsic.width * scale).rounded())))
        let height = max(1, min(maxPixels, Int((intrinsic.height * scale).rounded())))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return applyContrastMatteIfTransparent(bitmap)
    }

    /// Adds a subtle light or dark surface behind transparent SVGs so dark-ink diagrams stay legible in Dark Mode and
    /// `MediaViewer` (and light-ink icons stay legible in Light Mode), while leaving opaque SVGs untouched.
    nonisolated private static func applyContrastMatteIfTransparent(_ bitmap: NSBitmapImageRep) -> CGImage? {
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        guard width > 0, height > 0 else { return bitmap.cgImage }
        let steps = 16
        var borderAlphaSum: CGFloat = 0
        var borderCount = 0
        var fgLuminanceSum: CGFloat = 0
        var fgCount = 0
        for row in 0..<steps {
            let y = min(height - 1, (row * (height - 1)) / max(1, steps - 1))
            for col in 0..<steps {
                let x = min(width - 1, (col * (width - 1)) / max(1, steps - 1))
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let alpha = color.alphaComponent
                if row == 0 || row == steps - 1 || col == 0 || col == steps - 1 {
                    borderAlphaSum += alpha
                    borderCount += 1
                }
                if alpha > 0.15 {
                    fgLuminanceSum +=
                        0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                    fgCount += 1
                }
            }
        }
        guard borderCount > 0, borderAlphaSum / CGFloat(borderCount) < 0.75, fgCount > 0 else {
            return bitmap.cgImage
        }
        let averageLuminance = fgLuminanceSum / CGFloat(fgCount)
        let matte =
            averageLuminance < 0.45
            ? NSColor(srgbRed: 0.96, green: 0.965, blue: 0.973, alpha: 1)
            : NSColor(srgbRed: 0.11, green: 0.118, blue: 0.133, alpha: 1)
        guard
            let composited = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: composited)
        else { return bitmap.cgImage }
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        matte.setFill()
        rect.fill()
        bitmap.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return composited.cgImage
    }
}
