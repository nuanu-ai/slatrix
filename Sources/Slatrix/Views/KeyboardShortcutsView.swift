import SwiftUI

struct KeyboardShortcutsView: View {
    private static let width: CGFloat = 700
    private static let keyCapWidth: CGFloat = 44
    @Environment(\.metrics) private var m
    let onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @FocusState private var closeFocused: Bool
    private var colors: AppColors { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: m.sp12) {
                Text("Keyboard shortcuts").font(m.font(.title, .semibold)).foregroundStyle(colors.primaryText)
                Spacer()
            }.padding(m.sp24)
            Divider().overlay(colors.border)
            HStack(alignment: .top, spacing: m.sp32) {
                VStack(alignment: .leading, spacing: m.sp20) {
                    section("Navigate") {
                        shortcut("Jump to…", keys: "⌘K", spoken: "Command K")
                        shortcut("Search", keys: "⌘G", spoken: "Command G")
                        shortcut("Search in conversation", keys: "⌘F", spoken: "Command F")
                        shortcut("Back", keys: "⌘[", spoken: "Command left bracket")
                        shortcut("Forward", keys: "⌘]", spoken: "Command right bracket")
                        shortcut("Previous conversation", keys: "⌥↑", spoken: "Option up arrow")
                        shortcut("Next conversation", keys: "⌥↓", spoken: "Option down arrow")
                        shortcut("Previous unread", keys: "⇧⌥↑", spoken: "Option Shift up arrow")
                        shortcut("Next unread", keys: "⇧⌥↓", spoken: "Option Shift down arrow")
                    }
                    section("Go to") {
                        shortcut("Direct messages", keys: "⇧⌘K", spoken: "Command Shift K")
                        shortcut("Threads", keys: "⇧⌘T", spoken: "Command Shift T")
                        shortcut("Activity", keys: "⇧⌘M", spoken: "Command Shift M")
                        shortcut("Later", keys: "⇧⌘S", spoken: "Command Shift S")
                        shortcut("People", keys: "⇧⌘E", spoken: "Command Shift E")
                        shortcut("Browse channels", keys: "⇧⌘L", spoken: "Command Shift L")
                        shortcut("Switch workspace", keys: "⌘1–9", spoken: "Command 1 through 9")
                    }
                }
                Rectangle().fill(colors.border).frame(width: 1)
                VStack(alignment: .leading, spacing: m.sp20) {
                    section("Messages") {
                        shortcut("Mark as read", keys: "Esc", spoken: "Escape")
                        shortcut("Mark all as read", keys: "⇧Esc", spoken: "Shift Escape")
                        shortcut("Edit your last message", keys: "↑", spoken: "Up arrow")
                        shortcut("React to last message", keys: "⇧⌘\\", spoken: "Command Shift backslash")
                        shortcut("Attach a file", keys: "⌘U", spoken: "Command U")
                        shortcut("New message", keys: "⌘N", spoken: "Command N")
                        shortcut("New channel", keys: "⇧⌘N", spoken: "Command Shift N")
                    }
                    section("View") {
                        shortcut("Toggle sidebar", keys: "⇧⌘D", spoken: "Command Shift D")
                        shortcut("Toggle right pane", keys: "⌘.", spoken: "Command period")
                        shortcut("Zoom in / out", keys: "⌘+ ⌘−", spoken: "Command plus, Command minus")
                        shortcut("Actual size", keys: "⌘0", spoken: "Command zero")
                    }
                    section("Slatrix") {
                        shortcut("Preferences", keys: "⌘,", spoken: "Command comma")
                        shortcut("Keyboard shortcuts", keys: "⌘/", spoken: "Command slash")
                    }
                }
            }.fixedSize(horizontal: false, vertical: true).padding(m.sp24)
            Divider().overlay(colors.border)
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.cancelAction).focused($closeFocused)
                    .buttonStyle(.bordered).controlSize(.regular)
            }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16)
        }
        .sheetSize(width: Self.width).background(colors.canvas).foregroundStyle(colors.text)
        .onAppear { closeFocused = true }
        .onExitCommand(perform: onClose)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            Text(title.uppercased()).font(m.font(.caption, .semibold)).tracking(m(0.6)).foregroundStyle(
                colors.muted
            ).padding(.bottom, m.sp4)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcut(_ title: String, keys: String, spoken: String) -> some View {
        HStack(spacing: m.sp12) {
            Text(title).font(m.font(.meta)).lineLimit(1)
            Spacer(minLength: m.sp4)
            Text(keys).font(m.font(.meta, .medium, design: .monospaced)).foregroundStyle(colors.primaryText)
                .padding(.horizontal, m.sp8).frame(minWidth: m(Self.keyCapWidth), minHeight: m.sp24)
                .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: m.radiusSmall).stroke(colors.border))
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(spoken)")
    }
}
