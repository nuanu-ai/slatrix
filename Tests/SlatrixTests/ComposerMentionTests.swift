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

    @Test("Bold text right before a mention stays one bold element in the draft after an edit")
    func boldBeforeMentionStaysWhole() throws {
        var draft = "<strong>go</strong><a href=\"https://matrix.to/#/@alice:example.org\">Alice</a>"
        let hosting = NSHostingView(
            rootView: MessageComposer(
                text: Binding(get: { draft }, set: { draft = $0 }), placeholder: "Message #team",
                members: [ChatUser(id: "@alice:example.org", name: "Alice")], onSend: { _, _ in }, onTyping: { _ in }
            ).environmentObject(AppearanceStore()))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hosting.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let editor = try #require(views(hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        editor.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(draft.hasPrefix("<strong>go</strong>"))
    }

    @Test("A word replaced behind the caret, as a spelling correction does, leaves the caret after the space")
    func replacementBehindCaretKeepsCaret() throws {
        var draft = ""
        let hosting = NSHostingView(
            rootView: MessageComposer(
                text: Binding(get: { draft }, set: { draft = $0 }), placeholder: "Message #team", members: [],
                onSend: { _, _ in }, onTyping: { _ in }
            ).environmentObject(AppearanceStore()))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        hosting.layoutSubtreeIfNeeded()
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let editor = try #require(views(hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let atCaret = NSRange(location: NSNotFound, length: 0)
        for character in "teh " { editor.insertText(String(character), replacementRange: atCaret) }

        editor.insertText("the", replacementRange: NSRange(location: 0, length: 3))
        editor.insertText("x", replacementRange: atCaret)

        #expect(editor.string == "the x", "The space typed before the correction stays between the words")
    }

    // capability: message.edit
    // capability: composer.mentions
    @Test("Editing a message offers @room when permitted and ranks recent senders first in @ suggestions")
    func editComposerOffersRecentSendersAndRoomMention() async throws {
        _ = NSApplication.shared
        let f = ActionFixture()
        try f.service.credentials.save(
            StoredSession(
                accessToken: "synthetic-token", userId: f.userID, deviceId: "FIXTURE",
                homeserverUrl: "https://example.org", storeID: UUID().uuidString,
                storeKey: Data(repeating: 0x31, count: 32)))
        f.service.status = .ready
        let alice = ChatUser(id: "@alice:example.org", name: "Alice")
        let zara = ChatUser(id: "@zara:example.org", name: "Zara")
        f.service.members = [alice, zara]
        f.service.canMentionRoom = true
        var zaraMsg = f.message("$zara", sender: zara.id)
        zaraMsg.senderName = zara.name
        zaraMsg.body = "From Zara"
        let ownMsg = f.message("$own")
        f.service.messages = [zaraMsg, ownMsg]

        let hosting = NSHostingView(
            rootView: RootView(scratch: f.service)
                .environmentObject(AppearanceStore())
                .environment(\.metrics, Metrics(zoom: 1)))
        let window = offscreenWindow(NSSize(width: 960, height: 640), key: true)
        window.contentView = hosting
        defer {
            window.contentView = nil
            window.close()
        }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func editableEditor() -> NSTextView? {
            hosting.layoutSubtreeIfNeeded()
            return views(hosting).compactMap { $0 as? NSTextView }.first { $0.isEditable }
        }

        // Wait for the primary composer to become active, then press Up to open the edit composer.
        try #require(await eventually(timeout: .seconds(5)) { editableEditor() != nil })
        let primary = try #require(editableEditor())
        let upEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126))
        primary.keyDown(with: upEvent)

        try #require(await eventually(timeout: .seconds(5)) { editableEditor()?.string == "Original" })
        let editor = try #require(editableEditor())
        let atCaret = NSRange(location: NSNotFound, length: 0)
        let returnEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))

        // Typing "@" and pressing Return picks the top suggestion: Zara (recent sender) ahead of Alice.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        for ch in " @" { editor.insertText(String(ch), replacementRange: atCaret) }
        editor.keyDown(with: returnEvent)
        #expect(editor.string.contains("@Zara"), "Expected recent sender @Zara first, got: \(editor.string)")

        // Typing "@ro" and pressing Return inserts "@room " when canMentionRoom is true.
        for ch in "@ro" { editor.insertText(String(ch), replacementRange: atCaret) }
        editor.keyDown(with: returnEvent)
        #expect(editor.string.contains("@room"), "Expected @room suggestion in edit composer, got: \(editor.string)")
    }
}
