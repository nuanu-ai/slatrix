import Foundation
import Testing

@testable import Slatrix

struct ComposerDraftTargetTests {
    private static let roomA = "!a:example.org"
    private static let roomB = "!b:example.org"
    private static let root = "$thread"
    private static func message(
        id: String = "$edit", room: String = roomA, sender: String = "@me:example.org", thread: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id, roomID: room, senderID: sender, senderName: "Me", body: "Original", timestamp: .distantPast,
            threadRootID: thread)
    }

    @Test("An open edit reads and writes its edit buffer and leaves drafts alone")
    func editUsesEditBuffer() {
        let original = Self.message()
        let target = ComposerDraftTarget(roomID: Self.roomA, editing: original)
        var drafts: [String: String] = [Self.roomA: "Unsent A", Self.roomB: "Unsent B"]
        var editText = "Edited text"
        #expect(target.read(draft: drafts[Self.roomA], editText: editText, editing: original) == "Edited text")
        let persist = target.write("Saved edit", editing: original, draft: &drafts[Self.roomA], editText: &editText)
        #expect(!persist)
        #expect(editText == "Saved edit")
        #expect(drafts == [Self.roomA: "Unsent A", Self.roomB: "Unsent B"])
    }

    @Test("A cancelled edit neither shows nor clears the unsent draft underneath")
    func cancelledEdit() {
        let target = ComposerDraftTarget(roomID: Self.roomA, editing: Self.message())
        var draft: String? = "Unsent A"
        var editText = "Saved edit"
        #expect(target.read(draft: draft, editText: editText, editing: nil).isEmpty)
        target.write("", editing: nil, draft: &draft, editText: &editText)
        #expect(draft == "Unsent A" && editText == "Saved edit")
    }

    @Test(
        "A finished edit cannot write into a different edit",
        arguments: [
            message(id: "$new-edit"), message(room: roomB), message(sender: "@other:example.org"),
            message(thread: root),
        ])
    func staleEditRejected(replacement: ChatMessage) {
        let target = ComposerDraftTarget(roomID: Self.roomA, editing: Self.message())
        var draft: String? = "Unsent A"
        var editText = "New edit buffer"
        target.write("", editing: replacement, draft: &draft, editText: &editText)
        #expect(editText == "New edit buffer" && draft == "Unsent A")
    }

    @Test("A regular send stays attached to its draft after an edit opens, and clears only that draft")
    func regularSendClearsOwnDraft() {
        let target = ComposerDraftTarget(roomID: Self.roomA, editing: nil)
        var drafts: [String: String] = [Self.roomA: "Unsent A", Self.roomB: "Unsent B"]
        var editText = "Later edit"
        #expect(target.read(draft: drafts[Self.roomA], editText: editText, editing: Self.message()) == "Unsent A")
        #expect(target.write("", editing: Self.message(), draft: &drafts[Self.roomA], editText: &editText))
        #expect(drafts == [Self.roomB: "Unsent B"] && editText == "Later edit")
    }

    @Test("A thread composer ignores an edit of a main-timeline message and clears only its own thread draft")
    func threadComposerIgnoresMainEdit() {
        let key = ThreadDraftAddress(roomID: Self.roomA, rootID: Self.root).id
        let otherKey = ThreadDraftAddress(roomID: Self.roomB, rootID: Self.root).id
        var drafts = [key: "Thread A", otherKey: "Thread B"]
        var editText = "Later edit"
        let target = ComposerDraftTarget(roomID: Self.roomA, threadRootID: Self.root, editing: Self.message())
        #expect(target.read(draft: drafts[key], editText: editText, editing: Self.message()) == "Thread A")
        target.write("", editing: Self.message(), draft: &drafts[key], editText: &editText)
        #expect(drafts == [otherKey: "Thread B"] && editText == "Later edit")
    }

    @Test("A thread edit updates only its edit buffer, and only while that edit is open")
    func threadEdit() {
        let key = ThreadDraftAddress(roomID: Self.roomA, rootID: Self.root).id
        var drafts = [key: "Retained thread draft"]
        var editText = "Later edit"
        let threadEdit = Self.message(thread: Self.root)
        let target = ComposerDraftTarget(roomID: Self.roomA, threadRootID: Self.root, editing: threadEdit)
        target.write("", editing: Self.message(), draft: &drafts[key], editText: &editText)
        #expect(drafts[key] == "Retained thread draft" && editText == "Later edit")
        target.write("Thread edit", editing: threadEdit, draft: &drafts[key], editText: &editText)
        #expect(editText == "Thread edit" && drafts[key] == "Retained thread draft")
    }
}
