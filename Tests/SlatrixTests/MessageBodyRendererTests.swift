import Foundation
import Testing

@testable import Slatrix

struct MessageBodyRendererTests {
    private func render(_ html: String?, body: String = "Fallback", reveal: Bool = false) -> RenderedMessageBody {
        MessageBodyRenderer().render(body: body, formattedBody: html, revealSpoilers: reveal)
    }

    @Test("Entities and line breaks render as text")
    func entitiesAndBreaks() {
        let text = render("<p>Hello &amp; &nbsp; &#x1F44B;<br>next</p>").plainText
        #expect(text.contains("& \u{00A0} 👋") && text.contains("\nnext"))
    }

    @Test("Inline styles and preformatted whitespace survive rendering")
    func inlineStyles() {
        let runs = render(
            "<p><strong>bold</strong> <em>italic</em> <s>strike</s> <code>inline</code></p><pre>  let x = 1\n  let y = 2</pre>"
        ).runs
        #expect(runs.contains { $0.text == "bold" && $0.style.contains(.bold) })
        #expect(runs.contains { $0.text == "italic" && $0.style.contains(.italic) })
        #expect(runs.contains { $0.text == "strike" && $0.style.contains(.strike) })
        #expect(runs.contains { $0.style.contains(.code) && $0.text.contains("  let y = 2") })
    }

    @Test("Struck text keeps the space after it, as Element sends it")
    func strikeSpacing() {
        let rendered = render("<del>struck</del> and <DEL>more</DEL>")
        #expect(rendered.plainText == "struck and more")
        #expect(rendered.runs.filter { $0.style.contains(.strike) }.map(\.text) == ["struck", "more"])
    }

    @Test("Malformed HTML still renders its text")
    func malformed() {
        #expect(render("<p>Unclosed <strong>bold").plainText.contains("Unclosed bold"))
    }

    @Test("Ordered lists keep their start number and nested lists indent")
    func lists() {
        let runs = render("<ol start='3'><li>one<ul><li>nested</li></ul></li><li>two</li></ol>").runs
        #expect(runs.filter(\.marker).map(\.text) == ["3. ", "• ", "4. "])
        #expect(runs.filter(\.marker).map(\.block.list) == [1, 2, 1])
        #expect(runs.first { $0.text.hasPrefix("nested") }?.block.list == 2)
    }

    @Test("A legacy reply fallback is not shown")
    func replyFallback() {
        let text = render(
            "<mx-reply><blockquote>Untrusted fallback</blockquote></mx-reply><p>Answer</p>", body: "Answer"
        ).plainText
        #expect(text == "Answer")
    }

    @Test("Images and scripts stay inert")
    func inertResources() {
        let rendered = render(
            "<p>safe<img src='https://invalid.example/tracker' alt=' picture'><img src='file:///nonexistent/x'></p><script>secret()</script>",
            body: "safe")
        #expect(rendered.plainText.contains("safe") && !rendered.plainText.contains("secret"))
        #expect(rendered.runs.allSatisfy { $0.link == nil })
    }

    @Test("A document with an entity declaration falls back to the plain body")
    func externalEntity() {
        let rendered = render(
            "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///nonexistent/x'>]><p>&x;</p>", body: "literal")
        #expect(rendered.usedPlainTextFallback && rendered.plainText == "literal")
    }

    @Test("Spoilers stay hidden until revealed")
    func spoilers() {
        let hidden = render("<span data-mx-spoiler='ending'>secret</span>", body: "secret")
        #expect(hidden.containsSpoilers && !hidden.plainText.contains("secret"))
        let revealed = render("<span data-mx-spoiler>secret</span>", body: "secret", reveal: true)
        #expect(revealed.plainText == "secret")
    }

    @Test("Only safe links become clickable")
    func linkAllowlist() {
        let runs = render("<a href='javascript:alert(1)'>unsafe</a> <a href='https://example.org'>safe</a>").runs
        #expect(!runs.contains { $0.text.contains("unsafe") && $0.link != nil })
        #expect(runs.contains { $0.link?.host == "example.org" })
    }

    @Test(
        "Local, data and credential-bearing links are refused",
        arguments: ["file:///tmp/example", "data:text/html,test", "https://user:password@example.org"])
    func unsafeLinks(link: String) {
        #expect(MessageBodyRenderer.safeLink(link) == nil)
    }

    @Test("Mail and Matrix links are allowed", arguments: ["mailto:hello@example.org", "matrix:u/alice:example.org"])
    func nativeLinks(link: String) {
        #expect(MessageBodyRenderer.safeLink(link) != nil)
    }

    @Test(
        "Addresses typed into a message become links",
        arguments: [
            (
                nil, "See https://example.org/docs?a=1 today", "https://example.org/docs?a=1",
                "https://example.org/docs?a=1"
            ),
            (nil, "Docs at www.example.org.", "www.example.org", "http://www.example.org"),
            (nil, "Write to hello@example.org", "hello@example.org", "mailto:hello@example.org"),
            ("<p>Read <b>https://example.org</b> now</p>", "", "https://example.org", "https://example.org"),
        ] as [(String?, String, String, String)])
    func typedLinks(html: String?, body: String, text: String, url: String) {
        let runs = render(html, body: body).runs
        #expect(runs.contains { $0.text == text && $0.link?.absoluteString == url })
        #expect(runs.map(\.text).joined() == render(html, body: body).plainText)
    }

    @Test("Addresses in code, and schemes that aren't safe, stay plain text")
    func untypedLinks() {
        #expect(render("<p><code>https://example.org</code></p>").runs.allSatisfy { $0.link == nil })
        #expect(render("<pre>curl https://example.org</pre>").runs.allSatisfy { $0.link == nil })
        #expect(render(nil, body: "Open file:///etc/hosts or ftp://example.org").runs.allSatisfy { $0.link == nil })
    }

    @Test("A typed address inside a link keeps the link's own target")
    func anchorWins() {
        let runs = render("<a href='https://example.org/target'>https://example.org/shown</a>").runs
        #expect(runs.allSatisfy { $0.link == nil || $0.link?.path == "/target" })
    }

    @Test("A plain body is shown literally, not as Markdown")
    func plainIsLiteral() {
        #expect(render(nil, body: "**literal**").plainText == "**literal**")
    }

    @Test("Unsupported markup falls back to the plain body")
    func unsupportedMarkup() {
        #expect(render("2<sup>3</sup>", body: "2 cubed").plainText == "2 cubed")
    }

    @Test(
        "Hostile HTML that exceeds a depth, size, node or output bound falls back to the plain body",
        arguments: [
            String(repeating: "<div>", count: 110) + "deep" + String(repeating: "</div>", count: 110),
            String(repeating: "x", count: 70_000),
            String(repeating: "<b>x</b>", count: 2_100),
            String(repeating: "<blockquote>", count: 60) + String(repeating: "x<br>", count: 1_000)
                + String(repeating: "</blockquote>", count: 60),
        ])
    func boundedParsing(html: String) {
        #expect(render(html, body: "literal").usedPlainTextFallback)
    }

    @Test("A huge plain body is cut with a notice")
    func boundedPlainText() {
        let body = String(repeating: "👋", count: 70_000)
        let text = render(nil, body: body).plainText
        #expect(text.utf16.count < body.utf16.count && text.hasSuffix("[Message exceeds the display limit]"))
    }

    @Test("Runs of whitespace collapse to one space and never start a line")
    func collapsesWhitespace() {
        #expect(render("<p>  one \n\t two</p><p> three</p>").plainText == "one two\nthree")
    }

    @Test("Paragraphs start on a new line; two line breaks leave an empty line")
    func lineBreaks() {
        #expect(render("<p>one</p><p>two</p>").plainText == "one\ntwo")
        #expect(render("one<br><br>two").plainText == "one\n\ntwo")
    }

    @Test("A quote's lines, line breaks included, carry its depth instead of a marker; the text after it has none")
    func quotes() {
        let rendered = render("<blockquote>first<br>second<blockquote>inner</blockquote></blockquote><p>after</p>")
        #expect(rendered.plainText == "first\nsecond\ninner\nafter")
        let depths = rendered.runs.flatMap { run in run.text.map { _ in run.block.quote } }
        #expect(
            depths == Array(repeating: 1, count: 13) + Array(repeating: 2, count: 6) + Array(repeating: 0, count: 5))
    }

    @Test("Table cells are separated by tabs")
    func tableCells() {
        let cells = render("<table><tr><td>a</td><th>b</th></tr></table>").plainText.split(separator: "\t")
        #expect(cells.map { $0.trimmingCharacters(in: .whitespaces) } == ["a", "b"])
    }

    @Test("An image shows its alt text")
    func imageAltText() {
        #expect(render("<p>see <img src='mxc://example.org/x' alt='diagram'></p>").plainText == "see diagram")
    }

    @Test("Maths markup falls back to the plain body", arguments: ["span", "div"])
    func maths(element: String) {
        let rendered = render("<\(element) data-mx-maths='x^2'>x2</\(element)>", body: "x^2")
        #expect(rendered.usedPlainTextFallback && rendered.plainText == "x^2")
    }

    @Test("HTML that renders to nothing shows the plain body instead")
    func emptyRenderFallsBack() {
        #expect(render("<script>hidden()</script>", body: "Look").plainText == "Look")
    }

    @Test("A spoiler stays hidden when its message falls back to the plain body")
    func spoilerInFallback() {
        let html = "<span data-mx-spoiler>secret</span> 2<sup>3</sup>"
        #expect(render(html, body: "secret 2^3").plainText == "[Spoiler hidden]")
        #expect(render(html, body: "secret 2^3", reveal: true).plainText == "secret 2^3")
    }

    @Test(
        "A link to a person reads @ and the link's text and carries their ID",
        arguments: [
            "https://matrix.to/#/@alice:example.org", "https://matrix.to/#/%40alice%3Aexample.org?via=example.org",
            "matrix:u/alice:example.org?action=chat",
        ])
    func personLink(href: String) {
        let runs = render("<p>Hi <a href=\"\(href)\">Alice</a>!</p>").runs
        #expect(runs.map(\.text).joined() == "Hi @Alice!")
        #expect(runs.first { $0.text == "@Alice" }?.mention == "@alice:example.org")
    }

    @Test(
        "Links to one person with nothing between them are one pill; a space or another person keeps pills apart",
        arguments: [
            // As 0.2.8 and 0.2.9 sent a mention: split before its last letter.
            ([("dl", "deadlock agen"), ("dl", "t")], "", ["@deadlock agent"]),
            ([("dl", "deadlock agent"), ("dl", "deadlock agent")], " ", ["@deadlock agent", "@deadlock agent"]),
            ([("alice", "Alice"), ("bob", "Bob")], "", ["@Alice", "@Bob"]),
        ])
    func adjacentPersonLinks(links: [(String, String)], between: String, pills: [String]) {
        let html = links.map { "<a href=\"https://matrix.to/#/@\($0):example.org\">\($1)</a>" }
            .joined(separator: between)
        #expect(render(html).runs.filter { $0.mention != nil }.map(\.text) == pills)
    }

    @Test("A bare ID reads @ and its localpart, and @room mentions everyone")
    func bareMentions() {
        let runs = render(nil, body: "@room ping @alice:example.org.").runs
        #expect(runs.map(\.text).joined() == "@room ping @alice.")
        #expect(runs.compactMap(\.mention) == ["@room", "@alice:example.org"])
    }

    @Test("Mentions in code, and addresses that only look like mentions, stay text")
    func notMentions() {
        let runs = render(
            "<p><code>@alice:example.org</code> bob@example.org.com email@room.org @roommate</p><pre>@room</pre>"
        ).runs
        #expect(runs.allSatisfy { $0.mention == nil })
    }

    @Test(
        "A person link with an unsafe or foreign target is not a mention",
        arguments: ["javascript://matrix.to/#/@alice:example.org", "https://evil.example/#/@alice:example.org"])
    func foreignPersonLink(href: String) {
        let runs = render("<a href=\"\(href)\">Alice</a>").runs
        #expect(runs.map(\.text).joined() == "Alice" && runs.allSatisfy { $0.mention == nil })
        #expect(runs.allSatisfy { $0.link == nil || $0.link?.host == "evil.example" })
    }

    @Test("A bare ID shows the member's name when the conversation knows it; a linked name stays as sent")
    func memberNames() {
        let names = ["@alice:example.org": "Alice Liddell", "@bob:example.org": "Robert"]
        let bare = MessageBodyRenderer.named(render(nil, body: "@alice:example.org and @carol:example.org").runs) {
            names[$0]
        }
        #expect(bare.map(\.text).joined() == "@Alice Liddell and @carol")
        let linked = MessageBodyRenderer.named(render("<a href='https://matrix.to/#/@bob:example.org'>Bobby</a>").runs)
        {
            names[$0]
        }
        #expect(linked.map(\.text).joined() == "@Bobby")
    }
}
