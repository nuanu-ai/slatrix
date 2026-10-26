import SwiftUI

/// A sidebar section's header, as in Slack: a chevron and a muted title that fold the section, then a ⋮ menu and a
/// "+" that show while the pointer is over the header or keyboard focus is on one of them.
struct SectionHeader<MenuItems: View>: View {
    let title: String
    let collapsed: Bool
    var onToggle: () -> Void
    /// The "+" button's label; a header without one only folds.
    var addLabel: String? = nil
    var onAdd: () -> Void = {}
    @ViewBuilder var menu: MenuItems
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var hovering = false
    @FocusState private var focus: Action?

    private enum Action { case menu, add }

    var body: some View {
        // Hidden actions keep their place, so the title never shifts when they appear.
        let revealed = hovering || focus != nil
        HStack(spacing: m.sp2) {
            Button(action: onToggle) {
                HStack(spacing: m.sp8) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(m.font(.caption, .bold))
                        .frame(width: m.avatarSmall)
                    Text(title).font(m.font(.body, .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(height: m.row)
            }.buttonStyle(.row).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            if let addLabel {
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(m.font(.secondary, .bold))
                        .frame(width: m(24), height: m(24))
                }
                .menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).fixedSize()
                .help("Section options").accessibilityLabel("\(title) options")
                .focused($focus, equals: .menu).opacity(revealed ? 1 : 0)
                IconButton(symbol: "plus", label: addLabel, role: .secondary, side: 24, action: onAdd)
                    .focused($focus, equals: .add).opacity(revealed ? 1 : 0)
            }
        }
        .foregroundStyle(appearance.colors.textSecondary)
        .padding(.leading, m.sp16).padding(.trailing, m.sp4)
        .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}
