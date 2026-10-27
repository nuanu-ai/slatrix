import AppKit
import SwiftUI

/// Slack's toast: a one-off confirmation such as "Link copied", small and dark in both themes, as a tooltip is.
struct Toast: View {
    let text: String
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        Text(text).font(m.font(.secondary, .semibold)).foregroundStyle(appearance.colors.onTooltip)
            .padding(.horizontal, m.sp16).padding(.vertical, m.sp8)
            .background(appearance.colors.tooltip, in: RoundedRectangle(cornerRadius: m.radiusLarge))
            .elevation(.e2, cornerRadius: m.radiusLarge)
    }
}

/// The window's toasts. Any view can show one; a new one replaces the last, and each leaves after about 4 s.
@MainActor @Observable final class Toasts {
    struct Note: Equatable {
        let id = UUID()
        let text: String
    }
    var current: Note?
    func show(_ text: String) {
        current = Note(text: text)
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Where toasts appear. It takes no clicks, so whatever is under a toast still works.
struct ToastHost: View {
    let toasts: Toasts

    var body: some View {
        ZStack {
            if let note = toasts.current {
                Toast(text: note.text).transition(.opacity)
            }
        }
        .animation(Motion.overlay, value: toasts.current)
        .allowsHitTesting(false)
        .task(id: toasts.current) {
            guard toasts.current != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toasts.current = nil }
        }
    }
}
