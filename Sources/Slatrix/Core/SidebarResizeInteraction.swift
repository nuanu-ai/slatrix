import Foundation

// Window coordinates and the width captured on mouse-down remain stable while
// resizing moves the pointer view. A reset cannot fall through to a drag commit.
struct SidebarResizeInteraction {
    private var origin: (width: CGFloat, x: CGFloat)?
    private var dragging = false

    mutating func begin(width: CGFloat, x: CGFloat, clickCount: Int) -> Bool {
        origin = nil
        dragging = false
        if clickCount == 2 { return true }
        origin = (width, x)
        return false
    }

    mutating func drag(x: CGFloat) -> CGFloat? {
        guard let origin else { return nil }
        let delta = x - origin.x
        guard dragging || abs(delta) >= 3 else { return nil }
        dragging = true
        return origin.width + delta
    }

    mutating func end(x: CGFloat) -> CGFloat? {
        defer {
            origin = nil
            dragging = false
        }
        guard dragging, let origin else { return nil }
        return origin.width + x - origin.x
    }
}
