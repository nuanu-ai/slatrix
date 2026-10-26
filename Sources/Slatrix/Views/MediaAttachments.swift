import AppKit
import ImageIO
import SwiftUI

/// What an attachment does besides downloading, bound to its message by the timeline.
struct AttachmentActions {
    /// Opens the media viewer.
    var open: () -> Void = {}
    var forward: (() -> Void)?
    var copyLink: (() -> Void)?
}

/// An attachment as Slack shows it: images, GIFs and videos inline under their name, other files as a card.
struct AttachmentView: View {
    let matrix: MatrixService
    let message: ChatMessage
    let attachment: MessageAttachment
    var collapsed = false
    var actions = AttachmentActions()

    var body: some View {
        Group {
            if message.isViewerMedia {
                InlineMedia(
                    matrix: matrix, message: message, attachment: attachment, collapsed: collapsed, actions: actions)
            } else {
                FileCard(matrix: matrix, message: message, attachment: attachment, actions: actions)
            }
        }
        // An edit that replaces the file starts over: nothing loaded for the old one carries across.
        .id(attachment)
    }
}

/// Saving and opening attachment files, for rows and the media viewer. Failures land in the window's error toast.
@Observable @MainActor final class AttachmentFiles {
    static let shared = AttachmentFiles()
    /// Where each attachment was saved this session, by event ID, for "Show in Finder".
    private(set) var saved: [String: URL] = [:]

    func download(_ message: ChatMessage, matrix: MatrixService) async {
        guard let attachment = message.attachment else { return }
        let session = matrix.notificationSessionID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SharedContentMapping.safeFilename(attachment.name)
        panel.title = "Save attachment"
        guard panel.runModal() == .OK, let destination = panel.url, matrix.notificationSessionID == session else {
            return
        }
        do {
            let lease = try await matrix.prepareAttachmentPreview(message)
            defer { withExtendedLifetime(lease) {} }
            guard matrix.notificationSessionID == session, lease.isCurrent else { throw CancellationError() }
            let temporary = lease.url
            try await Task.detached(priority: .userInitiated) {
                let staging = destination.deletingLastPathComponent().appendingPathComponent(
                    ".slatrix-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: temporary, to: staging)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: destination)
                }
            }.value
            guard matrix.notificationSessionID == session else { return }
            saved[message.eventID] = destination
        } catch is CancellationError {} catch {
            if matrix.notificationSessionID == session { matrix.errorMessage = MatrixService.safeError(error) }
        }
    }

    /// Opens the file in the app macOS picks for it.
    func open(_ message: ChatMessage, matrix: MatrixService) async {
        let session = matrix.notificationSessionID
        do {
            let lease = try await matrix.prepareAttachmentPreview(message)
            guard matrix.notificationSessionID == session, lease.isCurrent else { return }
            NSWorkspace.shared.open(lease.url)
        } catch is CancellationError {} catch {
            if matrix.notificationSessionID == session { matrix.errorMessage = MatrixService.safeError(error) }
        }
    }

    func showInFinder(_ message: ChatMessage) {
        guard let url = saved[message.eventID], FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension MatrixService {
    /// A decoded still of the attachment already in memory: its thumbnail, a GIF's first frame, a video's poster.
    func cachedMediaImage(_ message: ChatMessage) -> CGImage? {
        mediaImageKey(message).flatMap { mediaImages.object(forKey: $0) }
    }

    /// Loads, decodes and remembers the attachment's still; nil when it has none or it went away meanwhile.
    func loadMediaImage(_ message: ChatMessage) async -> CGImage? {
        guard let key = mediaImageKey(message) else { return nil }
        if let image = mediaImages.object(forKey: key) { return image }
        guard let data = try? await thumbnailData(message, width: 960, height: 720) else { return nil }
        let image = await Task.detached(priority: .utility) { Self.decodeStill(data) }.value
        guard let image, mediaImageKey(message) == key else { return nil }
        mediaImages.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    private func mediaImageKey(_ message: ChatMessage) -> NSString? {
        attachmentSourceRevision(message).map {
            "\(message.eventID)|\(String(decoding: $0, as: UTF8.self))" as NSString
        }
    }

    nonisolated private static func decodeStill(_ data: Data) -> CGImage? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }

    /// The whole file as an image, which keeps a GIF's frames.
    func loadFullImage(_ message: ChatMessage) async throws -> NSImage {
        let lease = try await prepareAttachmentPreview(message)
        let url = lease.url
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        guard lease.isCurrent, let image = NSImage(data: data) else { throw CancellationError() }
        return image
    }
}

/// An image, GIF or video in a row: a muted "name ▾" line that hides it, then the picture in a box reserved from
/// the event's size, so nothing moves when it loads.
private struct InlineMedia: View {
    private static let bounds = CGSize(width: 480, height: 360)
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appearance: AppearanceStore
    let matrix: MatrixService
    let message: ChatMessage
    let attachment: MessageAttachment
    let collapsed: Bool
    let actions: AttachmentActions
    @State private var still: CGImage?
    @State private var animation: NSImage?
    /// Under Reduce Motion a GIF waits for a click.
    @State private var playing = false
    @State private var hovering = false
    @State private var downloading = false
    private var colors: AppColors { appearance.colors }
    private var isVideo: Bool { message.kind == "m.video" }
    private var animates: Bool { attachment.animated && (playing || !reduceMotion) }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp4) {
            Button {
                matrix.collapsedMedia.formSymmetricDifference([message.eventID])
            } label: {
                HStack(spacing: m.sp4) {
                    Text(attachment.name).lineLimit(1).truncationMode(.middle)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(m.font(.caption, .semibold))
                }.font(m.font(.meta)).foregroundStyle(colors.textSecondary)
            }.buttonStyle(.row).help(collapsed ? "Show" : "Hide")
                .accessibilityLabel("\(collapsed ? "Show" : "Hide") \(attachment.name)")
            if !collapsed { media }
        }
    }

    private var media: some View {
        let box = MediaBox.fit(
            width: attachment.width, height: attachment.height,
            within: CGSize(width: m(Self.bounds.width), height: m(Self.bounds.height)))
        let shape = RoundedRectangle(cornerRadius: m.radiusLarge)
        let shown = still ?? matrix.cachedMediaImage(message)
        return Button(action: click) {
            shape.fill(colors.sunken)
                .overlay {
                    if let animation {
                        MediaImage(image: animation, animates: true)
                    } else if let shown {
                        MediaImage(image: NSImage(cgImage: shown, size: .zero)).transition(.opacity)
                    }
                }
                .overlay { if isVideo { playBadge } }
                .overlay(alignment: .bottomLeading) { badge.padding(m.sp8) }
                .clipShape(shape)
                .overlay(shape.strokeBorder(colors.border))
                .aspectRatio(box.width / box.height, contentMode: .fit)
                .frame(maxWidth: box.width)
        }
        .buttonStyle(.row).help(attachment.name).accessibilityLabel("Open \(attachment.name)")
        .accessibilityAction(named: "Download") {
            Task { await AttachmentFiles.shared.download(message, matrix: matrix) }
        }
        .overlay(alignment: .topTrailing) {
            if hovering || downloading {
                MediaActionsToolbar(
                    matrix: matrix, message: message, actions: actions, downloading: $downloading
                ).padding(m.sp8)
            }
        }
        .onHover { hovering = $0 }
        .task(id: animates) { await load() }
    }

    @ViewBuilder private var badge: some View {
        if isVideo, let duration = attachment.duration {
            chip(
                Duration.seconds(duration).formatted(
                    .time(pattern: duration >= 3_600 ? .hourMinuteSecond : .minuteSecond)))
        } else if attachment.animated && !animates {
            chip("GIF")
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(m.font(.caption, .semibold)).monospacedDigit().foregroundStyle(colors.onMedia)
            .padding(.horizontal, m.sp4 + m.sp2).padding(.vertical, m.sp2)
            .background(colors.mediaControl, in: Capsule())
    }

    private var playBadge: some View {
        Image(systemName: "play.fill").font(m.font(.title)).foregroundStyle(colors.onMedia)
            .frame(width: m.sp40 + m.sp8, height: m.sp40 + m.sp8).background(colors.mediaControl, in: Circle())
    }

    private func click() {
        if attachment.animated && !animates {
            playing = true
        } else {
            actions.open()
        }
    }

    private func load() async {
        if still == nil, matrix.cachedMediaImage(message) == nil, let image = await matrix.loadMediaImage(message),
            !Task.isCancelled
        {
            // Only a picture that wasn't in memory fades in; a cached one is on the first frame.
            withAnimation(Motion.content) { still = image }
        }
        // A large GIF plays when asked, not on its own.
        guard animates, animation == nil,
            playing || MatrixMapping.permitsAutomaticOriginalPreview(size: attachment.size),
            let image = try? await matrix.loadFullImage(message), !Task.isCancelled
        else { return }
        animation = image
    }
}

/// The hover toolbar over an inline image or a file card: download, forward and more.
private struct MediaActionsToolbar: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let matrix: MatrixService
    let message: ChatMessage
    let actions: AttachmentActions
    @Binding var downloading: Bool

    var body: some View {
        let colors = appearance.colors
        let side = MessageToolbar.button
        HStack(spacing: 0) {
            if downloading {
                DelayedProgress().frame(width: m(side), height: m(side))
            } else {
                IconButton(symbol: "arrow.down.to.line", label: "Download", role: .body, side: side) {
                    downloading = true
                    Task {
                        await AttachmentFiles.shared.download(message, matrix: matrix)
                        downloading = false
                    }
                }
            }
            if let forward = actions.forward {
                IconButton(
                    symbol: "arrowshape.turn.up.right", label: "Forward", role: .body, side: side, action: forward)
            }
            Menu {
                AttachmentMenuItems(matrix: matrix, message: message, copyLink: actions.copyLink)
            } label: {
                Image(systemName: "ellipsis").font(m.font(.body)).frame(width: m(side), height: m(side))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: m(side)).help("More actions")
        }.padding(.horizontal, m.sp2).frame(height: m(side))
            .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radius))
            .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.border))
            .elevation(.e1, cornerRadius: m.radius)
    }
}

/// The attachment's ⋮ menu, in a row and in the viewer.
struct AttachmentMenuItems: View {
    let matrix: MatrixService
    let message: ChatMessage
    let copyLink: (() -> Void)?

    var body: some View {
        if let copyLink { Button("Copy link", action: copyLink) }
        Button("Open in default app") { Task { await AttachmentFiles.shared.open(message, matrix: matrix) } }
        if AttachmentFiles.shared.saved[message.eventID] != nil {
            Button("Show in Finder") { AttachmentFiles.shared.showInFinder(message) }
        }
    }
}

/// A file as a card: a colored type tile, its name, and "PDF · 2 MB". A click opens it in the viewer.
private struct FileCard: View {
    private static let maxWidth: CGFloat = 420
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let matrix: MatrixService
    let message: ChatMessage
    let attachment: MessageAttachment
    let actions: AttachmentActions
    @State private var hovering = false
    @State private var downloading = false

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radiusLarge)
        Button(action: actions.open) {
            HStack(spacing: m.sp12) {
                FileTypeIcon(kind: attachment.fileKind)
                VStack(alignment: .leading, spacing: m.sp2) {
                    Text(attachment.name).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(caption).font(m.font(.secondary)).foregroundStyle(colors.textSecondary).lineLimit(1)
                }
                Spacer(minLength: m.sp8)
            }
            .padding(m.sp12).frame(maxWidth: m(Self.maxWidth), alignment: .leading)
            .background(colors.canvas, in: shape).overlay(shape.strokeBorder(colors.border))
        }
        .buttonStyle(.row).help("Open \(attachment.name)")
        .overlay(alignment: .topTrailing) {
            if hovering || downloading {
                MediaActionsToolbar(matrix: matrix, message: message, actions: actions, downloading: $downloading)
                    .padding(m.sp8)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Download") {
            Task { await AttachmentFiles.shared.download(message, matrix: matrix) }
        }
    }

    private var caption: String {
        ([attachment.typeLabel]
            + (attachment.size.map {
                [ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)]
            }
                ?? []))
            .joined(separator: " · ")
    }
}

/// A file type as a colored tile with a white glyph.
struct FileTypeIcon: View {
    let kind: FileKind
    /// The tile's side at 100% zoom.
    var side: CGFloat = 40
    var glyph: TextRole = .title
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        RoundedRectangle(cornerRadius: m.radius).fill(colors.file(kind))
            .overlay(Image(systemName: kind.symbol).font(m.font(glyph, .semibold)).foregroundStyle(colors.onMedia))
            .frame(width: m(side), height: m(side)).accessibilityHidden(true)
    }
}

extension FileKind {
    fileprivate var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .document: "doc.text.fill"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "chart.pie.fill"
        case .archive: "doc.zipper"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .audio: "waveform"
        case .video: "film.fill"
        case .image: "photo.fill"
        case .generic: "doc.fill"
        }
    }
}

/// An image that fills the box it is given at its own aspect. A GIF plays only while it is in a window, so a row
/// scrolled away or reused stops it.
struct MediaImage: NSViewRepresentable {
    let image: NSImage
    var animates = false

    func makeNSView(context: Context) -> MediaImageView {
        let view = MediaImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.isEditable = false
        return view
    }

    func updateNSView(_ view: MediaImageView, context: Context) {
        if view.image !== image { view.image = image }
        view.playing = animates
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MediaImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class MediaImageView: NSImageView {
    var playing = false {
        didSet { update() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        update()
    }
    private func update() {
        let animate = playing && window != nil
        if animates != animate { animates = animate }
    }
    /// Clicks belong to the button around it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
