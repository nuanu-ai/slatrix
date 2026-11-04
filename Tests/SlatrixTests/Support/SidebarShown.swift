import AppKit

@testable import Slatrix

/// Whether the sidebar is on screen in `view`, docked or as the drawer. It floats a few points in from the window's
/// edge and scrolls its own list, while the conversation and any page reach the edge once it folds away.
@MainActor func sidebarShown(in view: NSView) -> Bool {
    view.layoutSubtreeIfNeeded()
    func scrollViews(_ view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
    return scrollViews(view).contains { (list: NSScrollView) in
        let frame = list.convert(list.bounds, to: nil)
        return list.window != nil && frame.minX > 0 && frame.minX < Metrics().sp24 * 2
            && frame.width <= SidebarLayout.maximumWidth
    }
}
