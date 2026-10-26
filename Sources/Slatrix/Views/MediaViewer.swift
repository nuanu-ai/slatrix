import AVKit
import AppKit
import Quartz
import SwiftUI

/// Slack's media viewer: the picture, video or file over a dark backdrop, with who sent it and where. It opens at
/// once on the row's own thumbnail and swaps in the full file when it arrives. ← and → step through the
/// conversation's images and videos, or the Files list it was opened from; Esc closes it.
struct MediaViewer: View {
    let matrix: MatrixService
    let viewer: MediaViewerState
    let onForward: (MessageActionTarget) -> Void

    var body: some View {
        ZStack {
            if let message = viewer.message {
                MediaViewerPage(matrix: matrix, viewer: viewer, message: message, onForward: onForward)
                    .transition(.opacity)
            }
        }
        .animation(Motion.overlay, value: viewer.message == nil)
    }
}

private struct MediaViewerPage: View {
    private static let titleWidth: CGFloat = 360
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let matrix: MatrixService
    let viewer: MediaViewerState
    let message: ChatMessage
    let onForward: (MessageActionTarget) -> Void
    @State private var loaded: Loaded?
    @State private var downloading = false
    private var colors: AppColors { appearance.colors }
    private var attachment: MessageAttachment { message.attachment ?? MessageAttachment(name: "", url: "") }
    private var messages: [ChatMessage] {
        viewer.surface == .conversation ? matrix.messages : matrix.threadMessages
    }

    /// The full file, for the message it was loaded for.
    private struct Loaded {
        var eventID: String
        var image: NSImage?
        var lease: AttachmentPreviewLease?
        var error: String?
    }

    var body: some View {
        let current = loaded?.eventID == message.eventID ? loaded : nil
        VStack(spacing: 0) {
            header
            // Margins wide enough for the arrows, so they never sit on the picture.
            MediaStage(content: content(current), onStep: step, onClose: viewer.close)
                .overlay { placeholder(current) }
                .padding(.horizontal, m.sp40 + m.sp32).padding(.bottom, m.sp40)
                .overlay(alignment: .leading) { arrow(-1) }
                .overlay(alignment: .trailing) { arrow(1) }
        }
        .background(colors.mediaBackdrop)
        .accessibilityAddTraits(.isModal)
        .task(id: message.eventID) { await load() }
    }

    private func content(_ loaded: Loaded?) -> MediaStageView.Content {
        let size = attachment.width.flatMap { width in
            attachment.height.map { CGSize(width: CGFloat(width), height: CGFloat($0)) }
        }
        if message.kind == "m.video", let url = loaded?.lease?.url { return .video(url) }
        if !message.isViewerMedia {
            return loaded?.lease.map { .file($0.url) } ?? .empty
        }
        if let image = loaded?.image {
            return .image(id: message.eventID, image, size: size ?? image.size, animates: attachment.animated)
        }
        guard let still = matrix.cachedMediaImage(message) else { return .empty }
        let image = NSImage(cgImage: still, size: .zero)
        return .image(id: message.eventID, image, size: size ?? image.size, animates: false)
    }

    /// What stands in until the file arrives: a file's tile and name, and the spinner once the wait is long.
    @ViewBuilder private func placeholder(_ loaded: Loaded?) -> some View {
        if let error = loaded?.error {
            VStack(spacing: m.sp12) {
                Text(error).font(m.font(.secondary)).foregroundStyle(colors.onMedia)
                Button("Retry") { Task { await load() } }.buttonStyle(.secondary)
            }
        } else if !message.isViewerMedia, loaded?.lease == nil {
            VStack(spacing: m.sp16) {
                FileTypeIcon(kind: attachment.fileKind, side: 96, glyph: .hero)
                Text(attachment.name).font(m.font(.title, .semibold)).foregroundStyle(colors.onMedia)
                DelayedProgress().environment(\.colorScheme, .dark)
            }
        } else if loaded == nil && (message.kind == "m.video" || matrix.cachedMediaImage(message) == nil) {
            DelayedProgress().environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private func arrow(_ offset: Int) -> some View {
        if viewer.neighbor(offset, in: messages) != nil {
            ViewerButton(
                symbol: offset < 0 ? "chevron.left" : "chevron.right", label: offset < 0 ? "Previous" : "Next",
                filled: true
            ) { step(offset) }.padding(.horizontal, m.sp16)
        }
    }

    private var header: some View {
        HStack(spacing: m.sp12) {
            AvatarView(name: message.senderName, size: m.avatar, matrix: matrix, source: message.avatarURL)
            VStack(alignment: .leading, spacing: m.sp2) {
                Text(message.senderName).font(m.font(.secondary, .bold))
                Text(subtitle).font(m.font(.meta)).opacity(0.7)
            }.lineLimit(1)
            Spacer(minLength: m(Self.titleWidth))
            if downloading {
                DelayedProgress().environment(\.colorScheme, .dark).frame(width: m.iconButton, height: m.iconButton)
            } else {
                ViewerButton(symbol: "arrow.down.to.line", label: "Download") {
                    downloading = true
                    Task {
                        await AttachmentFiles.shared.download(message, matrix: matrix)
                        downloading = false
                    }
                }
            }
            if ForwardMessageContent.supports(message),
                let target = matrix.captureMessageAction(message: message, surface: viewer.surface)
            {
                ViewerButton(symbol: "arrowshape.turn.up.right", label: "Forward") {
                    viewer.close()
                    onForward(target)
                }
            }
            ViewerButton(symbol: "arrow.up.forward.app", label: "Open in default app") {
                Task { await AttachmentFiles.shared.open(message, matrix: matrix) }
            }
            Menu {
                AttachmentMenuItems(matrix: matrix, message: message, copyLink: copyLink)
            } label: {
                Image(systemName: "ellipsis").font(m.font(.title)).frame(width: m.iconButton, height: m.iconButton)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: m.iconButton).help("More actions")
            ViewerButton(symbol: "xmark", label: "Close", action: viewer.close)
        }
        .foregroundStyle(colors.onMedia)
        .overlay {
            Text(attachment.name).font(m.font(.secondary, .semibold)).foregroundStyle(colors.onMedia).lineLimit(1)
                .truncationMode(.middle).frame(maxWidth: m(Self.titleWidth))
        }
        .padding(.horizontal, m.sp16).frame(height: m.paneHeader)
    }

    private var subtitle: String {
        let time = message.timestamp.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        guard let room = matrix.rooms.first(where: { $0.id == message.roomID }) else { return time }
        return "\(time) in \(room.isDirect ? room.name : "#" + room.name)"
    }

    private var copyLink: (() -> Void)? {
        if viewer.files != nil {
            guard !matrix.isPreview else { return nil }
            return matrix.sharedFiles.item(for: message).map { item in { copyFilesLink(item, matrix: matrix) } }
        }
        guard let target = matrix.captureMessagePermalink(message: message, surface: viewer.surface) else { return nil }
        return {
            Task {
                do {
                    let link = try await matrix.messagePermalink(for: target)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                } catch is CancellationError {} catch { matrix.errorMessage = MatrixService.safeError(error) }
            }
        }
    }

    private func step(_ offset: Int) { viewer.step(offset, in: messages) }

    private func load() async {
        let eventID = message.eventID
        loaded = nil
        do {
            if message.isViewerMedia && message.kind != "m.video" {
                let image = try await matrix.loadFullImage(message)
                guard !Task.isCancelled else { return }
                loaded = Loaded(eventID: eventID, image: image)
            } else {
                let lease = try await matrix.prepareAttachmentPreview(message)
                guard !Task.isCancelled, lease.isCurrent else { return }
                loaded = Loaded(eventID: eventID, lease: lease)
            }
        } catch is CancellationError {} catch {
            guard !Task.isCancelled else { return }
            // An image keeps showing its thumbnail; the full picture is a nicety.
            if !message.isViewerMedia || message.kind == "m.video" || matrix.cachedMediaImage(message) == nil {
                loaded = Loaded(eventID: eventID, error: MatrixService.safeError(error))
            }
        }
    }
}

/// An icon button that reads on the viewer's dark backdrop in either theme.
private struct ViewerButton: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let symbol: String
    let label: String
    var filled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let colors = appearance.colors
        Button(action: action) {
            Image(systemName: symbol).font(m.font(.title)).foregroundStyle(colors.onMedia)
                .frame(width: filled ? m.sp40 : m.iconButton, height: filled ? m.sp40 : m.iconButton)
                .background(
                    filled ? colors.mediaControl : hovering ? colors.onMedia.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: filled ? m.sp20 : m.radius))
        }
        .buttonStyle(.row).help(label).accessibilityLabel(label).onHover { hovering = $0 }
    }
}

/// The viewer's stage: a zoomable picture, a video player, or a Quick Look view of a file. It holds the keyboard
/// while the viewer is open.
struct MediaStage: NSViewRepresentable {
    let content: MediaStageView.Content
    let onStep: (Int) -> Void
    let onClose: () -> Void

    func makeNSView(context: Context) -> MediaStageView { MediaStageView() }

    func updateNSView(_ view: MediaStageView, context: Context) {
        view.onStep = onStep
        view.onClose = onClose
        view.show(content)
    }

    static func dismantleNSView(_ view: MediaStageView, coordinator: ()) { view.show(.empty) }
}

final class MediaStageView: NSView {
    enum Content: Equatable {
        case empty
        /// `id` names the picture: a new one fits the window, the same one in full resolution keeps its zoom.
        case image(id: String, NSImage, size: CGSize, animates: Bool)
        case video(URL)
        case file(URL)

        static func == (a: Self, b: Self) -> Bool {
            switch (a, b) {
            case (.empty, .empty): true
            case (.image(let a, let x, let s, let p), .image(let b, let y, let t, let q)):
                a == b && x === y && s == t && p == q
            case (.video(let a), .video(let b)), (.file(let a), .file(let b)): a == b
            default: false
            }
        }
    }

    var onStep: (Int) -> Void = { _ in }
    var onClose: () -> Void = {}
    private var content = Content.empty
    private let scroll = NSScrollView()
    private let picture = MediaImageView()
    private var player: AVPlayerView?
    private var preview: QLPreviewView?
    /// Whether the picture follows the window's size, until the reader zooms.
    private var fitted = true

    init() {
        super.init(frame: .zero)
        scroll.contentView = CenteringClipView()
        scroll.documentView = picture
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.maxMagnification = 8
        scroll.autoresizingMask = [.width, .height]
        picture.imageScaling = .scaleProportionallyUpOrDown
        addSubview(scroll)
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(doubleClick)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinched), name: NSScrollView.willStartLiveMagnifyNotification, object: scroll)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Where the keyboard was before the viewer opened, such as the composer; it goes back there on close.
    private weak var previousResponder: NSResponder?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        previousResponder = window?.firstResponder
        window?.makeFirstResponder(self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let window, window.firstResponder === self {
            window.makeFirstResponder(previousResponder)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onStep(-1)
        case 124: onStep(1)
        case 53: onClose()
        default: super.keyDown(with: event)
        }
    }

    /// ⌘+, ⌘− and ⌘0 zoom the picture instead of the window; the app routes them here first.
    func zoom(_ event: NSEvent) -> Bool {
        guard case .image = content,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command
        else { return false }
        switch event.charactersIgnoringModifiers {
        case "=", "+": magnify(by: 1.25)
        case "-": magnify(by: 0.8)
        case "0":
            fitted = true
            fit()
        default: return false
        }
        return true
    }

    func show(_ next: Content) {
        guard next != content else { return }
        let previous = content
        content = next
        scroll.isHidden = true
        if case .video = next {
        } else {
            player?.player?.pause()
            player?.removeFromSuperview()
            player = nil
        }
        if case .file = next {
        } else {
            preview?.close()
            preview?.removeFromSuperview()
            preview = nil
        }
        switch next {
        case .empty: picture.image = nil
        case .image(let id, let image, let size, let animates):
            scroll.isHidden = false
            picture.image = image
            picture.playing = animates
            if case .image(id, _, size, _) = previous { return }
            picture.frame = CGRect(origin: .zero, size: size)
            fitted = true
            fit()
        case .video(let url):
            let view = player ?? AVPlayerView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.controlsStyle = .floating
            view.player = AVPlayer(url: url)
            if player == nil { addSubview(view) }
            player = view
            view.player?.play()
        case .file(let url):
            guard let view = preview ?? QLPreviewView(frame: bounds, style: .normal) else { return }
            view.autoresizingMask = [.width, .height]
            // The stage closes it; closing it again after the window did is a Quick Look crash.
            view.shouldCloseWithWindow = false
            view.previewItem = url as NSURL
            if preview == nil { addSubview(view) }
            preview = view
        }
    }

    override func layout() {
        super.layout()
        if fitted { fit() }
    }

    private var fitScale: CGFloat {
        let size = picture.frame.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(1, bounds.width / size.width, bounds.height / size.height)
    }

    private func fit() {
        scroll.minMagnification = fitScale
        scroll.magnification = fitScale
    }

    private func magnify(by factor: CGFloat) {
        fitted = false
        let visible = scroll.documentVisibleRect
        scroll.setMagnification(scroll.magnification * factor, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
    }

    /// Double-click switches between fitting the window and 100%, at the point clicked.
    @objc private func toggleZoom(_ recognizer: NSClickGestureRecognizer) {
        guard case .image = content else { return }
        if fitted && fitScale < 1 {
            fitted = false
            scroll.setMagnification(1, centeredAt: recognizer.location(in: picture))
        } else {
            fitted = true
            fit()
        }
    }

    @objc private func pinched() { fitted = false }
}

/// Keeps a picture smaller than the window in its middle.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
