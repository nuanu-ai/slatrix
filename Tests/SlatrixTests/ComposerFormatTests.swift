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
        "Each format writes standard HTML",
        arguments: [
            (
                [Paragraph(runs: [.init(text: "Hi "), .init(text: "there", style: .bold)])],
                "Hi <strong>there</strong>"
            ),
            ([Paragraph(runs: [.init(text: "soft", style: .italic)])], "<em>soft</em>"),
            ([Paragraph(runs: [.init(text: "gone", style: .strike)])], "<del>gone</del>"),
            ([Paragraph(runs: [.init(text: "a < b", style: .code)])], "<code>a &lt; b</code>"),
            (
                [Paragraph(runs: [.init(text: "docs", link: URL(string: "https://example.org/a?b=1&c"))])],
                "<a href=\"https://example.org/a?b=1&amp;c\">docs</a>"
            ),
            (
                [
                    Paragraph(block: .bullet, runs: [.init(text: "one")]),
                    Paragraph(block: .bullet, runs: [.init(text: "two")]),
                ],
                "<ul><li>one</li><li>two</li></ul>"
            ),
            (
                [
                    Paragraph(block: .ordered, runs: [.init(text: "one")]),
                    Paragraph(block: .ordered, runs: [.init(text: "two")]),
                ],
                "<ol><li>one</li><li>two</li></ol>"
            ),
            (
                [
                    Paragraph(block: .quote, runs: [.init(text: "said")]),
                    Paragraph(block: .quote, runs: [.init(text: "this")]),
                ],
                "<blockquote>said<br>this</blockquote>"
            ),
            (
                [
                    Paragraph(block: .code, runs: [.init(text: "if a < b {")]),
                    Paragraph(block: .code, runs: [.init(text: "  go()")]),
                ],
                "<pre><code>if a &lt; b {\n  go()</code></pre>"
            ),
            (
                [Paragraph(runs: [.init(text: "Thanks "), alice])],
                "Thanks <a href=\"https://matrix.to/#/@alice:example.org\">Alice Liddell</a>"
            ),
            (
                [
                    Paragraph(runs: [.init(text: "2 * 3 = **six** & <done>")]),
                    Paragraph(runs: [.init(text: "> not a quote")]),
                ],
                "2 * 3 = **six** &amp; &lt;done&gt;<br>&gt; not a quote"
            ),
        ] as [([Paragraph], String)])
    private func format(paragraphs: [Paragraph], html: String) {
        #expect(ComposerFormat.html(paragraphs) == html)
    }

    struct Send: Decodable, CustomTestStringConvertible {
        var name: String
        var draft: String
        var body: String
        var html: String?
        var mentions: [String]
        var mentionsRoom: Bool
        var testDescription: String { name }
    }

    struct Spec: Decodable { var send: [Send] }

    // capability: composer.formatting
    @Test(
        "What a draft sends, from spec/composer.json",
        arguments: try SharedSpec.decode("spec/composer.json", as: Spec.self).send)
    func send(spec: Send) {
        let message = ComposerFormat.message(draft: spec.draft)
        #expect(message.body == spec.body)
        #expect(message.html == spec.html)
        #expect(message.mentions == spec.mentions)
        #expect(message.mentionsRoom == spec.mentionsRoom)
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

    // capability: composer.drafts
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

    @Test("A draft with a mention split as 0.2.8 and 0.2.9 saved it reopens as one token")
    func splitMentionDraft() {
        let link = "https://matrix.to/#/@dl:example.org"
        let draft = "<a href=\"\(link)\">deadlock agen</a><a href=\"\(link)\">t</a> "
        let mentions = ComposerFormat.paragraphs(html: draft).flatMap(\.runs).filter { $0.mention != nil }
        #expect(mentions.map(\.text) == ["@deadlock agent"])
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
