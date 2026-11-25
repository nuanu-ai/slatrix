import MatrixRustSDK
import Testing

@testable import Slatrix

struct SearchMappingTests {
    private func hit(_ id: String, kind: MsgLikeKind, room: String = "!room:example.org") -> SearchServiceResult {
        .message(
            roomId: room,
            result: MessageSearchResult(
                eventId: id, sender: "@alice:example.org", senderProfile: .unavailable,
                content: .msgLike(
                    content: MsgLikeContent(kind: kind, inReplyTo: nil, threadRoot: nil, threadSummary: nil)),
                timestamp: 1_000))
    }

    @Test("Search results never show a deleted message, since rows render the indexed content")
    func dropsDeletedHits() {
        let text = MsgLikeKind.message(
            content: MessageContent(
                msgType: .text(content: TextMessageContent(body: "Still here", formatted: nil)), body: "Still here",
                isEdited: true, mentions: nil))
        let hits = [hit("$deleted", kind: .redacted), hit("$kept", kind: text)]
        let results = MatrixMapping.searchMessages(hits, roomID: nil)
        #expect(results.map(\.id) == ["$kept"])
        #expect(results.first?.body == "Still here" && results.first?.isEdited == true)
    }

    private func text(_ body: String) -> MsgLikeKind {
        .message(
            content: MessageContent(
                msgType: .text(content: TextMessageContent(body: body, formatted: nil)), body: body, isEdited: false,
                mentions: nil))
    }

    @Test("A hit returned twice is listed once")
    func deduplicatesHits() {
        let hits = [hit("$one", kind: text("One")), hit("$two", kind: text("Two")), hit("$one", kind: text("One"))]
        #expect(MatrixMapping.searchMessages(hits, roomID: nil).map(\.id) == ["$one", "$two"])
    }

    @Test("A room-scoped search lists only that room's hits")
    func roomScope() {
        let hits = [hit("$one", kind: text("One")), hit("$two", kind: text("Two"), room: "!two:example.org")]
        #expect(MatrixMapping.searchMessages(hits, roomID: "!two:example.org").map(\.id) == ["$two"])
    }

    @Test("Search snippets sanitize Matrix Markdown mentions, backticks, reply fallbacks and spoilers")
    func sanitizesSnippets() {
        var mention = ChatMessage(
            id: "$m", roomID: "!r:example.org", senderID: "@a:example.org", senderName: "Alice",
            body:
                "> <@bob:example.org> Old\n\n"
                + "[Dmitry Ukhanov](https://matrix.to/#/@dmitry.ukhanov:example.org) check `deploy`\n\nNow",
            timestamp: .distantPast, replyToID: "$old")
        #expect(MessageResultRow.snippetBody(for: mention) == "@Dmitry Ukhanov check deploy\nNow")
        mention.formattedBody = "<span data-mx-spoiler>top secret</span>"
        #expect(MessageResultRow.snippetBody(for: mention) == "[Spoiler hidden]")
        let long = ChatMessage(
            id: "$long", roomID: "!r:example.org", senderID: "@a:example.org", senderName: "Alice",
            body: String(repeating: "padding ", count: 700) + "needle-after-4096",
            timestamp: .distantPast)
        #expect(MessageResultRow.snippetBody(for: long).contains("needle-after-4096"))
    }
}
