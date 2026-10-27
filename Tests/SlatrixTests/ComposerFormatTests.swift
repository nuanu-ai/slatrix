import Foundation
import Testing

@testable import Slatrix

private typealias Paragraph = ComposerFormat.Paragraph
private let alice = MessageBodyRun(
    text: "@Alice Liddell", link: URL(string: "https://matrix.to/#/@alice:example.org"),
    mention: "@alice:example.org")

/// What the composer sends: Matrix HTML from the spec's tag list, and a plain body that reads as typed.
struct ComposerFormatTests {
    private func sent(_ paragraphs: [Paragraph]) -> ComposerFormat.Message {
        ComposerFormat.message(draft: ComposerFormat.html(paragraphs))
    }

    @Test(
        "Each format sends standard HTML and a natural plain body",
        arguments: [
            (
                [Paragraph(runs: [.init(text: "Hi "), .init(text: "there", style: .bold)])],
                "Hi <strong>there</strong>", "Hi there"
            ),
            ([Paragraph(runs: [.init(text: "soft", style: .italic)])], "<em>soft</em>", "soft"),
            ([Paragraph(runs: [.init(text: "gone", style: .strike)])], "<del>gone</del>", "gone"),
            ([Paragraph(runs: [.init(text: "a < b", style: .code)])], "<code>a &lt; b</code>", "`a < b`"),
            (
                [Paragraph(runs: [.init(text: "docs", link: URL(string: "https://example.org/a?b=1&c"))])],
                "<a href=\"https://example.org/a?b=1&amp;c\">docs</a>", "docs (https://example.org/a?b=1&c)"
            ),
            (
                [
                    Paragraph(block: .bullet, runs: [.init(text: "one")]),
                    Paragraph(block: .bullet, runs: [.init(text: "two")]),
                ],
                "<ul><li>one</li><li>two</li></ul>", "- one\n- two"
            ),
            (
                [
                    Paragraph(block: .ordered, runs: [.init(text: "one")]),
                    Paragraph(block: .ordered, runs: [.init(text: "two")]),
                ],
                "<ol><li>one</li><li>two</li></ol>", "1. one\n2. two"
            ),
            (
                [
                    Paragraph(block: .quote, runs: [.init(text: "said")]),
                    Paragraph(block: .quote, runs: [.init(text: "this")]),
                ],
                "<blockquote>said<br>this</blockquote>", "> said\n> this"
            ),
            (
                [
                    Paragraph(block: .code, runs: [.init(text: "if a < b {")]),
                    Paragraph(block: .code, runs: [.init(text: "  go()")]),
                ],
                "<pre><code>if a &lt; b {\n  go()</code></pre>", "```\nif a < b {\n  go()\n```"
            ),
            (
                [Paragraph(runs: [.init(text: "Thanks "), alice])],
                "Thanks <a href=\"https://matrix.to/#/@alice:example.org\">Alice Liddell</a>", "Thanks @Alice Liddell"
            ),
        ] as [([Paragraph], String, String)])
    private func format(paragraphs: [Paragraph], html: String, body: String) {
        let message = sent(paragraphs)
        #expect(message.html == html)
        #expect(message.body == body)
    }

    @Test("Text without formatting sends only a body, with Markdown characters kept as typed")
    func plainText() {
        let message = sent([
            Paragraph(runs: [.init(text: "2 * 3 = **six** & <done>")]), Paragraph(runs: [.init(text: "> not a quote")]),
        ])
        #expect(message.html == nil)
        #expect(message.body == "2 * 3 = **six** & <done>\n> not a quote")
    }

    @Test("A mention notifies its person through m.mentions")
    func mentions() {
        #expect(sent([Paragraph(runs: [alice, .init(text: " and "), alice])]).mentions == ["@alice:example.org"])
        #expect(sent([Paragraph(runs: [.init(text: "nobody")])]).mentions.isEmpty)
    }

    @Test(
        "A complete Matrix ID typed outside code mentions its person",
        arguments: [
            ("Hi @alice:example.org, @alice:example.org", ["@alice:example.org"]),
            ("<code>@alice:example.org</code><pre><code>@carol:example.org</code></pre>", []),
            ("mail me at bob@example.org or @alice", []),
        ])
    func typedMentions(draft: String, ids: [String]) {
        #expect(ComposerFormat.message(draft: draft).mentions == ids)
    }

    @Test("Every tag the composer sends is on the Matrix spec's list")
    func allowedTags() throws {
        let everything = sent([
            Paragraph(runs: [.init(text: "a", style: [.bold, .italic, .strike, .code]), alice]),
            Paragraph(runs: [.init(text: "b", link: URL(string: "https://example.org"))]),
            Paragraph(block: .bullet, runs: [.init(text: "c")]), Paragraph(block: .ordered, runs: [.init(text: "d")]),
            Paragraph(block: .quote, runs: [.init(text: "e")]), Paragraph(block: .code, runs: [.init(text: "f")]),
        ])
        let html = try #require(everything.html)
        let tags = Set(html.matches(of: /<\/?([a-z0-9]+)/).map { String($0.1) })
        let allowed: Set = [
            "font", "del", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "p", "a", "ul", "ol", "sup", "sub", "li",
            "b", "i", "u", "strong", "em", "s", "code", "hr", "br", "div", "table", "thead", "tbody", "tr", "th", "td",
            "caption", "pre", "span", "img", "details", "summary",
        ]
        #expect(tags.isSubset(of: allowed), "\(tags.subtracting(allowed))")
        #expect(tags == ["strong", "em", "del", "code", "a", "br", "ul", "ol", "li", "blockquote", "pre"])
    }

    @Test("A draft round-trips every format, mention, special character and run of spaces")
    func draftRoundTrip() {
        let paragraphs = [
            Paragraph(runs: [.init(text: "  indented  <b> & \"quoted\""), .init(text: " bold", style: .bold), alice]),
            Paragraph(),
            Paragraph(block: .bullet, runs: [.init(text: "item", style: .italic)]),
            Paragraph(block: .ordered, runs: [.init(text: "first")]),
            Paragraph(block: .quote, runs: [.init(text: "quoted", style: .strike)]),
            Paragraph(block: .code, runs: [.init(text: "    let x = 1")]),
            Paragraph(block: .code, runs: []),
            Paragraph(block: .code, runs: [.init(text: "}")]),
            Paragraph(runs: [.init(text: "after", link: URL(string: "https://example.org"))]),
        ]
        let restored = ComposerFormat.paragraphs(html: ComposerFormat.html(paragraphs))
        #expect(restored.map(\.block) == paragraphs.map(\.block))
        #expect(restored.map { $0.runs.map(\.text).joined() } == paragraphs.map { $0.runs.map(\.text).joined() })
        #expect(restored[0].runs.contains { $0.text.contains("bold") && $0.style == .bold })
        #expect(restored[0].runs.last?.mention == "@alice:example.org")
        #expect(restored[2].runs.first?.style == .italic && restored[4].runs.first?.style == .strike)
        #expect(restored[8].runs.first?.link?.absoluteString == "https://example.org")
    }

    @Test("A message from Element opens for editing with its formatting")
    func editsElementMessage() {
        let draft = ComposerFormat.draft(
            body: "> quoted\n\nHi **there**\n\n- one\n- two",
            html:
                "<blockquote>\n<p>quoted</p>\n</blockquote>\n<p>Hi <strong>there</strong></p>\n<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n"
        )
        let paragraphs = ComposerFormat.paragraphs(html: draft)
        #expect(paragraphs.map(\.block) == [.quote, nil, .bullet, .bullet])
        #expect(paragraphs.map { $0.runs.map(\.text).joined() } == ["quoted", "Hi there", "one", "two"])
        #expect(paragraphs[1].runs.contains { $0.text == "there" && $0.style == .bold })
    }

    @Test("A message with only a plain body opens as typed, with Element's mention links as mentions")
    func editsPlainMessage() {
        let draft = ComposerFormat.draft(
            body: "Hi [Alice](https://matrix.to/#/@alice:example.org), **as is**", html: nil)
        let paragraphs = ComposerFormat.paragraphs(html: draft)
        #expect(paragraphs.count == 1 && paragraphs[0].block == nil)
        #expect(paragraphs[0].runs.map(\.text).joined() == "Hi @Alice, **as is**")
        #expect(paragraphs[0].runs.contains { $0.mention == "@alice:example.org" })
    }

    @Test("A vault saved before drafts kept formatting opens with its drafts' text as written and mentions as tokens")
    func legacyVault() throws {
        // Sealed by the release before this one, which stored drafts as Markdown.
        let legacy = try #require(
            Data(
                base64Encoded:
                    "RUxWTFQwMQrzSPQrh6HbhrYVVWr7ACk3WiRn5ylxdG9+k741tX4EgAmN5VLcU0WQcy35Fp7hxSzo8NbwutBdWSuSF8CJxKuHZqYlSjtLBtmLb7DPs6F4ghmpGC7/UsrdaEACas+oarkk5NDMqT3NgrXg9i8ICgq6EPd9GkonrmfShJqjn6gcsTnZMld6nGzFFsBC3PbyRE0l1GCd3nRYnVNY9Gpzfb4oW6W54JkEnY4YkN9QU6HFFdME++XNbMYUvBFTuf4TLBVOLkrmtBZHN9ZiBeT+lzWRKS7+GaUk5gE7YNtVDYf3Q5ok0tVMx7qJUs16kSrJMSDCGsg1onrfoLGxNXpvTSst"
            ))
        let state = try ProtectedLocalStateCodec.unseal(
            legacy, key: Data(repeating: 0x71, count: 32), accountID: "@vault-fixture:example.org")
        let draft = ComposerFormat.paragraphs(html: try #require(state.drafts["!room:example.org"]))
        #expect(draft.map { $0.runs.map(\.text).joined() } == ["Hi @Alice, 2 < 3 & **not bold**", "> not a quote"])
        #expect(draft.allSatisfy { $0.block == nil && $0.runs.allSatisfy { $0.style.isEmpty } })
        #expect(draft[0].runs.contains { $0.mention == "@alice:example.org" })
        let thread = ThreadDraftAddress(roomID: "!room:example.org", rootID: "$root").id
        let threadDraft = ComposerFormat.paragraphs(html: try #require(state.threadDrafts[thread]))
        #expect(threadDraft.first?.runs.contains { $0.mention == "@bob:example.org" } == true)

        // Saved again, the vault keeps the HTML as it is.
        let key = Data(repeating: 0x71, count: 32)
        let resealed = try ProtectedLocalStateCodec.seal(state, key: key, accountID: "@vault-fixture:example.org")
        #expect(
            try ProtectedLocalStateCodec.unseal(resealed, key: key, accountID: "@vault-fixture:example.org") == state)
    }
}
