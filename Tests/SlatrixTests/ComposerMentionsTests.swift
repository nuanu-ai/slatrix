import Foundation
import Testing

@testable import Slatrix

struct ComposerMentionsTests {
    private let alice = ComposerMentions.Token(range: NSRange(location: 3, length: 14), userID: "@alice:example.org")

    @Test("A token is sent as Element's Markdown link and mentions its person")
    func sendsLink() {
        let markdown = ComposerMentions.markdown("Hi @Alice Liddell, look", tokens: [alice])
        #expect(markdown == "Hi [Alice Liddell](https://matrix.to/#/@alice:example.org), look")
        #expect(MatrixMapping.mentionedUserIDs(in: markdown) == ["@alice:example.org"])
    }

    @Test("A saved draft restores its tokens, even when a name has Markdown characters")
    func draftRoundTrip() throws {
        let display = "Hi @[QA] *Ann*_, and @Alice Liddell"
        let tokens = [
            ComposerMentions.Token(range: NSRange(location: 3, length: 12), userID: "@ann:example.org"),
            ComposerMentions.Token(range: NSRange(location: 21, length: 14), userID: alice.userID),
        ]
        let key = Data(repeating: 7, count: 32)
        let sealed = try ProtectedLocalStateCodec.seal(
            ProtectedLocalState(drafts: ["!room:example.org": ComposerMentions.markdown(display, tokens: tokens)]),
            key: key, accountID: "@me:example.org")
        let restored = try ProtectedLocalStateCodec.unseal(sealed, key: key, accountID: "@me:example.org")
        let draft = try #require(restored.drafts["!room:example.org"])
        let parsed = ComposerMentions.tokens(in: draft) { _ in nil }
        #expect(parsed.display == display && parsed.tokens == tokens)
    }

    @Test("A message sent before tokens existed opens for editing with tokens named from the conversation")
    func legacyEdit() {
        let parsed = ComposerMentions.tokens(in: "ping @alice:example.org and @carol:example.org") {
            $0 == "@alice:example.org" ? "Alice Liddell" : nil
        }
        #expect(parsed.display == "ping @Alice Liddell and @carol")
        #expect(parsed.tokens.map(\.userID) == ["@alice:example.org", "@carol:example.org"])
    }
}
