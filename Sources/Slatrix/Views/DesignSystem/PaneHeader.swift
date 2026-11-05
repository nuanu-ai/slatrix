import SwiftUI

/// A side pane's title bar, for a thread, pinned messages, files or a profile: one inset, type and close button,
/// so moving from one pane to another changes only the words.
struct PaneHeader: View {
    let title: String
    var subtitle: String? = nil
    let closeLabel: String
    let onClose: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        HStack(spacing: m.sp8) {
            VStack(alignment: .leading, spacing: m(1)) {
                Text(title).font(m.font(.title3, .semibold)).foregroundStyle(colors.textPrimary)
                if let subtitle {
                    Text(subtitle).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                }
            }.lineLimit(1)
            Spacer()
            CloseButton(label: closeLabel, action: onClose)
        }.padding(.leading, m.sp16).padding(.trailing, m.sp12).frame(height: m.paneHeader)
            .background(WindowDragArea())
    }
}

/// The round close button of panes, modals and dismissible errors.
struct CloseButton: View {
    var label = "Close"
    let action: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        IconButton(symbol: "xmark", label: label, role: .body, round: true, action: action)
            .fontWeight(.semibold).foregroundStyle(appearance.colors.textSecondary)
    }
}
