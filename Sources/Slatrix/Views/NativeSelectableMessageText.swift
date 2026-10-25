import AppKit
import SwiftUI

struct NativeSelectableMessageText: NSViewRepresentable {
    /// Layout width until SwiftUI proposes one; never seen on screen.
    private static let fallbackWidth: CGFloat = 480
    var runs: [MessageBodyRun]
    var fontSize: Double
    var textColor: NSColor
    var linkColor: NSColor
    var menuCommands: () -> [MessageMenuCommand]
    var onOpenURL: (URL) -> Void
    @Environment(\.lineLimit) private var lineLimit

    func makeNSView(context: Context) -> MessageTextView {
        let container = NSTextContainer(
            size: NSSize(width: Self.fallbackWidth, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layout)
        let view = MessageTextView(frame: .zero, textContainer: container)
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.textContainerInset = .zero
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("Message")
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        context.coordinator.sizes = [:]
        context.coordinator.onOpenURL = onOpenURL
        view.menuCommands = menuCommands
        view.textContainer?.maximumNumberOfLines = max(0, lineLimit ?? 0)
        view.textContainer?.lineBreakMode = lineLimit == nil ? .byWordWrapping : .byTruncatingTail
        view.linkTextAttributes = [.foregroundColor: linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        if context.coordinator.runs != runs || context.coordinator.fontSize != fontSize
            || context.coordinator.textColor != textColor || context.coordinator.linkColor != linkColor
        {
            let attributed = Self.attributed(runs, fontSize: fontSize, textColor: textColor, linkColor: linkColor)
            let selection =
                view.string == attributed.string
                ? view.selectedRanges : [NSValue(range: NSRange(location: 0, length: 0))]
            view.textStorage?.setAttributedString(attributed)
            view.selectedRanges = selection
            context.coordinator.runs = runs
            context.coordinator.fontSize = fontSize
            context.coordinator.textColor = textColor
            context.coordinator.linkColor = linkColor
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.fallbackWidth)
        let line = ceil(fontSize + 3)
        // Stacks probe with a zero width; laying text out a glyph per line would be the costliest layout of all.
        guard width >= fontSize * 2 else { return CGSize(width: width, height: line) }
        if let size = context.coordinator.sizes[width] { return size }
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else {
            return CGSize(width: width, height: fontSize + 4)
        }
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let size = CGSize(width: width, height: max(line, ceil(layout.usedRect(for: container).height)))
        context.coordinator.sizes[width] = size
        return size
    }

    func makeCoordinator() -> Coordinator { Coordinator(onOpenURL: onOpenURL) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var runs: [MessageBodyRun]?
        var fontSize: Double?
        var textColor: NSColor?
        var linkColor: NSColor?
        /// Laid-out sizes by width for the current text; a timeline row is measured at one or two widths, many times.
        var sizes: [CGFloat: CGSize] = [:]
        var onOpenURL: (URL) -> Void
        init(onOpenURL: @escaping (URL) -> Void) { self.onOpenURL = onOpenURL }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let source = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
            if let url = MessageBodyRenderer.safeLink(source) { onOpenURL(url) }
            return true
        }
    }

    static func attributed(_ runs: [MessageBodyRun], fontSize: Double, textColor: NSColor, linkColor: NSColor)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = fontSize / 5  // 3 pt at the 15 pt body, scaling with zoom.
        for run in runs {
            let size = run.style.contains(.code) ? max(10, fontSize - 1) : fontSize
            var font =
                run.style.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            var traits = font.fontDescriptor.symbolicTraits
            if run.style.contains(.bold) { traits.insert(.bold) }
            if run.style.contains(.italic) { traits.insert(.italic) }
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: size) ?? font
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: textColor, .paragraphStyle: paragraph,
            ]
            if run.style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.contains(.code) { attributes[.backgroundColor] = textColor.withAlphaComponent(0.07) }
            if let link = run.link.flatMap({ MessageBodyRenderer.safeLink($0.absoluteString) }) {
                attributes[.link] = link
                attributes[.foregroundColor] = linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }
}

final class MessageTextView: NSTextView {
    var menuCommands: () -> [MessageMenuCommand] = { [] }

    /// A message never scrolls the timeline: AppKit asks a resized text view to reveal its selection, which would
    /// pull a resizing conversation away from its newest message.
    override func scrollToVisible(_ rect: NSRect) -> Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var commands = menuCommands()
        let proposedRange = selectedRange()
        let range =
            proposedRange.location != NSNotFound && NSMaxRange(proposedRange) <= (string as NSString).length
            ? proposedRange : NSRange(location: 0, length: 0)
        if range.length > 0 || commands.isEmpty {
            let selection = range.length > 0 ? (string as NSString).substring(with: range) : string
            let copy = MessageMenuCommand(
                id: "native-copy-selection", title: range.length > 0 ? "Copy selection" : "Copy text",
                isEnabled: !selection.isEmpty
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection, forType: .string)
            }
            if !commands.isEmpty {
                commands.insert(MessageMenuCommand(id: "native-copy-separator", isSeparator: true), at: 0)
            }
            commands.insert(copy, at: 0)
        }
        return NativeMessageMenu.make(commands: commands)
    }
}
