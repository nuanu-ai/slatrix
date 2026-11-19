import AppKit

/// What VoiceOver reaches in `view` whose label or title contains `text`. Needs `VoiceOver.listen()` first.
@MainActor func accessible(_ text: String, in view: NSView) -> [AnyObject] {
    view.layoutSubtreeIfNeeded()
    func walk(_ element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }.flatMap(walk)
    }
    return walk(view).filter { labelled($0, text) }
}

@MainActor private func labelled(_ element: AnyObject, _ text: String) -> Bool {
    [element.accessibilityLabel?(), element.accessibilityTitle?()].contains { ($0 ?? nil)?.contains(text) == true }
}

/// The roles from `view` down to the first element VoiceOver reaches whose label or title contains `text`, nil if none.
@MainActor func accessibilityPath(to text: String, in view: NSView) -> [String]? {
    view.layoutSubtreeIfNeeded()
    func path(_ element: AnyObject) -> [String]? {
        let role = (element.accessibilityRole?() ?? nil)?.rawValue ?? "-"
        if labelled(element, text) { return [role] }
        for child in element.accessibilityChildren?() ?? [] {
            if let rest = path(child as AnyObject) { return [role] + rest }
        }
        return nil
    }
    return path(view)
}

/// SwiftUI builds its accessibility tree only once an assistive app such as VoiceOver asks for it. Tests in parallel
/// share the one switch, so it stays on until the last that listened is done.
@MainActor enum VoiceOver {
    private static var listeners = 0
    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    static func listen() {
        listeners += 1
        if listeners == 1 { NSApp.accessibilitySetValue(true, forAttribute: enhanced) }
    }

    static func done() {
        listeners -= 1
        if listeners == 0 { NSApp.accessibilitySetValue(false, forAttribute: enhanced) }
    }
}
