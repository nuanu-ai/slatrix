import AppKit

/// What VoiceOver reaches in `view` whose label or title contains `text`. Needs `VoiceOver.listen()` first.
@MainActor func accessible(_ text: String, in view: NSView) -> [AnyObject] {
    view.layoutSubtreeIfNeeded()
    func walk(_ element: AnyObject) -> [AnyObject] {
        [element] + (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }.flatMap(walk)
    }
    return walk(view).filter { element in
        [element.accessibilityLabel?(), element.accessibilityTitle?()].contains { ($0 ?? nil)?.contains(text) == true }
    }
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
