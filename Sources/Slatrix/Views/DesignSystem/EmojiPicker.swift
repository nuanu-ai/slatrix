import AppKit
import SwiftUI

/// Slack's emoji picker: search focused on open, frequently used, category tabs and a grid of 32 pt cells. Arrows
/// move, Return picks and Esc closes; the footer names the emoji under the pointer. Shown in a `PopoverHost`.
struct EmojiPicker: View {
    private static let cell: CGFloat = 32
    private static let columns = 9
    private static let gridRows: CGFloat = 8
    private static let footer: CGFloat = 48
    private static let frequentLimit = 18
    let recent: [String]
    let onPick: (String) -> Void
    @AppStorage("emoji.skinTone") private var tone = SkinTone.none
    @State private var query = ""
    @State private var selected = 0
    @State private var choosingTone = false
    /// The cell under the pointer; only the footer reads it, so hovering never redraws the grid.
    @State private var hover = Hover()
    @FocusState private var searching: Bool
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    @Observable fileprivate final class Hover { var item: Item? }
    fileprivate struct Item: Hashable {
        let value: String
        let emoji: Emoji
    }
    private struct Section: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let items: [Item]
    }

    var body: some View {
        let colors = appearance.colors
        let sections = sections
        let items = sections.flatMap(\.items)
        let selection = items.isEmpty ? nil : min(selected, items.count - 1)
        let starts = sections.indices.map { index in sections[..<index].reduce(0) { $0 + $1.items.count } }
        // By section, so a cell never keeps what another section showed in its place.
        let cellID = { (index: Int) -> String in
            let section = starts.lastIndex { $0 <= index } ?? 0
            return "\(sections[section].id) \(index - starts[section])"
        }
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: m.sp8) {
                // Always focused: typing goes here, and the grid answers its arrows.
                FieldChrome(focused: true) {
                    HStack(spacing: m.sp8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(colors.textSecondary)
                            .accessibilityHidden(true)
                        EmojiSearchField(
                            text: $query, font: m.nsFont(.secondary), color: NSColor(colors.textPrimary),
                            onMove: { direction in
                                guard let selection else { return }
                                selected = EmojiGrid.move(
                                    selection, direction, sizes: sections.map(\.items.count), columns: Self.columns)
                                proxy.scrollTo(cellID(selected))
                            },
                            onSubmit: { if let selection { onPick(items[selection].value) } }
                        ).focused($searching)
                    }
                }
                tabs(sections, proxy: proxy)
                ScrollView {
                    if items.isEmpty {
                        Text("No emoji found").font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
                            .frame(maxWidth: .infinity).padding(.top, m.sp24)
                    }
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(m(Self.cell)), spacing: 0), count: Self.columns),
                        alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders
                    ) {
                        ForEach(sections.indices, id: \.self) { index in
                            let section = sections[index]
                            let offset = starts[index]
                            SwiftUI.Section {
                                ForEach(section.items.indices, id: \.self) { position in
                                    let item = section.items[position]
                                    EmojiCell(
                                        value: item.value, selected: offset + position == selection,
                                        onHover: { inside in
                                            if inside {
                                                hover.item = item
                                            } else if hover.item == item {
                                                hover.item = nil
                                            }
                                        }, onPick: { onPick(item.value) }
                                    ).equatable().id(cellID(offset + position))
                                }
                            } header: {
                                Text(section.title).font(m.font(.meta, .semibold)).foregroundStyle(colors.textSecondary)
                                    .frame(maxWidth: .infinity, minHeight: m.sp24, alignment: .leading)
                                    .background(colors.overlay).id(section.id)
                            }
                        }
                    }
                }.scrollIndicators(.never).frame(height: m(Self.cell) * Self.gridRows)
                Rectangle().fill(colors.border).frame(height: 1).padding(.horizontal, -m.sp16)
                EmojiFooter(
                    hover: hover, fallback: selection.map { items[$0] }, tone: $tone, choosingTone: $choosingTone
                ).frame(height: m(Self.footer))
            }
        }
        .onChange(of: query) { _, _ in selected = 0 }
        // After the card around it has taken focus.
        .task { searching = true }
    }

    private func tabs(_ sections: [Section], proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 0) {
            ForEach(sections.filter { $0.id != "results" }) { section in
                IconButton(symbol: section.symbol, label: section.title, role: .secondary, side: 28) {
                    query = ""
                    proxy.scrollTo(section.id, anchor: .top)
                }.foregroundStyle(appearance.colors.textSecondary).frame(maxWidth: .infinity)
            }
        }
    }

    private var sections: [Section] {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else {
            let found = EmojiCatalog.search(query).map { Item(value: $0.value(tone: tone), emoji: $0) }
            return [Section(id: "results", title: "Search results", symbol: "", items: found)]
        }
        let frequent = recent.lazy.compactMap { value in
            EmojiCatalog.emoji(for: value).map { Item(value: value, emoji: $0) }
        }
        .prefix(Self.frequentLimit)
        let groups = Dictionary(grouping: EmojiCatalog.all, by: \.category)
        return
            (frequent.isEmpty
            ? [] : [Section(id: "frequent", title: "Frequently used", symbol: "clock", items: Array(frequent))])
            + Emoji.Category.allCases.map { category in
                Section(
                    id: "\(category)", title: category.title, symbol: category.symbol,
                    items: (groups[category] ?? []).map { Item(value: $0.value(tone: tone), emoji: $0) })
            }
    }
}

extension Emoji.Category {
    fileprivate var title: String {
        switch self {
        case .smileys: "Smileys & emotion"
        case .people: "People & body"
        case .nature: "Animals & nature"
        case .food: "Food & drink"
        case .activities: "Activities"
        case .travel: "Travel & places"
        case .objects: "Objects"
        case .symbols: "Symbols"
        case .flags: "Flags"
        }
    }
    fileprivate var symbol: String {
        switch self {
        case .smileys: "face.smiling"
        case .people: "hand.raised"
        case .nature: "leaf"
        case .food: "fork.knife"
        case .activities: "soccerball"
        case .travel: "car"
        case .objects: "lightbulb"
        case .symbols: "heart"
        case .flags: "flag"
        }
    }
}

/// The search field. It takes focus as the picker opens and hands the arrows and Return to the grid, which a
/// SwiftUI text field's own editor would keep for its caret.
private struct EmojiSearchField: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let color: NSColor
    let onMove: (EmojiGrid.Direction) -> Void
    let onSubmit: () -> Void

    /// Gives the keyboard back to where it was, such as the composer, when the picker closes without a pick.
    final class Field: NSTextField {
        private weak var previousResponder: NSResponder?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            previousResponder = window?.firstResponder
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            // SwiftUI may have let the search go already; then focus is nowhere, and goes back too.
            if newWindow == nil, let window,
                window.firstResponder === window || window.firstResponder === currentEditor()
            {
                window.makeFirstResponder(previousResponder)
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search all emoji"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search emoji")
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = font
        field.textColor = color
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: EmojiSearchField
        init(parent: EmojiSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(.down)
            case #selector(NSResponder.moveLeft(_:)): parent.onMove(.left)
            case #selector(NSResponder.moveRight(_:)): parent.onMove(.right)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            default: return false
            }
            return true
        }
    }
}

/// Equal cells skip their body, so moving the selection redraws two cells, not the grid.
private struct EmojiCell: View, Equatable {
    let value: String
    let selected: Bool
    let onHover: (Bool) -> Void
    let onPick: () -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    static func == (a: Self, b: Self) -> Bool { a.value == b.value && a.selected == b.selected }

    var body: some View {
        Button(action: onPick) {
            Text(value).font(m.font(.title)).frame(width: m.sp32, height: m.sp32)
                .background(
                    selected ? appearance.colors.selection : .clear, in: RoundedRectangle(cornerRadius: m.radius))
        }.buttonStyle(.icon).onHover(perform: onHover).accessibilityLabel(EmojiCatalog.emoji(for: value)?.name ?? value)
    }
}

/// The emoji under the pointer, or the selected one, by name and shortcode; and the skin tone.
private struct EmojiFooter: View {
    let hover: EmojiPicker.Hover
    let fallback: EmojiPicker.Item?
    @Binding var tone: SkinTone
    @Binding var choosingTone: Bool
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        HStack(spacing: m.sp8) {
            if choosingTone {
                Text("Skin tone").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                Spacer(minLength: 0)
                ForEach(SkinTone.allCases, id: \.self) { option in
                    Button {
                        tone = option
                        choosingTone = false
                    } label: {
                        Text(hand(option)).font(m.font(.title)).frame(width: m.iconButton, height: m.iconButton)
                    }.buttonStyle(.icon).accessibilityLabel(option.label)
                }
            } else {
                if let item = hover.item ?? fallback {
                    Text(item.value).font(m.font(.header)).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.emoji.name.prefix(1).uppercased() + item.emoji.name.dropFirst())
                            .font(m.font(.secondary, .semibold)).foregroundStyle(colors.textPrimary)
                        Text(EmojiCatalog.shortcode(for: item.value)).font(m.font(.meta))
                            .foregroundStyle(colors.textSecondary)
                    }.lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    choosingTone = true
                } label: {
                    Text(hand(tone)).font(m.font(.title)).frame(width: m.iconButton, height: m.iconButton)
                }.buttonStyle(.icon).help("Skin tone").accessibilityLabel("Skin tone: \(tone.label)")
            }
        }
    }

    private func hand(_ tone: SkinTone) -> String { "✋" + (tone.modifier ?? "") }
}

extension SkinTone {
    fileprivate var label: String {
        switch self {
        case .none: "Default"
        case .light: "Light"
        case .mediumLight: "Medium light"
        case .medium: "Medium"
        case .mediumDark: "Medium dark"
        case .dark: "Dark"
        }
    }
}
