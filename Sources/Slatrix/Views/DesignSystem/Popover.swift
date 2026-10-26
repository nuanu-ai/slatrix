import AppKit
import SwiftUI

/// The card shown over the window next to what was clicked. Observable, so only the host redraws with it.
@Observable @MainActor final class Popovers {
    enum Kind: Equatable {
        case profile(userID: String, fallback: ChatUser?)
        case emoji(EmojiPick)
    }
    struct Shown: Equatable {
        let id = UUID()
        let kind: Kind
        /// Window content coordinates, top-left origin; nil centers the card near the top.
        let anchor: CGPoint?
    }
    var current: Shown?

    func show(_ kind: Kind) { show(kind, at: Self.pointer()) }
    func show(_ kind: Kind, at anchor: CGPoint?) { current = Shown(kind: kind, anchor: anchor) }
    func close() { current = nil }

    /// Where the click that opens a card happened.
    /// shortcut: anchors at the pointer rather than the clicked element's frame, which rows hosted in table cells
    /// can't report cheaply; read the element's frame if keyboard-opened cards need to sit beside it.
    static func pointer() -> CGPoint? {
        guard let event = NSApp.currentEvent,
            [.leftMouseUp, .leftMouseDown, .rightMouseUp, .otherMouseUp].contains(event.type),
            let content = event.window?.contentView
        else { return nil }
        let point = content.convert(event.locationInWindow, from: nil)
        return content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
    }
}

/// What picking an emoji does: insert it, or react with it. Two picks are the same only when they are one request.
struct EmojiPick: Equatable {
    let id = UUID()
    let action: (String) -> Void
    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// Slack's anchored card: 320 pt on the popover surface, beside the click, kept inside the window. It fades in over
/// 120 ms and closes on Esc or a click outside, which the click spends; nothing under it moves.
struct PopoverHost<Content: View, Card: View>: View {
    let popovers: Popovers
    @ViewBuilder let content: Content
    @ViewBuilder let card: (Popovers.Kind) -> Card
    @Environment(\.metrics) private var m

    var body: some View {
        let current = popovers.current
        content.overlay {
            if let current {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        // A button, not a tap gesture, so the click outside lands however the window was activated.
                        Button(action: popovers.close) { Color.clear.contentShape(Rectangle()) }.buttonStyle(.row)
                            .focusable(false).accessibilityHidden(true)
                        Placed(
                            anchor: current.anchor.map {
                                let origin = geometry.frame(in: .global).origin
                                return CGPoint(x: $0.x - origin.x, y: $0.y - origin.y)
                            }, bounds: geometry.size, onClose: popovers.close
                        ) { card(current.kind) }
                        // A new card is a new view, so its size and focus start fresh.
                        .id(current.id)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.overlay, value: current)
    }
}

private struct Placed<Card: View>: View {
    let anchor: CGPoint?
    let bounds: CGSize
    let onClose: () -> Void
    @ViewBuilder let card: Card
    @State private var size: CGSize?
    @FocusState private var focused: Bool
    @Environment(\.metrics) private var m

    var body: some View {
        PopoverSurface { card }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .offset(origin(size ?? .zero))
            // Drawn only once measured, so it never appears in one place and then jumps.
            .opacity(size == nil ? 0 : 1)
            .focusable().focusEffectDisabled().focused($focused)
            .onAppear { focused = true }
            .onExitCommand(perform: onClose)
    }

    /// Right of the anchor and a little above it, flipped left when the window ends first, always inside it.
    private func origin(_ card: CGSize) -> CGSize {
        let margin = m.sp8
        guard let anchor else { return CGSize(width: (bounds.width - card.width) / 2, height: m.paneHeader + m.sp24) }
        let gap = m.sp12
        let right = anchor.x + gap
        let x = right + card.width + margin <= bounds.width ? right : anchor.x - gap - card.width
        let y = anchor.y - m.sp24
        return CGSize(
            width: min(max(margin, x), max(margin, bounds.width - card.width - margin)),
            height: min(max(margin, y), max(margin, bounds.height - card.height - margin)))
    }
}

/// The card's surface: 320 pt wide, 16 pt in, on the popover color at the second elevation.
struct PopoverSurface<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        content.padding(m.sp16).frame(width: m.popoverWidth, alignment: .leading)
            .background(appearance.colors.overlay, in: RoundedRectangle(cornerRadius: m.radiusLarge))
            .elevation(.e2, cornerRadius: m.radiusLarge)
    }
}
