import SwiftUI

/// The modal shown inside the main window. Observable, so only the views that read `current` update with it.
@Observable @MainActor final class InWindowModal {
    enum Kind: Equatable {
        case preferences, shortcuts
        /// ⌘K and message search; `roomID` scopes a search to one conversation.
        case search(messages: Bool, roomID: String?)
    }
    var current: Kind?
}

/// Slack's in-window modal: the window dims, the modal fades in over 120 ms, Esc or a click outside closes it, and
/// the window under it takes no clicks or focus. Nothing under it is rebuilt to open it.
struct ModalHost<Content: View, Modal: View>: View {
    let modals: InWindowModal
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let modal: (InWindowModal.Kind) -> Modal
    @Environment(\.metrics) private var m
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let current = modals.current
        content.disabled(current != nil).accessibilityHidden(current != nil)
            .overlay {
                if let current {
                    ZStack(alignment: current.isSearch ? .top : .center) {
                        Color.black.opacity(0.32).contentShape(Rectangle()).onTapGesture(perform: onClose)
                            .accessibilityHidden(true)
                        modal(current).clipShape(RoundedRectangle(cornerRadius: m.radiusPanel))
                            .shadow(color: .black.opacity(0.25), radius: m.sp24, y: m.sp8)
                            .padding(.top, current.isSearch ? m.paneHeader + m.sp24 : 0)
                            .onExitCommand(perform: onClose)
                            .accessibilityAddTraits(.isModal)
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: current)
    }
}

extension InWindowModal.Kind {
    fileprivate var isSearch: Bool {
        if case .search = self { true } else { false }
    }
}
