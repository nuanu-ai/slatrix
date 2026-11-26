import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO

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
            let image = NSImage(data: data), !image.representations.isEmpty,
            image.size.width.isFinite, image.size.height.isFinite,
            image.size.width > 0, image.size.height > 0
        else { return nil }
        return (UInt64(image.size.width.rounded()), UInt64(image.size.height.rounded()))
    }

    nonisolated private static func rasterizeSVG(_ data: Data, maxPixels: Int) -> CGImage? {
        guard let image = NSImage(data: data), !image.representations.isEmpty else { return nil }
        let intrinsic = image.size
        guard intrinsic.width.isFinite, intrinsic.height.isFinite, intrinsic.width > 0, intrinsic.height > 0 else {
            return nil
        }
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
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        return bitmap.cgImage
    }
}
