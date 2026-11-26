import AVKit
import AppKit
import SwiftUI

/// What an attachment does besides downloading, bound to its message by the timeline.
struct AttachmentActions {
    /// Opens the media viewer.
    var open: () -> Void = {}
    var forward: (() -> Void)?
    var copyLink: (() -> Void)?
    /// Where a video here plays in place rather than in the viewer.
    var inlineVideo: InlineVideo.Slot?
}

/// An attachment as Slack shows it: images, GIFs and videos inline under their name, other files as a card.
struct AttachmentView: View {
    let matrix: MatrixService
    let message: ChatMessage
    let attachment: MessageAttachment
    var collapsed = false
    var pendingSend = false
    var actions = AttachmentActions()

    var body: some View {
        Group {
            if message.isViewerMedia {
                InlineMedia(
                    matrix: matrix, message: message, attachment: attachment, collapsed: collapsed,
                    pendingSend: pendingSend, actions: actions)
            } else {
                FileCard(
                    matrix: matrix, message: message, attachment: attachment, pendingSend: pendingSend,
                    actions: actions)
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

    /// Opens the file in the app macOS picks for it, from an independent copy so switching rooms never deletes the
    /// file out from under Preview or QuickTime.
    func open(_ message: ChatMessage, matrix: MatrixService) async {
        let session = matrix.notificationSessionID
        let safeName = SharedContentMapping.safeFilename(message.attachment?.name ?? "attachment")
        do {
            let lease = try await matrix.prepareAttachmentPreview(message)
            defer { withExtendedLifetime(lease) {} }
            guard matrix.notificationSessionID == session, lease.isCurrent else { return }
            let source = lease.url
            let (folder, copy) = try await Task.detached(priority: .userInitiated) {
                let root = AppPaths.temporary.appendingPathComponent("OpenedAttachments", isDirectory: true)
                // Prune older external-open copies (older than 24h) so decrypted temp files don't accumulate forever.
                if let entries = try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.contentModificationDateKey])
                {
                    let cutoff = Date().addingTimeInterval(-86_400)
                    for entry in entries {
                        let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate
                        if modified.map({ $0 < cutoff }) ?? true {
                            try? FileManager.default.removeItem(at: entry)
                        }
                    }
                }
                let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let destination = folder.appendingPathComponent(safeName)
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                } catch {
                    try? FileManager.default.removeItem(at: folder)
                    throw error
                }
                return (folder, destination)
            }.value
            guard matrix.notificationSessionID == session else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            if !NSWorkspace.shared.open(copy) {
                try? FileManager.default.removeItem(at: folder)
            }
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
        let image = await Task.detached(priority: .utility) {
            MediaImageDecoder.decodeStill(data, maxPixels: 960)
        }.value
        guard let image, mediaImageKey(message) == key else { return nil }
        mediaImages.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    fileprivate func mediaImageKey(_ message: ChatMessage) -> NSString? {
        // While it sends, `eventID` is its transaction ID. The send queue swaps its local copy for the uploaded one
        // midway, but the picture is the same.
        if message.sendState != "sent" { return "\(message.eventID)|sending" as NSString }
        return attachmentSourceRevision(message).map {
            "\(message.eventID)|\(String(decoding: $0, as: UTF8.self))" as NSString
        }
    }

    /// The whole file as an upright image, preserving GIF frames and rasterizing SVGs cleanly.
    func loadFullImage(_ message: ChatMessage) async throws -> NSImage {
        let lease = try await prepareAttachmentPreview(message)
        let url = lease.url
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        guard lease.isCurrent else { throw CancellationError() }
        let image = await Task.detached(priority: .userInitiated) { MediaImageDecoder.decodeFullImage(data) }.value
        guard lease.isCurrent else { throw CancellationError() }
        guard let image else { throw MatrixServiceError.request("Couldn’t open this image.") }
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
    let pendingSend: Bool
    let actions: AttachmentActions
    @State private var still: CGImage?
    @State private var animation: NSImage?
    @State private var loadFailed = false
    /// Under Reduce Motion a GIF waits for a click.
    @State private var playing = false
    @State private var hovering = false
    @State private var downloading = false
    private var colors: AppColors { appearance.colors }
    private var isVideo: Bool { message.kind == "m.video" }
    private var animates: Bool { attachment.animated && (playing || !reduceMotion) }
    /// Where a video plays in place; nil where a click opens the viewer instead.
    private var inline: InlineVideo.Slot? { isVideo ? actions.inlineVideo : nil }
    private var playsHere: Bool { inline?.isPlaying == true }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp4) {
            Button {
                matrix.collapsedMedia.formSymmetricDifference([message.eventID])
            } label: {
                HStack(spacing: m.sp4) {
                    FileNameText(attachment.name, role: .subheadline)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(
                        m.font(.subheadline, .semibold))
                }.font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
            }.buttonStyle(.row).help(collapsed ? "Show" : "Hide")
                .accessibilityLabel("\(collapsed ? "Show" : "Hide") \(attachment.name)")
                .opacity(pendingSend ? 0.5 : 1)
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
                    } else if loadFailed && !isVideo {
                        VStack(spacing: m.sp8) {
                            Image(systemName: "photo").font(m.font(.title2)).foregroundStyle(colors.textTertiary)
                            Text(attachment.name).font(m.font(.caption, .medium)).foregroundStyle(colors.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            if let size = attachment.size {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                                    .font(m.font(.caption)).foregroundStyle(colors.textTertiary)
                            }
                        }.padding(m.sp16)
                    }
                }
                .overlay { if isVideo { videoOverlay } }
                .overlay(alignment: .bottomLeading) { if !playsHere { badge.padding(m.sp8) } }
                .opacity(pendingSend ? 0.5 : 1)
                .overlay(alignment: .bottom) {
                    if pendingSend {
                        PendingUploadProgressOverlay(
                            store: matrix.uploadProgress, roomID: message.roomID, messageID: message.eventID)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(colors.border))
                .aspectRatio(box.width / box.height, contentMode: .fit)
                .frame(maxWidth: box.width)
        }
        .buttonStyle(.row).help(attachment.name)
        .accessibilityLabel("\(inline == nil ? "Open" : "Play") \(attachment.name)")
        .accessibilityAction(named: "Download") {
            Task { await AttachmentFiles.shared.download(message, matrix: matrix) }
        }
        .accessibilityActions { if inline != nil { Button("Full screen", action: actions.open) } }
        .overlay(alignment: .topTrailing) {
            if hovering || downloading {
                MediaActionsToolbar(
                    matrix: matrix, message: message, actions: actions, downloading: $downloading,
                    fullScreen: inline == nil ? nil : actions.open
                ).padding(m.sp8)
            }
        }
        .onHover { hovering = $0 }
        // A sent file gets its server copy when its remote echo lands, and the still loads from that.
        .task(id: LoadID(source: matrix.mediaImageKey(message), animates: animates)) { await load() }
    }

    private struct LoadID: Equatable {
        let source: NSString?
        let animates: Bool
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
        Text(text).font(m.font(.subheadline, .semibold)).monospacedDigit().foregroundStyle(colors.onMedia)
            .padding(.horizontal, m.sp4 + m.sp2).padding(.vertical, m.sp2)
            .background(colors.mediaControl, in: Capsule())
    }

    /// Over a video's poster: the play button, then the wait for its file, then the video itself.
    @ViewBuilder private var videoOverlay: some View {
        if playsHere, let player = inline?.player {
            InlinePlayer(player: player)
        } else if playsHere {
            DelayedProgress().environment(\.colorScheme, .dark)
        } else {
            playBadge
        }
    }

    private var playBadge: some View {
        Image(systemName: "play.fill").font(m.font(.title3)).foregroundStyle(colors.onMedia)
            .frame(width: m.sp40 + m.sp8, height: m.sp40 + m.sp8).background(colors.mediaControl, in: Circle())
    }

    private func click() {
        if attachment.animated && !animates {
            playing = true
        } else if inline != nil {
            if !playsHere { inline?.play() }
        } else {
            actions.open()
        }
    }

    private func load() async {
        // A picture on screen stays when the server confirms a sent file: its copy is the same picture.
        let started = ContinuousClock.now
        if still == nil, matrix.cachedMediaImage(message) == nil {
            if let image = await matrix.loadMediaImage(message), !Task.isCancelled {
                loadFailed = false
                withAnimation(Motion.arrival(since: started)) { still = image }
            } else if !Task.isCancelled {
                loadFailed = true
            }
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
    /// Opens a video that plays in place in the viewer.
    var fullScreen: (() -> Void)?

    var body: some View {
        let colors = appearance.colors
        let side = MessageToolbar.button
        HStack(spacing: 0) {
            if let fullScreen {
                IconButton(
                    symbol: "arrow.up.left.and.arrow.down.right", label: "Full screen", role: .body, side: side,
                    action: fullScreen)
            }
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
        }.foregroundStyle(colors.textSecondary).padding(.horizontal, m.sp2).frame(height: m(side))
            .background(colors.overlay, in: RoundedRectangle(cornerRadius: m.radius))
            .elevation(.e1, cornerRadius: m.radius)
    }
}

/// The attachment's ⋮ menu, in a row and in the viewer.
struct AttachmentMenuItems: View {
    let matrix: MatrixService
    let message: ChatMessage
    let copyLink: (() -> Void)?
    var forward: (() -> Void)? = nil

    var body: some View {
        if let forward { Button("Forward…", action: forward) }
        if let copyLink { Button("Copy link", action: copyLink) }
        Button("Open in default app") { Task { await AttachmentFiles.shared.open(message, matrix: matrix) } }
        if AttachmentFiles.shared.saved[message.eventID] != nil {
            Button("Show in Finder") { AttachmentFiles.shared.showInFinder(message) }
        }
    }
}

/// A file as a compact card: a soft tinted type tile, subordinate filename and metadata, and quiet trailing download
/// and menu actions on hover that never collide with the filename. A click opens it in the viewer.
struct FileCard: View {
    private enum Focus { case card, download, menu }
    static let minWidth: CGFloat = 240
    static let maxWidth: CGFloat = 348
    static let iconSide: CGFloat = 36
    private static let trailingReserve: CGFloat = 56
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let matrix: MatrixService
    let message: ChatMessage
    let attachment: MessageAttachment
    var pendingSend = false
    var actions = AttachmentActions()
    @State private var hovering = false
    @State private var downloading = false
    @FocusState private var focus: Focus?

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radiusLarge)
        let showActions = hovering || downloading || focus != nil
        FitWidthLayout(min: m(Self.minWidth), max: m(Self.maxWidth)) {
            Button(action: actions.open) {
                HStack(spacing: m.sp12) {
                    FileTypeIcon(kind: attachment.fileKind, side: Self.iconSide, glyph: .body)
                    VStack(alignment: .leading, spacing: m.sp2) {
                        FileNameText(attachment.name, role: .body, weight: .medium).foregroundStyle(colors.textPrimary)
                        Text(caption).font(m.font(.caption)).foregroundStyle(colors.textSecondary).lineLimit(1)
                    }
                }
                .padding(.leading, m(10)).padding(.vertical, m(10))
                .padding(.trailing, m(10) + m(Self.trailingReserve))
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(pendingSend ? 0.5 : 1)
                .background(colors.surfaceCard, in: shape)
                .overlay(alignment: .bottom) {
                    if pendingSend {
                        PendingUploadProgressOverlay(
                            store: matrix.uploadProgress, roomID: message.roomID, messageID: message.eventID)
                    }
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(hovering ? colors.borderStrong : colors.border))
            }
            .buttonStyle(.row).focused($focus, equals: .card).help("Open \(attachment.name)")
            .overlay(alignment: .trailing) {
                if showActions {
                    trailingActions.padding(.trailing, m.sp8).transition(.opacity)
                }
            }
            .animation(Motion.overlay, value: showActions)
            .onHover { hovering = $0 }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Download") {
            Task { await AttachmentFiles.shared.download(message, matrix: matrix) }
        }
    }

    private var trailingActions: some View {
        let colors = appearance.colors
        let side = MessageToolbar.button
        return HStack(spacing: 0) {
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
                .focused($focus, equals: .download)
            }
            Menu {
                AttachmentMenuItems(
                    matrix: matrix, message: message, copyLink: actions.copyLink, forward: actions.forward)
            } label: {
                Image(systemName: "ellipsis").font(m.font(.body)).frame(width: m(side), height: m(side))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: m(side)).help("More actions")
                .focused($focus, equals: .menu)
        }.foregroundStyle(colors.textSecondary)
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

/// Observes upload progress strictly in a leaf overlay so progress ticks never invalidate `MessageRow` or the timeline.
private struct PendingUploadProgressOverlay: View {
    let store: UploadProgressStore
    let roomID: String
    let messageID: String

    var body: some View {
        if let progress = store.progress(roomID: roomID, messageID: messageID) {
            UploadProgressBar(progress: progress)
        }
    }
}

/// A quiet hairline progress bar overlaid along the bottom edge of a sending attachment without shifting row height.
private struct UploadProgressBar: View {
    let progress: Double
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let clamped = min(1, max(0, progress))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                appearance.colors.sunken
                appearance.colors.accentFill.frame(width: proxy.size.width * clamped)
            }
        }
        .frame(height: m(3))
        .accessibilityLabel("Uploading")
        .accessibilityValue("\(Int((clamped * 100).rounded())) percent")
    }
}

/// A file type as a soft tinted tile with a subtle edge and crisp vector symbol.
struct FileTypeIcon: View {
    let kind: FileKind
    /// The tile's side at 100% zoom.
    var side: CGFloat = 40
    var glyph: TextRole = .title3
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radius)
        shape.fill(colors.fileFill(kind))
            .overlay(shape.strokeBorder(colors.fileEdge(kind), lineWidth: 1))
            .overlay(
                Image(systemName: kind.symbol).font(m.font(glyph, .medium)).foregroundStyle(colors.fileGlyph(kind))
            )
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

/// The playing video's AVKit view, in its row's box. Out of sight, scrolled away or gone from the window, it pauses.
private struct InlinePlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> InlinePlayerView {
        let view = InlinePlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: InlinePlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: InlinePlayerView, coordinator: ()) {
        view.hide()
        view.player = nil
    }
}

final class InlinePlayerView: AVPlayerView {
    /// The view each player shows in now. A reused cell can hold a stale copy of the row, and that copy leaving
    /// mustn't pause the video being watched.
    private static let showing = NSMapTable<AVPlayer, InlinePlayerView>.weakToWeakObjects()
    private var observers: [NSObjectProtocol] = []
    private var started: NSKeyValueObservation?

    /// Clear until its video plays, or shows where it was paused, so the poster shows meanwhile, not a black box.
    override var player: AVPlayer? {
        didSet {
            guard player !== oldValue else { return }
            if let player, window != nil { Self.showing.setObject(self, forKey: player) }
            alphaValue = 0
            started = player?.observe(\.timeControlStatus, options: [.initial]) { [weak self] player, _ in
                guard player.timeControlStatus == .playing || player.currentTime() > .zero else { return }
                DispatchQueue.main.async { self?.alphaValue = 1 }
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { return hide() }
        if let player { Self.showing.setObject(self, forKey: player) }
        // Out of sight: scrolled away, the window in the Dock, or the app hidden.
        func pause(on name: Notification.Name, from object: AnyObject?, when: @escaping (InlinePlayerView) -> Bool) {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self, when(self) { self.hide() } }
                })
        }
        pause(on: NSWindow.didMiniaturizeNotification, from: window) { _ in true }
        pause(on: NSApplication.didHideNotification, from: nil) { _ in true }
        if let clip = enclosingScrollView?.contentView {
            pause(on: NSView.boundsDidChangeNotification, from: clip) { $0.visibleRect.isEmpty }
        }
    }

    /// Pauses its video, unless another view shows it now.
    func hide() {
        if let player, Self.showing.object(forKey: player) === self { player.pause() }
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
