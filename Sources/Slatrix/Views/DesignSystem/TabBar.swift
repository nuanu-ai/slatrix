import SwiftUI

/// Slack's underlined tabs, 40 pt tall. The selected tab is semibold over a 2 pt accent line; a click gives the bar
/// keyboard focus, and then ← and → move between tabs.
struct TabBar<Value: Hashable>: View {
    struct Tab {
        let value: Value
        let title: String
        var symbol: String? = nil
        /// Shown in a neutral badge.
        var count: Int? = nil
        var disabled = false
    }
    let tabs: [Tab]
    @Binding var selection: Value
    @FocusState private var focused: Bool
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: m.sp24) {
            ForEach(tabs, id: \.value) { tab in
                TabItem(
                    title: tab.title, symbol: tab.symbol, count: tab.count, selected: tab.value == selection,
                    ringed: keyboardFocused(focused) && tab.value == selection
                ) {
                    selection = tab.value
                    focused = true
                }.disabled(tab.disabled)
            }
        }
        .frame(height: m.tabBar)
        .focusable().focusEffectDisabled().focused($focused)
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement(children: .contain)
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let enabled = tabs.filter { !$0.disabled }
        guard let index = enabled.firstIndex(where: { $0.value == selection }) else { return .ignored }
        selection = enabled[(index + offset + enabled.count) % enabled.count].value
        return .handled
    }
}

private struct TabItem: View {
    let title: String
    let symbol: String?
    let count: Int?
    let selected: Bool
    let ringed: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        Button(action: action) {
            HStack(spacing: m.sp4 + m.sp2) {
                if let symbol { Image(systemName: symbol).font(m.font(.secondary)) }
                // The semibold title holds the width, so selecting a tab never moves the ones beside it.
                Text(title).font(m.font(.secondary, .semibold)).hidden()
                    .overlay { Text(title).font(m.font(.secondary, selected ? .semibold : .regular)) }
                if let count { CountBadge(text: "\(count)", neutral: true) }
            }
            .lineLimit(1).fixedSize()
            .foregroundStyle(selected || hovering ? colors.textPrimary : colors.textSecondary)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(colors.accent).frame(height: m.sp2) }
            }
            .focusRing(ringed, cornerRadius: m.radiusSmall)
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.row).focusable(false).onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
