import AppKit
import SwiftUI

/// Slack's empty state: one short line and, when there is something to do, one action.
struct EmptyStateView<Action: View>: View {
    private static var textWidth: CGFloat { 360 }
    @Environment(\.metrics) private var m
    let symbol: String
    let title: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: m.sp12) {
            Image(systemName: symbol).font(m.font(.header)).foregroundStyle(.secondary)
            Text(title).font(m.font(.body, .semibold)).multilineTextAlignment(.center).frame(
                maxWidth: m(Self.textWidth))
            action().buttonStyle(.link).font(m.font(.secondary))
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(m.sp32)
    }
}

extension EmptyStateView where Action == EmptyView {
    init(symbol: String, title: String) { self.init(symbol: symbol, title: title) { EmptyView() } }
}

struct InlineErrorView: View {
    @Environment(\.metrics) private var m
    let message: String
    var dismiss: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: m.sp8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            Text(message).font(m.font(.meta)).textSelection(.enabled).frame(
                maxWidth: .infinity, alignment: .leading)
            if let dismiss { IconButton(symbol: "xmark", label: "Dismiss error", role: .caption, action: dismiss) }
        }.padding(.horizontal, m.sp12).padding(.vertical, m.sp8).background(Color.orange.opacity(0.08))
            .accessibilityElement(
                children: .combine)
    }
}

/// Configures the main window as soon as it exists, before its first frame: the saved frame is restored and the
/// background already matches the theme, so the window neither jumps nor flashes dark in light mode.
struct WindowConfiguration: NSViewRepresentable {
    var background: NSColor

    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ view: ConfigurationView, context: Context) {
        view.background = background
        view.window?.backgroundColor = background
    }

    final class ConfigurationView: NSView {
        var background = NSColor.windowBackgroundColor
        private weak var configured: NSWindow?

        override func viewWillMove(toWindow window: NSWindow?) {
            super.viewWillMove(toWindow: window)
            guard let window, window !== configured else { return }
            configured = window
            window.title = "Slatrix"
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = background
            window.setFrameAutosaveName("SlatrixMainWindow")
        }
    }
}

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Takes the space offered without asking this view its size, so a change inside it lays out only itself, not
    /// the whole window. For content that fills whatever it is given.
    func layoutIsolated(alignment: Alignment = .center) -> some View {
        Color.clear.overlay(alignment: alignment) { self }
    }

    /// Times how long this loading state is on screen, for the performance report.
    func loadingInterval(_ name: Performance.Name?, while shown: Bool = true) -> some View {
        modifier(LoadingInterval(name: name, shown: shown))
    }
}

private struct LoadingInterval: ViewModifier {
    let name: Performance.Name?
    let shown: Bool
    @State private var interval: Performance.Interval?

    func body(content: Content) -> some View {
        content.onAppear { show(shown) }.onDisappear { show(false) }.onChange(of: shown) { _, shown in show(shown) }
    }

    private func show(_ shown: Bool) {
        if shown, interval == nil, let name {
            interval = Performance.begin(name)
        } else if !shown, let interval {
            Performance.end(interval)
            self.interval = nil
        }
    }
}
