import AppKit
import Testing

/// The view AppKit drops a drag of `types` on at `point` in `window`, or nil when the drag finds nowhere to land.
///
/// Synthetic drags never reach the window server, so this asks AppKit's own lookup. It walks frames and registered
/// types rather than `hitTest`, which SwiftUI answers itself, so only it shows where a real drop goes.
@MainActor
func dropTarget(in window: NSWindow, at point: NSPoint, types: [NSPasteboard.PasteboardType]) throws -> NSView? {
    let selector = NSSelectorFromString("_hitTest:dragTypes:")
    let frame = try #require(window.contentView?.superview)
    try #require(frame.responds(to: selector), "AppKit no longer finds drop targets this way")
    typealias Lookup = @convention(c) (NSView, Selector, UnsafeMutablePointer<NSPoint>, NSSet) -> NSView?
    let lookup = unsafeBitCast(frame.method(for: selector), to: Lookup.self)
    var location = frame.convert(point, from: nil)
    return lookup(frame, selector, &location, NSSet(array: types.map(\.rawValue)))
}

/// What AppKit hands a drop target: a drag of files, image data or text over `window`.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("SlatrixTests-" + UUID().uuidString))
    let draggingDestinationWindow: NSWindow?
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    @MainActor init(files: [URL] = [], png: Data? = nil, text: String? = nil, over window: NSWindow? = nil) {
        draggingDestinationWindow = window
        super.init()
        draggingPasteboard.clearContents()
        if !files.isEmpty { draggingPasteboard.writeObjects(files as [NSURL]) }
        if let png { draggingPasteboard.setData(png, forType: .png) }
        if let text { draggingPasteboard.setString(text, forType: .string) }
    }

    var draggingLocation: NSPoint { .zero }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
