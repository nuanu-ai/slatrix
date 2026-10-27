import SwiftUI

/// Slack's banner: a state that needs attention until it resolves, such as being offline or a save that failed. It
/// spans its pane and sits over what is under it, so coming and going moves nothing. Without a symbol it shows the
/// spinner, for a wait the person can cancel.
struct Banner<Actions: View>: View {
    enum Tone { case neutral, warning, destructive }
    let text: String
    var symbol: String? = nil
    var tone = Tone.warning
    var onDismiss: (() -> Void)? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let tint =
            switch tone {
            case .neutral: colors.textSecondary
            case .warning: colors.warning
            case .destructive: colors.destructive
            }
        HStack(spacing: m.sp8) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            } else {
                DelayedProgress()
            }
            Text(text).foregroundStyle(colors.textPrimary).textSelection(.enabled).lineLimit(2)
            Spacer(minLength: m.sp8)
            actions().buttonStyle(.textLink)
            if let onDismiss { IconButton(symbol: "xmark", label: "Dismiss", role: .secondary, action: onDismiss) }
        }
        .font(m.font(.secondary)).padding(.horizontal, m.sp16).frame(minHeight: m.control)
        .background(tone == .neutral ? colors.raised : tint.opacity(0.12)).background(colors.canvas)
        .overlay(alignment: .bottom) { Divider().overlay(colors.border) }
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(text: String, symbol: String? = nil, tone: Tone = .warning, onDismiss: (() -> Void)? = nil) {
        self.init(text: text, symbol: symbol, tone: tone, onDismiss: onDismiss) { EmptyView() }
    }
}
