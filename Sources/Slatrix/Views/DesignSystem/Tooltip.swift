import AppKit
import SwiftUI

/// Slack's tooltip: a line of `.meta` text on the inverted surface, under optional leading content such as a
/// reaction's emoji, drawn large.
struct Tooltip<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        VStack(spacing: m.sp4) {
            leading
            Text(text).font(m.font(.meta))
        }
        .foregroundStyle(colors.onTooltip).padding(.horizontal, m.sp8).padding(.vertical, m.sp4)
        .fixedSize()
        .background(colors.tooltip, in: RoundedRectangle(cornerRadius: m.radius))
        .elevation(.e2, cornerRadius: m.radius)
    }
}

extension Tooltip where Leading == EmptyView {
    init(_ text: String) { self.init(text: text) { EmptyView() } }
}

/// Shows one tooltip at a time above what the pointer rests on, kept inside the window. It appears after a short
/// delay and fades in, then moves from one anchor to the next at once. It is a child window, as AppKit's own tool
/// tips are, so nothing in the window moves for it and nothing clips it.
@MainActor final class TooltipPresenter {
    private static let delay = 0.3
    private let view = TooltipView(rootView: AnyView(EmptyView()))
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The tooltip draws its own elevation.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = view
        return panel
    }()
    private var pending: DispatchWorkItem?
    private var anchor: NSRect?
    /// When a tooltip last went away; another one soon after shows without the delay.
    private var hiddenAt = Date.distantPast

    /// `anchor` is in `window`'s coordinates.
    func show(_ text: String, above anchor: NSRect, in window: NSWindow, metrics m: Metrics, content: () -> some View) {
        guard text != view.text || anchor != self.anchor else { return }
        let showing = panel.parent != nil
        hide()
        self.anchor = anchor
        view.text = text
        // Room around the bubble for its shadow.
        let margin = m.sp12
        view.rootView = AnyView(content().padding(margin))
        let size = view.fittingSize
        let bubble = NSSize(width: size.width - 2 * margin, height: size.height - 2 * margin)
        let target = window.convertToScreen(anchor)
        let bounds = window.frame.insetBy(dx: m.sp4, dy: m.sp4)
        let x = min(max(bounds.minX, target.midX - bubble.width / 2), bounds.maxX - bubble.width)
        let y = min(target.maxY + m.sp4, bounds.maxY - bubble.height)
        panel.appearance = window.effectiveAppearance
        panel.setFrame(NSRect(x: x - margin, y: y - margin, width: size.width, height: size.height), display: false)
        let reveal = { [panel] (fade: Bool) in
            panel.alphaValue = fade ? 0 : 1
            window.addChildWindow(panel, ordered: .above)
            guard fade else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.overlayDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        if showing || Date().timeIntervalSince(hiddenAt) < Self.delay { return reveal(false) }
        let work = DispatchWorkItem { reveal(true) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        anchor = nil
        view.text = ""
        guard let parent = panel.parent else { return }
        parent.removeChildWindow(panel)
        panel.orderOut(nil)
        hiddenAt = Date()
    }
}

final class TooltipView: NSHostingView<AnyView> {
    /// What it says, and so whether showing it again would change anything.
    fileprivate(set) var text = ""
}
