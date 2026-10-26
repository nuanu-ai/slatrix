import AppKit
import SwiftUI

/// The draggable divider beside a resizable pane: the sidebar on its leading side, or the thread and details pane
/// on its trailing side.
struct ResizeHandle: View {
    /// Which side of the divider the resized pane is on.
    var pane: HorizontalEdge = .leading
    var label = "Conversation sidebar width"
    let currentWidth: CGFloat
    var onChange: (CGFloat) -> Void
    var onCommit: () -> Void
    var onReset: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @Environment(\.metrics) private var m
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            pane == .leading ? appearance.colors.sidebar : appearance.colors.canvas
            Rectangle().fill(dragging ? appearance.colors.accent : appearance.colors.border).frame(width: 1)
            if hovering { appearance.colors.hover }
            ResizePointerSurface(
                direction: direction, currentWidth: currentWidth,
                onDragging: { dragging = $0 }, onArrow: { adjust(by: m.sp16 * direction * $0) },
                onChange: onChange, onCommit: onCommit, onReset: onReset)
        }
        .frame(width: m(SidebarLayout.handleWidth)).frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int(currentWidth)) points")
        .accessibilityHint("Use the arrow keys to resize. Double-click to reset the width.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: m.sp16)
            case .decrement: adjust(by: -m.sp16)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Reset width")) { onReset() }
        .help("Drag to resize. Double-click to reset the width.")
        .onDisappear {
            hovering = false
            dragging = false
        }
    }

    /// Moving the divider right widens a leading pane and narrows a trailing one.
    private var direction: CGFloat { pane == .leading ? 1 : -1 }

    private func adjust(by amount: CGFloat) {
        guard !dragging else { return }
        onChange(currentWidth + amount)
        onCommit()
    }
}

private struct ResizePointerSurface: NSViewRepresentable {
    var direction: CGFloat
    var currentWidth: CGFloat
    var onDragging: (Bool) -> Void
    var onArrow: (CGFloat) -> Void
    var onChange: (CGFloat) -> Void
    var onCommit: () -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> ResizePointerView {
        let view = ResizePointerView()
        view.setAccessibilityElement(false)
        view.setAccessibilityHidden(true)
        // Slack's dividers take the arrow keys without a focus ring.
        view.focusRingType = .none
        return view
    }
    func updateNSView(_ view: ResizePointerView, context: Context) {
        view.direction = direction
        view.currentWidth = currentWidth
        view.onDragging = onDragging
        view.onArrow = onArrow
        view.onChange = onChange
        view.onCommit = onCommit
        view.onReset = onReset
    }
}

private final class ResizePointerView: NSView {
    var direction: CGFloat = 1
    var currentWidth: CGFloat = SidebarLayout.defaultWidth
    var onDragging: (Bool) -> Void = { _ in }
    /// -1 for the left arrow, 1 for the right.
    var onArrow: (CGFloat) -> Void = { _ in }
    var onChange: (CGFloat) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onReset: () -> Void = {}
    private var interaction = SidebarResizeInteraction()

    // The window moves by its background; without this the window server takes the drag and no mouseDragged arrives.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?: onArrow(-1)
        case .rightArrow?: onArrow(1)
        default: super.keyDown(with: event)
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onDragging(false)
        if interaction.begin(width: currentWidth, x: x(event), clickCount: event.clickCount) {
            onDragging(false)
            onReset()
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let width = interaction.drag(x: x(event)) else { return }
        onDragging(true)
        NSCursor.resizeLeftRight.set()
        onChange(width)
    }
    override func mouseUp(with event: NSEvent) {
        onDragging(false)
        guard let width = interaction.end(x: x(event)) else { return }
        onChange(width)
        onCommit()
        window?.invalidateCursorRects(for: self)
    }
    /// Mirrored for a trailing pane, so the width always grows with x.
    private func x(_ event: NSEvent) -> CGFloat { event.locationInWindow.x * direction }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { interaction = SidebarResizeInteraction() }
    }
}
