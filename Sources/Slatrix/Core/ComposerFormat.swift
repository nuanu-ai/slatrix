import Foundation

/// A composer paragraph's block; a plain paragraph has none.
enum ComposerBlock: String, Sendable {
    case quote, bullet, ordered, code
}

/// The composer's text as Matrix HTML. Drafts store it, and a message sends it as `formatted_body` with a plain `body`
/// beside it. Only tags from the spec's list appear, so every client renders what was typed.
enum ComposerFormat {
    struct Paragraph: Equatable {
        var block: ComposerBlock?
        /// Inline text only: no line breaks, blocks or list markers.
        var runs: [MessageBodyRun] = []
    }

    struct Message: Equatable {
        var body: String
        /// Nil when nothing is formatted, so the event carries only `body`.
        var html: String?
        var mentions: [String]
        var mentionsRoom = false
    }

    static func message(draft: String) -> Message {
        let rendered = MessageBodyRenderer.editable(body: stripped(draft), html: draft).runs
        var paragraphs = paragraphs(rendered)
        while paragraphs.last.map(isBlank) == true { paragraphs.removeLast() }
        while paragraphs.first.map(isBlank) == true { paragraphs.removeFirst() }
        let runs = paragraphs.flatMap(\.runs)
        let formatted =
            paragraphs.contains { $0.block != nil }
            || runs.contains { !$0.style.isEmpty || $0.link != nil || $0.mention != nil }
        return Message(
            body: plain(paragraphs), html: formatted ? html(paragraphs) : nil,
            mentions: Set(runs.compactMap(\.mention)).sorted(),
            mentionsRoom: rendered.contains { $0.mention == "@room" })
    }

    /// A draft's paragraphs, or a pasted fragment's.
    static func paragraphs(html: String) -> [Paragraph] {
        paragraphs(MessageBodyRenderer.editable(body: stripped(html), html: html).runs)
    }

    /// A draft saved before the composer kept formatting, or a message with only a plain body: its text exactly as
    /// written, with Element's mention links as mentions.
    static func draft(plain text: String) -> String {
        let source = text as NSString
        var runs: [MessageBodyRun] = []
        var cursor = 0
        for match in mentionLink?.matches(in: text, range: NSRange(location: 0, length: source.length)) ?? [] {
            let id = source.substring(with: match.range(at: 2)).removingPercentEncoding ?? ""
            guard MatrixID.isUser(id) else { continue }
            runs.append(
                MessageBodyRun(
                    text: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))))
            let name = source.substring(with: match.range(at: 1)).replacingOccurrences(
                of: #"\\(.)"#, with: "$1", options: .regularExpression)
            runs.append(MessageBodyRun(text: "@" + (name.isEmpty ? MatrixID.localpart(id) : name), mention: id))
            cursor = NSMaxRange(match.range)
        }
        runs.append(MessageBodyRun(text: source.substring(from: cursor)))
        return html(paragraphs(runs))
    }

    /// A message opened for editing, as a draft.
    static func draft(body: String, html: String?) -> String {
        guard let html, !html.isEmpty else { return draft(plain: body) }
        let rendered = MessageBodyRenderer.editable(body: body, html: html)
        return rendered.usedPlainTextFallback ? draft(plain: body) : self.html(paragraphs(rendered.runs))
    }

    /// `formatted_body`, and the draft. Empty when there is nothing but whitespace.
    static func html(_ paragraphs: [Paragraph]) -> String {
        guard !paragraphs.allSatisfy(isBlank) else { return "" }
        var html = ""
        var index = paragraphs.startIndex
        while index < paragraphs.endIndex {
            let block = paragraphs[index].block
            let group = paragraphs[index...].prefix { $0.block == block }
            index += group.count
            switch block {
            case nil:
                html += group.map(inline).joined(separator: "<br>")
                // A break before a block shows nothing, so an empty last line needs one more.
                if index < paragraphs.endIndex, group.last.map(isBlank) == true { html += "<br>" }
            case .quote: html += "<blockquote>" + group.map(inline).joined(separator: "<br>") + "</blockquote>"
            case .bullet, .ordered:
                let tag = block == .bullet ? "ul" : "ol"
                html += "<\(tag)>" + group.map { "<li>" + inline($0) + "</li>" }.joined() + "</\(tag)>"
            case .code:
                html +=
                    "<pre><code>" + group.map { escape($0.runs.map(\.text).joined()) }.joined(separator: "\n")
                    + "</code></pre>"
            }
        }
        return html
    }

    /// `body`: lists, quotes and code read as they would be typed, and mentions as names.
    static func plain(_ paragraphs: [Paragraph]) -> String {
        var lines: [String] = []
        var number = 0
        for (index, paragraph) in paragraphs.enumerated() {
            let previous = index > 0 ? paragraphs[index - 1].block : nil
            let next = index + 1 < paragraphs.count ? paragraphs[index + 1].block : nil
            let text = paragraph.runs.map(plainText).joined()
            number = previous == .ordered ? number + 1 : 1
            switch paragraph.block {
            case nil: lines.append(text)
            case .quote: lines.append("> " + text)
            case .bullet: lines.append("- " + text)
            case .ordered: lines.append("\(number). " + text)
            case .code:
                if previous != .code { lines.append("```") }
                lines.append(paragraph.runs.map(\.text).joined())
                if next != .code { lines.append("```") }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func isBlank(_ paragraph: Paragraph) -> Bool {
        paragraph.runs.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
    }

    private static func plainText(_ run: MessageBodyRun) -> String {
        if run.mention != nil { return run.text }
        if run.style.contains(.code) { return "`\(run.text)`" }
        if let link = run.link, link.absoluteString != run.text { return "\(run.text) (\(link.absoluteString))" }
        return run.text
    }

    private static func inline(_ paragraph: Paragraph) -> String {
        // HTML collapses spaces, so a line's leading and repeated spaces are sent as no-break spaces.
        var previous: Character?
        return paragraph.runs.map { run in
            var html: String
            if let id = run.mention {
                html =
                    "<a href=\"\(escape(MatrixID.permalink(id)))\">\(escape(String(run.text.drop { $0 == "@" })))</a>"
                previous = run.text.last
            } else {
                html = ""
                for character in run.text {
                    html +=
                        character == " " && (previous == nil || previous == " ") ? "&nbsp;" : escape(String(character))
                    previous = character
                }
                if run.style.contains(.code) { html = "<code>\(html)</code>" }
            }
            for (style, tag) in [
                (MessageTextStyle.strike, "del"), (.underline, "u"), (.italic, "em"), (.bold, "strong"),
            ]
            where run.style.contains(style) {
                html = "<\(tag)>\(html)</\(tag)>"
            }
            if run.mention == nil, let link = run.link {
                html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>"
            }
            return html
        }.joined()
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The renderer's lines as paragraphs, each block taken from the line's first run.
    private static func paragraphs(_ runs: [MessageBodyRun]) -> [Paragraph] {
        var result: [Paragraph] = []
        var lineStart = true
        for run in runs {
            for (index, line) in run.text.components(separatedBy: "\n").enumerated() {
                if index > 0 {
                    // Two breaks in a row: an empty line.
                    if lineStart { result.append(Paragraph(block: block(of: run, after: result.last?.block))) }
                    lineStart = true
                }
                guard !line.isEmpty else { continue }
                if lineStart {
                    result.append(Paragraph(block: block(of: run, after: result.last?.block)))
                    lineStart = false
                }
                guard !run.marker else { continue }
                var piece = MessageBodyRun(text: line, style: run.style, link: run.link, mention: run.mention)
                if !run.block.code { piece.text = piece.text.replacingOccurrences(of: "\u{00A0}", with: " ") }
                if let mention = run.mention, !MatrixID.isUser(mention) {
                    piece.mention = nil
                    piece.link = nil
                }
                result[result.count - 1].runs.append(piece)
            }
        }
        return result
    }

    private static func block(of run: MessageBodyRun, after previous: ComposerBlock?) -> ComposerBlock? {
        if run.block.code { return .code }
        if run.marker { return run.text.hasPrefix("•") ? .bullet : .ordered }
        if run.block.list > 0 { return previous == .ordered ? .ordered : .bullet }
        return run.block.quote > 0 ? .quote : nil
    }

    /// The text of a draft too large for the renderer, so nothing typed is lost.
    private static func stripped(_ html: String) -> String {
        html.replacingOccurrences(of: #"<br>|</(?:li|pre|blockquote)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static let mentionLink = try? NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\]])*)\]\(https://matrix\.to/#/([^)\s]+)\)"#)
}
