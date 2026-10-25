import AppKit
import SwiftUI

struct AvatarView: View {
    let name: String
    var size: CGFloat = 36
    var online: Bool? = nil
    var matrix: MatrixService? = nil
    var source: String? = nil
    @State private var loaded: Loaded?
    private struct RequestID: Hashable {
        let userID: String?
        let source: String?
    }
    private struct Loaded {
        let request: RequestID
        let image: CGImage
    }
    private var requestID: RequestID { RequestID(userID: matrix?.user?.id, source: source) }
    private var cached: CGImage? {
        guard let matrix, let source, !matrix.isPreview else { return nil }
        return matrix.avatarImages.cachedImage(for: source)
    }
    var body: some View {
        let image = loaded?.request == requestID ? loaded?.image : cached
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.19).fill(avatarColor(name))
                .overlay(
                    Text(initials(name)).font(Font(NSFont.systemFont(ofSize: size * 0.35, weight: .semibold) as CTFont))
                        .foregroundStyle(.white)
                )
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: size, height: size).clipped().transition(.opacity)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: size * 0.19))
            if let online {
                Circle().fill(online ? Color(hex: 0x4b9a75) : Color(hex: 0x777a81)).frame(
                    width: size * 0.28, height: size * 0.28
                )
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2)).offset(
                    x: size * 0.06, y: size * 0.06)
            }
        }.frame(width: size, height: size).accessibilityLabel(name)
            .task(id: requestID) {
                let request = requestID
                guard cached == nil, let matrix, let source, !matrix.isPreview else { return }
                let image = await matrix.avatarImages.image(for: source) { try await matrix.avatarThumbnail(source) }
                guard !Task.isCancelled, let image else { return }
                // Only a photo that was not cached fades in over its initials; a cached one is on the first frame.
                withAnimation(.easeOut(duration: 0.12)) { loaded = Loaded(request: request, image: image) }
            }
    }
}

/// A spinner for a wait long enough to notice. It draws nothing before then, so callers place it in space that is
/// already reserved or in an overlay.
struct DelayedProgress: View {
    var active = true
    var hasContent = false
    /// Logs the whole wait, shown or not.
    let interval: Performance.Name
    @State private var shown = false
    var body: some View {
        ZStack { if shown { ProgressView().controlSize(.small) } }
            .loadingInterval(interval, while: active && !hasContent)
            .task(id: active && !hasContent) {
                shown = false
                guard active, !hasContent else { return }
                let start = ContinuousClock.now
                try? await Task.sleep(for: LoadingPresentation.indicatorDelay)
                guard !Task.isCancelled else { return }
                shown = LoadingPresentation.showsIndicator(waited: .now - start, hasContent: hasContent)
            }
    }
}

/// The house style for borderless buttons: the whole frame takes clicks, including the gaps between an icon,
/// its label and a trailing spacer, which `.plain` leaves dead.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == RowButtonStyle {
    static var row: RowButtonStyle { RowButtonStyle() }
}

/// A count in a filled pill that is round for one digit: red for mentions, neutral for other unread messages.
struct CountBadge: View {
    let text: String
    var mention = true
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Text(text).font(m.font(.caption, .bold)).monospacedDigit().lineLimit(1)
            .padding(.horizontal, m.sp4).frame(minWidth: m(18), minHeight: m(18))
            .background(mention ? colors.mention : colors.muted, in: Capsule())
            .foregroundStyle(mention ? Color.white : colors.canvas)
    }
}

struct IconButton: View {
    @Environment(\.metrics) private var m
    let symbol: String
    let label: String
    var role: TextRole = .title
    /// Square side at 100% zoom; the standard icon button when nil.
    var side: CGFloat? = nil
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(m.font(role)).frame(
                width: side.map(m.callAsFunction) ?? m.iconButton, height: side.map(m.callAsFunction) ?? m.iconButton
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.row).background(
            hovering ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: m.radius)
        )
        .onHover { hovering = $0 }.help(label).accessibilityLabel(label)
    }
}

struct ActionButton: View {
    @Environment(\.metrics) private var m
    let title: String
    var symbol: String? = nil
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: m.sp8) {
                if let symbol { Image(systemName: symbol) }
                Text(title).fontWeight(.semibold)
            }
            .padding(.horizontal, m.sp16).frame(height: m.control).foregroundStyle(prominent ? .white : Color.primary)
            .background(
                prominent ? Color(hex: 0x228369) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: m.radius)
            )
            .overlay(RoundedRectangle(cornerRadius: m.radius).strokeBorder(Color.primary.opacity(prominent ? 0 : 0.14)))
        }.buttonStyle(.row)
    }
}

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
    /// Times how long this loading state is on screen, for the performance report.
    func loadingInterval(_ name: Performance.Name, while shown: Bool = true) -> some View {
        modifier(LoadingInterval(name: name, shown: shown))
    }
}

private struct LoadingInterval: ViewModifier {
    let name: Performance.Name
    let shown: Bool
    @State private var interval: Performance.Interval?

    func body(content: Content) -> some View {
        content.onAppear { show(shown) }.onDisappear { show(false) }.onChange(of: shown) { _, shown in show(shown) }
    }

    private func show(_ shown: Bool) {
        if shown, interval == nil {
            interval = Performance.begin(name)
        } else if !shown, let interval {
            Performance.end(interval)
            self.interval = nil
        }
    }
}
