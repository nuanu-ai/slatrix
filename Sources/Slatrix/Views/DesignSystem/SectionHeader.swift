import SwiftUI

/// A sidebar section's header: a small gray title that folds the section, with a chevron, a ⋮ menu and a "+" that
/// show while the pointer is over the header or keyboard focus is on one of them. A folded section keeps its chevron.
struct SectionHeader<MenuItems: View>: View {
    let title: String
    let collapsed: Bool
    var onToggle: () -> Void
    /// The "+" button's label; a header without one only folds.
    var addLabel: String? = nil
    var onAdd: () -> Void = {}
    @ViewBuilder var menu: MenuItems
    @Environment(\.metrics) private var m
    @ThemeColors private var colors
    @State private var hovering = false
    @FocusState private var focus: Action?

    private enum Action { case menu, add }

    var body: some View {
        // Hidden actions keep their place, so the title never shifts when they appear.
        let revealed = hovering || focus != nil
        HStack(spacing: m.sp2) {
            Button(action: onToggle) {
                HStack(spacing: m.sp4) {
                    Text(title).font(m.font(.subheadline, .bold)).lineLimit(1)
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(m.font(.subheadline, .semibold)).imageScale(.small)
                        .opacity(revealed || collapsed ? 1 : 0)
                    Spacer(minLength: 0)
                }.frame(height: m.row)
            }.buttonStyle(.row).accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            if let addLabel {
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis").font(m.font(.body))
                        .frame(width: m(24), height: m(24))
                }
                .menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).fixedSize()
                .help("Section options").accessibilityLabel("\(title) options")
                .focused($focus, equals: .menu).opacity(revealed ? 1 : 0)
                IconButton(symbol: "plus", label: addLabel, role: .body, side: 24, action: onAdd)
                    .focused($focus, equals: .add).opacity(revealed ? 1 : 0)
            }
        }
        .foregroundStyle(colors.textSecondary)
        .padding(.leading, m.sp8)
        .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}
