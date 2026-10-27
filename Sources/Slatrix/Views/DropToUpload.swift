import AppKit
import SwiftUI

/// Stages dropped files in a composer, as its + button does; false when it refuses them.
typealias UploadIntake = @MainActor (ComposerAttachmentInput) -> Bool

extension View {
    /// Slack's drop-to-upload: files or images dragged anywhere over this pane show `title` over it and, dropped, go
    /// to the composer inside it.
    func dropToUpload(_ title: String) -> some View { modifier(DropToUpload(title: title)) }

    /// Offers this composer to the pane around it for drops; nil while it can't take attachments.
    func uploadIntake(_ intake: UploadIntake?) -> some View { preference(key: UploadIntakeKey.self, value: intake) }
}

private struct UploadIntakeKey: PreferenceKey {
    static var defaultValue: UploadIntake? { nil }
    static func reduce(value: inout UploadIntake?, nextValue: () -> UploadIntake?) { value = value ?? nextValue() }
}

private struct DropToUpload: ViewModifier {
    let title: String
    @State private var targeted = false
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.metrics) private var m

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(UploadIntakeKey.self) { intake in
            ZStack {
                banner.opacity(targeted ? 1 : 0).animation(Motion.overlay, value: targeted)
                UploadDropTarget(intake: intake) { targeted = $0 }
            }.allowsHitTesting(false)
        }
    }

    private var banner: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radiusPanel)
        return VStack(spacing: m.sp12) {
            Image(systemName: "arrow.up.doc").font(m.font(.hero)).foregroundStyle(colors.accent)
            Text(title).font(m.font(.header, .bold)).foregroundStyle(colors.textPrimary).lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(m.sp24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.canvas.opacity(0.92), in: shape)
        .overlay(shape.strokeBorder(colors.accent, style: StrokeStyle(lineWidth: m.sp2, dash: [m.sp8, m.sp4])))
        .padding(m.sp8).accessibilityHidden(true)
    }
}

private struct UploadDropTarget: NSViewRepresentable {
    var intake: UploadIntake?
    var onTargeted: (Bool) -> Void

    func makeNSView(context: Context) -> UploadDropView { UploadDropView() }

    func updateNSView(_ view: UploadDropView, context: Context) {
        view.intake = intake
        view.onTargeted = onTargeted
    }
}

/// Takes file and image drags over a pane while letting every click through: AppKit finds a drop target by frame and
/// registered types, never by `hitTest`.
final class UploadDropView: NSView {
    var intake: UploadIntake?
    var onTargeted: (Bool) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    // It covers the conversation, which must not become a handle that moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onTargeted(intake != nil)
        return intake == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        let pasteboard = sender.draggingPasteboard
        guard let intake else { return false }
        let files =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return intake(.files(files)) }
        guard let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type)
        else { return false }
        return intake(.image(data, png: type == .png))
    }
}
