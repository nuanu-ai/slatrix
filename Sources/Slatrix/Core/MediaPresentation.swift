import CoreGraphics
import Foundation

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
    /// The image or video `offset` steps from `eventID` in timeline order, or nil past either end.
    static func neighbor(of eventID: String, by offset: Int, in messages: [ChatMessage]) -> ChatMessage? {
        let media = messages.filter(\.isViewerMedia)
        guard let index = media.firstIndex(where: { $0.eventID == eventID }), media.indices.contains(index + offset)
        else { return nil }
        return media[index + offset]
    }
}

/// The message the media viewer shows, if it is open.
@Observable @MainActor final class MediaViewerState {
    private(set) var message: ChatMessage?
    private(set) var surface = MessageActionTarget.Surface.conversation

    func open(_ message: ChatMessage, surface: MessageActionTarget.Surface) {
        self.surface = surface
        self.message = message
    }

    func close() { message = nil }

    /// Stays put at either end.
    func step(_ offset: Int, in messages: [ChatMessage]) {
        guard let message, let next = MediaViewerNavigation.neighbor(of: message.eventID, by: offset, in: messages)
        else { return }
        self.message = next
    }

    /// Follows the message as its timeline changes, and closes once it is deleted, replaced or gone.
    func update(from messages: [ChatMessage]) {
        guard let current = message else { return }
        if let found = messages.first(where: { $0.eventID == current.eventID }), !found.isRedacted,
            found.attachment == current.attachment
        {
            if found != current { message = found }
        } else {
            close()
        }
    }
}
