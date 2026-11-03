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

/// The message the media viewer shows, if it is open.
@Observable @MainActor final class MediaViewerState {
    private(set) var message: ChatMessage?
    /// The window's video playing in its row, which holds while the viewer shows anything full size.
    let inlineVideo = InlineVideo()
    private(set) var surface = MessageActionTarget.Surface.conversation
    /// The Files list it was opened from, in the list's order; nil for a timeline.
    private(set) var files: [ChatMessage]?

    func open(_ message: ChatMessage, surface: MessageActionTarget.Surface) {
        inlineVideo.pause()
        self.surface = surface
        files = nil
        self.message = message
    }

    func open(_ message: ChatMessage, files: [ChatMessage]) {
        inlineVideo.pause()
        surface = .conversation
        self.files = files
        self.message = message
    }

    func close() { message = nil }

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

    /// Follows the message as its timeline or Files list changes, and closes once it is deleted, replaced or gone.
    func update(from messages: [ChatMessage]) {
        guard let current = message else { return }
        if let files {
            self.files = files.compactMap { file in messages.first { $0.eventID == file.eventID } }
        }
        if let found = messages.first(where: { $0.eventID == current.eventID }), !found.isRedacted,
            found.attachment == current.attachment
        {
            if found != current { message = found }
        } else {
            close()
        }
    }
}
