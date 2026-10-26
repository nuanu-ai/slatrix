import AppKit
import SwiftUI

/// Preferences, ⌘K and the shortcuts list, opened from the menu. Observable, so only the views that read `current`
/// update with it.
@Observable @MainActor final class InWindowModal {
    enum Kind: Hashable, Identifiable {
        case preferences, shortcuts
        /// ⌘K and message search; `roomID` scopes a search to one conversation.
        case search(messages: Bool, roomID: String?)
        var id: Self { self }
    }
    var current: Kind?
}

extension View {
    /// Shows `content` as a modal over the window while `item` is set, like `.sheet(item:)`. A click outside closes it
    /// only when `closesOnClickOutside`, so a form never loses what was typed into it.
    func modal<Item: Identifiable, Content: View>(
        item: Binding<Item?>, closesOnClickOutside: Bool = false, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        modifier(
            ModalPresenter(
                item: item, id: { AnyHashable($0.id) }, closesOnClickOutside: closesOnClickOutside, content: content))
    }

    func modal<Content: View>(
        isPresented: Binding<Bool>, closesOnClickOutside: Bool = false, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(
            ModalPresenter(
                item: Binding(
                    get: { isPresented.wrappedValue ? true : nil },
                    set: { if $0 == nil { isPresented.wrappedValue = false } }),
                id: { _ in AnyHashable(true) }, closesOnClickOutside: closesOnClickOutside, content: { _ in content() })
        )
    }
}

/// A modal on its way to the nearest `ModalHost`. Equal by identity, so the host restyles only when one opens or closes.
struct PresentedModal: Identifiable, Equatable {
    let id: AnyHashable
    let view: AnyView
    let onClickOutside: (() -> Void)?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

private struct PresentedModals: PreferenceKey {
    static var defaultValue: [PresentedModal] { [] }
    static func reduce(value: inout [PresentedModal], nextValue: () -> [PresentedModal]) {
        value += nextValue()
    }
}

private struct ModalPresenter<Item, Modal: View>: ViewModifier {
    @Binding var item: Item?
    let id: (Item) -> AnyHashable
    let closesOnClickOutside: Bool
    @ViewBuilder let content: (Item) -> Modal
    /// Tells this presenter's modals from another's that show the same item.
    @State private var presenter = UUID()

    func body(content view: Content) -> some View {
        // Built here, not in the preference callback, so the modal redraws with the presenter's state.
        let shown = item.map { item in
            PresentedModal(
                id: [AnyHashable(presenter), id(item)], view: AnyView(content(item)),
                onClickOutside: closesOnClickOutside ? { self.item = nil } : nil)
        }
        return view.transformPreference(PresentedModals.self) { if let shown { $0.append(shown) } }
    }
}

/// Slack's in-window modal layer. What `.modal` presents inside `content` fades in over a dimmed window in 120 ms, and
/// the window under it takes no clicks, focus or VoiceOver. A modal opened from a modal stacks on top of it. Nothing
/// under it is rebuilt to open one.
struct ModalHost<Content: View>: View {
    /// Called when the first modal opens and when the last one closes.
    var onCovered: (Bool) -> Void = { _ in }
    @ViewBuilder let content: Content
    @State private var covered = false

    var body: some View {
        content.disabled(covered).accessibilityHidden(covered)
            .onPreferenceChange(PresentedModals.self) { modals in
                guard covered != !modals.isEmpty else { return }
                covered = !modals.isEmpty
                onCovered(covered)
            }
            .overlayPreferenceValue(PresentedModals.self) { modals in
                ZStack {
                    ForEach(modals) { modal in
                        ModalLayer(modal: modal).disabled(modal.id != modals.last?.id).transition(.opacity)
                    }
                }
                .animation(Motion.overlay, value: modals.map(\.id))
            }
    }
}

private struct ModalLayer: View {
    let modal: PresentedModal
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        ModalHost {
            ZStack {
                // A button, not a tap gesture, so the click outside lands however the window was activated.
                Button {
                    modal.onClickOutside?()
                } label: {
                    appearance.colors.scrim.contentShape(Rectangle())
                }
                .buttonStyle(.row).focusable(false).accessibilityHidden(true)
                modal.view.accessibilityAddTraits(.isModal)
            }
        }
    }
}

enum ModalSize {
    case small, medium, large
    /// At 100% zoom, for the one modal that needs its own width: Preferences.
    case custom(CGFloat)
}

/// A footer button. The primary one takes Return unless `shortcut` says otherwise.
struct ModalAction {
    let title: String
    var kind = ButtonKind.primary
    var disabled = false
    /// nil when Return belongs to the form, such as a list of suggestions; ⌘Return under a multi-line field.
    var shortcut: KeyboardShortcut? = .defaultAction
    let action: () -> Void

    init(
        _ title: String, kind: ButtonKind = .primary, disabled: Bool = false,
        shortcut: KeyboardShortcut? = .defaultAction, action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.disabled = disabled
        self.shortcut = shortcut
        self.action = action
    }
}

/// Slack's modal: the title and ✕, the body 24 pt in, and [secondary][primary] at the bottom right. Esc and ✕ close it
/// and Return runs the primary action; while `busy` neither closes it and the buttons wait. The cursor starts in the
/// first field.
struct Modal<Content: View>: View {
    let title: String
    var size = ModalSize.medium
    /// At 100% zoom, for a body that scrolls; nil fits the content.
    var height: CGFloat? = nil
    /// False for a body that runs edge to edge, such as tabs or a list.
    var padded = true
    var busy = false
    let onClose: () -> Void
    var secondary: ModalAction? = nil
    var primary: ModalAction? = nil
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: m.sp16) {
                Text(title).font(m.font(.header, .bold)).foregroundStyle(colors.textPrimary).lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", label: "Close", action: onClose).keyboardShortcut(.cancelAction)
                    .disabled(busy)
            }
            .padding(.leading, m.sp24).padding(.trailing, m.sp16).padding(.vertical, m.sp16)
            VStack(alignment: .leading, spacing: m.sp16) { content }
                .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .topLeading)
                .padding(.horizontal, padded ? m.sp24 : 0).padding(.bottom, padded ? m.sp24 : 0)
            if secondary != nil || primary != nil {
                HStack(spacing: m.sp12) {
                    if busy { DelayedProgress() }
                    Spacer(minLength: 0)
                    if let secondary { button(secondary).buttonStyle(.secondary) }
                    if let primary {
                        button(primary).buttonStyle(HouseButtonStyle(kind: primary.kind))
                            .keyboardShortcut(primary.shortcut)
                    }
                }
                .controlSize(.large).padding([.horizontal, .bottom], m.sp24)
            }
        }
        .frame(maxWidth: width, maxHeight: height.map(m.callAsFunction))
        .background(colors.canvas).foregroundStyle(colors.textBody)
        .background(ModalFocus())
        .modalSurface()
        // Keeps the modal off the window's edges at any zoom.
        .padding(m.sp40)
    }

    private var width: CGFloat {
        switch size {
        case .small: m.modalSmall
        case .medium: m.modalMedium
        case .large: m.modalLarge
        case .custom(let points): m(points)
        }
    }

    private func button(_ action: ModalAction) -> some View {
        Button(action.title, action: action.action).disabled(action.disabled || busy)
    }
}

extension View {
    /// A modal's rounded corners and shadow, for one drawn without `Modal`.
    func modalSurface() -> some View { modifier(ModalSurface()) }
}

private struct ModalSurface: ViewModifier {
    @Environment(\.metrics) private var m
    func body(content: Content) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: m.radiusPanel)).elevation(.e3, cornerRadius: m.radiusPanel)
    }
}

/// Slack's confirmation: a small modal with one sentence, Cancel and the action. The action is red only when it
/// destroys something.
struct ConfirmModal: View {
    let title: String
    let message: String
    let action: String
    var kind = ButtonKind.destructive
    var cancel = "Cancel"
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.metrics) private var m

    var body: some View {
        Modal(
            title: title, size: .small, onClose: onCancel, secondary: ModalAction(cancel, action: onCancel),
            primary: ModalAction(action, kind: kind, action: onConfirm)
        ) {
            Text(message).font(m.font(.body)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Keeps the keyboard in the modal: the cursor starts in its first field, as a sheet's did, and when Tab would move
/// it to text in the window under the modal, it wraps to the modal's first field instead, or its last for ⇧Tab.
private struct ModalFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> Keeper { Keeper() }
    func updateNSView(_ view: Keeper, context: Context) { view.isTop = context.environment.isEnabled }

    final class Keeper: NSView {
        /// False while another modal covers this one.
        var isTop = true
        private var observation: NSKeyValueObservation?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepFocus() }
            }
            // After this pass, once the modal's fields exist and have their frames.
            DispatchQueue.main.async { [weak self] in
                guard let self, let first = fields().first else { return }
                window?.makeFirstResponder(first)
            }
        }

        private func keepFocus() {
            guard isTop, let window, let responder = window.firstResponder as? NSView else { return }
            // A field holds the cursor through the window's shared field editor.
            let focused = (responder as? NSTextView).flatMap { $0.isFieldEditor ? $0.delegate as? NSView : $0 }
            let fields = fields()
            guard let focused, !fields.isEmpty, !fields.contains(where: { $0 === focused }) else { return }
            let backward = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
            window.makeFirstResponder(backward ? fields.last : fields.first)
        }

        /// The modal's editable fields, top to bottom and then left to right.
        private func fields() -> [NSView] {
            guard let root = window?.contentView else { return [] }
            let area = convert(bounds, to: nil)
            return Self.fields(in: root)
                .map { ($0, $0.convert($0.bounds, to: nil)) }
                .filter { area.contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }
                // Window coordinates grow upward.
                .sorted { ($1.1.maxY, $0.1.minX) < ($0.1.maxY, $1.1.minX) }.map(\.0)
        }

        private static func fields(in view: NSView) -> [NSView] {
            if view.isHiddenOrHasHiddenAncestor { return [] }
            if let field = view as? NSTextField, field.isEditable, field.isEnabled { return [field] }
            if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return [text] }
            return view.subviews.flatMap(fields)
        }
    }
}
