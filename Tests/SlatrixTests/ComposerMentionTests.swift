import AppKit
import SwiftUI
import Testing

@testable import Slatrix

/// The composer's editor without a window, so these run on every test pass.
@MainActor
struct ComposerMentionTests {
    // capability: composer.mentions
    @Test("A mention chosen from the @ list sends as one link with the person's whole name")
    func chosenMentionSendsWhole() throws {
        var draft = ""
        let hosting = NSHostingView(
            rootView: MessageComposer(
                text: Binding(get: { draft }, set: { draft = $0 }), placeholder: "Message #team",
                members: [ChatUser(id: "@deadlock:example.org", name: "deadlock agent")], onSend: { _, _ in },
                onTyping: { _ in }
            ).environmentObject(AppearanceStore()))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hosting.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let editor = try #require(views(hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        for character in "@dead" {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        editor.keyDown(
            with: try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)))

        let message = ComposerFormat.message(draft: draft)
        #expect(message.body == "@deadlock agent")
        #expect(message.html == "<a href=\"https://matrix.to/#/@deadlock:example.org\">deadlock agent</a>")
    }
}
