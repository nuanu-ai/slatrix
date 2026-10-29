import Foundation

struct MessageTextStyle: OptionSet, Hashable, Sendable {
    let rawValue: UInt8
    static let bold = Self(rawValue: 1 << 0)
    static let italic = Self(rawValue: 1 << 1)
    static let strike = Self(rawValue: 1 << 2)
    static let code = Self(rawValue: 1 << 3)
    static let underline = Self(rawValue: 1 << 4)
}

/// Where a run sits among a message's blocks, which rows indent and decorate.
struct MessageBlock: Hashable, Sendable {
    var quote = 0
    var list = 0
    /// Inside `<pre>`.
    var code = false
}

struct MessageBodyRun: Hashable, Sendable {
    var text: String
    var style: MessageTextStyle = []
    var link: URL? = nil
    /// The user ID a mention names, or "@room".
    var mention: String? = nil
    var block = MessageBlock()
    /// A list item's "• " or "3. ".
    var marker = false
}

struct RenderedMessageBody: Sendable {
    var runs: [MessageBodyRun]
    var containsSpoilers: Bool
    var usedPlainTextFallback: Bool
    var plainText: String { runs.map(\.text).joined() }
}

/// Renders Matrix HTML bodies into styled runs. The cache is shared by every thread, so a timeline renders its
/// bodies when its items arrive and rows read the result synchronously on their first frame.
final class MessageBodyRenderer: @unchecked Sendable {
    static let shared = MessageBodyRenderer()
    private static let maximumInputBytes = 65_536
    private static let maximumOutputUnits = 65_536
    private static let maximumNodes = 4_096
    // 100 levels of walk() overflow a 512 KiB concurrency-thread stack in debug builds; 50 leaves a wide margin.
    private static let maximumDepth = 50
    // Several thousand messages: a few busy rooms visited in one session.
    private static let maximumCacheEntries = 8_192
    private static let maximumCacheBytes = 24 * 1_024 * 1_024

    private struct Key: Hashable {
        var body: String
        var html: String?
        var revealSpoilers: Bool
    }
    private struct Entry {
        var result: RenderedMessageBody
        var cost: Int
    }
    private let lock = NSLock()
    private var cache: [Key: Entry] = [:]
    private var insertionOrder: [Key] = []
    private var cacheBytes = 0

    func clearCache() {
        lock.withLock {
            cache.removeAll()
            insertionOrder.removeAll()
            cacheBytes = 0
        }
    }

    /// Safe on any thread. Parses outside the lock, so two threads may render the same body once each.
    func render(body: String, formattedBody: String?, revealSpoilers: Bool = false) -> RenderedMessageBody {
        let key = Key(body: body, html: formattedBody, revealSpoilers: revealSpoilers)
        if let entry = lock.withLock({ cache[key] }) { return entry.result }
        var result = Self.parse(body: body, html: formattedBody, revealSpoilers: revealSpoilers)
        result.runs = Self.linkified(Self.mentioned(result.runs))
        let cost =
            body.utf8.count + (formattedBody?.utf8.count ?? 0) + result.runs.reduce(0) { $0 + $1.text.utf8.count + 128 }
        guard cost <= Self.maximumCacheBytes / 4 else { return result }
        lock.withLock {
            guard cache[key] == nil else { return }
            while !insertionOrder.isEmpty
                && (cache.count >= Self.maximumCacheEntries || cacheBytes + cost > Self.maximumCacheBytes)
            {
                let oldest = insertionOrder.removeFirst()
                if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= removed.cost }
            }
            cache[key] = Entry(result: result, cost: cost)
            insertionOrder.append(key)
            cacheBytes += cost
        }
        return result
    }

    /// For the composer: spoilers shown, typed IDs as mentions, addresses left as typed, and nothing cached.
    static func editable(body: String, html: String) -> RenderedMessageBody {
        var result = parse(body: body, html: html, revealSpoilers: true)
        result.runs = mentioned(result.runs)
        return result
    }

    static func safeLink(_ source: String) -> URL? {
        guard source.count <= 4_096,
            !source.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            let components = URLComponents(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = components.scheme?.lowercased(), ["https", "http", "mailto", "matrix"].contains(scheme),
            components.user == nil, components.password == nil
        else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
        } else if components.path.isEmpty {
            return nil
        }
        return components.url
    }

    private static let addresses = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let mentions = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_])(?:" + MatrixID.userPattern + "|@room(?![A-Za-z0-9_:]))")

    /// Web and mail addresses typed as plain text become links, as in Slack. Code and existing links keep their text.
    private static func linkified(_ runs: [MessageBodyRun]) -> [MessageBodyRun] {
        split(runs, by: addresses, containing: ".") { match, text, style in
            match.url.flatMap { safeLink($0.absoluteString) }.map { MessageBodyRun(text: text, style: style, link: $0) }
        }
    }

    /// User IDs and @room typed as plain text become mentions, which read "@localpart" until a view names them.
    private static func mentioned(_ runs: [MessageBodyRun]) -> [MessageBodyRun] {
        split(runs, by: mentions, containing: "@") { _, id, style in
            id == "@room"
                ? MessageBodyRun(text: id, style: style, mention: id)
                : MessageBodyRun(
                    text: "@" + MatrixID.localpart(id), style: style, link: URL(string: MatrixID.permalink(id)),
                    mention: id)
        }
    }

    private static func split(
        _ runs: [MessageBodyRun], by expression: NSRegularExpression?, containing marker: Character,
        replace: (NSTextCheckingResult, String, MessageTextStyle) -> MessageBodyRun?
    ) -> [MessageBodyRun] {
        guard let expression else { return runs }
        var result: [MessageBodyRun] = []
        for run in runs {
            guard run.link == nil, run.mention == nil, !run.marker, !run.style.contains(.code),
                run.text.contains(marker)
            else {
                result.append(run)
                continue
            }
            let text = run.text as NSString
            var cursor = 0
            for match in expression.matches(in: run.text, range: NSRange(location: 0, length: text.length)) {
                guard var replaced = replace(match, text.substring(with: match.range), run.style) else { continue }
                if match.range.location > cursor {
                    let before = NSRange(location: cursor, length: match.range.location - cursor)
                    result.append(
                        MessageBodyRun(text: text.substring(with: before), style: run.style, block: run.block))
                }
                replaced.block = run.block
                result.append(replaced)
                cursor = NSMaxRange(match.range)
            }
            if cursor < text.length {
                result.append(MessageBodyRun(text: text.substring(from: cursor), style: run.style, block: run.block))
            }
        }
        return result
    }

    /// The person a matrix.to or matrix: link points at, when it points at a person.
    private static func mentionedUser(_ link: URL?) -> String? {
        guard let link, let parts = URLComponents(url: link, resolvingAgainstBaseURL: false) else { return nil }
        let id: String
        if parts.scheme == "https", parts.host?.lowercased() == "matrix.to", let fragment = parts.fragment,
            fragment.hasPrefix("/@")
        {
            id = String(fragment.dropFirst().prefix { $0 != "?" })
        } else if parts.scheme == "matrix", parts.path.hasPrefix("u/") {
            id = "@" + parts.path.dropFirst(2)
        } else {
            return nil
        }
        return MatrixID.isUser(id) ? id : nil
    }

    /// A mention that reads "@localpart" shows the member's display name once the conversation knows it.
    static func named(_ runs: [MessageBodyRun], name: (String) -> String?) -> [MessageBodyRun] {
        runs.map { run in
            guard let id = run.mention, run.text == "@" + MatrixID.localpart(id), let name = name(id), !name.isEmpty
            else { return run }
            var named = run
            named.text = "@" + name
            return named
        }
    }

    private enum ParseFailure: Error { case limit, unsupported }
    private struct Context {
        var style: MessageTextStyle = []
        var link: URL? = nil
        var mention: String? = nil
        var block = MessageBlock()
        var marker = false
    }

    private struct Builder {
        var runs: [MessageBodyRun] = []
        var outputUnits = 0
        var visitedNodes = 0
        var containsSpoilers = false
        var lastCharacter: Character? { runs.last?.text.last }

        mutating func append(_ value: String, context: Context, literal: Bool = false) throws {
            var normalized = ""
            var previous = lastCharacter
            for character in value {
                if !literal && !context.block.code && [" ", "\n", "\r", "\t", "\u{000C}"].contains(character) {
                    if previous != nil && previous != " " && previous != "\n" {
                        normalized.append(" ")
                        previous = " "
                    }
                } else {
                    normalized.append(character)
                    previous = character
                }
            }
            guard !normalized.isEmpty else { return }
            outputUnits += normalized.utf16.count
            guard outputUnits <= MessageBodyRenderer.maximumOutputUnits else { throw ParseFailure.limit }
            let run = MessageBodyRun(
                text: normalized, style: context.style, link: context.link, mention: context.mention,
                block: context.block, marker: context.marker)
            if let last = runs.indices.last, !run.marker, !runs[last].marker, runs[last].style == run.style,
                runs[last].link == run.link, runs[last].mention == run.mention, runs[last].block == run.block
            {
                runs[last].text += normalized
            } else {
                runs.append(run)
            }
        }

        /// A line break belongs to the line it ends, so a quote's or code block's lines stay one block.
        mutating func newline(force: Bool = false) throws {
            // A paragraph that opens a list item stays on its bullet's line.
            guard runs.last?.marker != true else { return }
            trimEnd(spacesOnly: true)
            if !runs.isEmpty && (force || lastCharacter != "\n") {
                try append("\n", context: Context(block: runs.last?.block ?? MessageBlock()), literal: true)
            }
        }

        mutating func trimEnd(spacesOnly: Bool = false) {
            while let last = runs.indices.last {
                while let tail = runs[last].text.last, tail == " " || (!spacesOnly && (tail == "\n" || tail == "\r")) {
                    runs[last].text.removeLast()
                }
                if runs[last].text.isEmpty { runs.removeLast() } else { break }
            }
        }
    }

    private static func fallback(_ body: String, html: String?, revealSpoilers: Bool) -> RenderedMessageBody {
        let spoiler = html?.localizedCaseInsensitiveContains("data-mx-spoiler") == true
        let text = spoiler && !revealSpoilers ? "[Spoiler hidden]" : boundedLiteral(body)
        return RenderedMessageBody(
            runs: [MessageBodyRun(text: text)], containsSpoilers: spoiler, usedPlainTextFallback: true)
    }

    static func boundedLiteral(_ body: String) -> String {
        guard body.utf16.count > maximumOutputUnits else { return body }
        let notice = "\n[Message exceeds the display limit]"
        let available = maximumOutputUnits - notice.utf16.count
        var result = ""
        var used = 0
        for character in body {
            let size = String(character).utf16.count
            guard used + size <= available else { break }
            result.append(character)
            used += size
        }
        return result + notice
    }

    private static func parse(body: String, html: String?, revealSpoilers: Bool) -> RenderedMessageBody {
        guard let html, !html.isEmpty else { return fallback(body, html: html, revealSpoilers: revealSpoilers) }
        guard html.utf8.count <= maximumInputBytes,
            !html.localizedCaseInsensitiveContains("<!doctype"), !html.localizedCaseInsensitiveContains("<!entity")
        else {
            return fallback(body, html: html, revealSpoilers: revealSpoilers)
        }
        // Foundation's HTML tidier drops unknown mx-reply wrappers while retaining their contents.
        let prepared = html.replacingOccurrences(
            of: "<mx-reply>", with: "<div data-slatrix-reply-fallback=\"true\">", options: .caseInsensitive
        )
        .replacingOccurrences(of: "</mx-reply>", with: "</div>", options: .caseInsensitive)
        // It also takes <del> for a block and eats the space after it; <s> means the same and stays inline.
        .replacingOccurrences(of: #"(?i)<(/?)del(?=[\s>])"#, with: "<$1s", options: .regularExpression)
        guard !prepared.localizedCaseInsensitiveContains("<mx-reply"),
            !prepared.localizedCaseInsensitiveContains("</mx-reply")
        else {
            return fallback(body, html: html, revealSpoilers: revealSpoilers)
        }
        do {
            let document = try XMLDocument(
                xmlString: "<html><body>" + prepared + "</body></html>",
                options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
            guard let root = document.rootElement(), let element = root.elements(forName: "body").first else {
                return fallback(body, html: html, revealSpoilers: revealSpoilers)
            }
            var builder = Builder()
            for child in element.children ?? [] {
                try walk(child, context: Context(), depth: 0, revealSpoilers: revealSpoilers, builder: &builder)
            }
            builder.trimEnd()
            if builder.runs.isEmpty && !body.isEmpty {
                return fallback(body, html: html, revealSpoilers: revealSpoilers)
            }
            return RenderedMessageBody(
                runs: builder.runs, containsSpoilers: builder.containsSpoilers, usedPlainTextFallback: false)
        } catch { return fallback(body, html: html, revealSpoilers: revealSpoilers) }
    }

    private static func walk(
        _ node: XMLNode, context: Context, depth: Int, revealSpoilers: Bool, builder: inout Builder
    ) throws {
        builder.visitedNodes += 1
        guard depth <= maximumDepth, builder.visitedNodes <= maximumNodes else { throw ParseFailure.limit }
        if node.kind == .text {
            try builder.append(node.stringValue ?? "", context: context)
            return
        }
        guard let element = node as? XMLElement else { return }
        let name = (element.localName ?? element.name ?? "").lowercased()
        if element.attribute(forName: "data-slatrix-reply-fallback") != nil { return }
        if [
            "script", "style", "iframe", "object", "embed", "link", "meta", "base", "head", "title", "form", "input",
            "button", "textarea", "select", "option", "svg", "video", "audio", "source",
        ].contains(name) {
            return
        }
        if element.attribute(forName: "data-mx-maths") != nil || name == "math" { throw ParseFailure.unsupported }
        if element.attribute(forName: "data-mx-spoiler") != nil {
            builder.containsSpoilers = true
            if !revealSpoilers {
                try builder.append("[Spoiler hidden]", context: context)
                return
            }
        }
        var next = context
        switch name {
        case "b", "strong":
            // Google Docs wraps everything it copies in <b style="font-weight:normal">.
            if element.attribute(forName: "style")?.stringValue?.contains("font-weight:normal") != true {
                next.style.insert(.bold)
            }
        case "i", "em": next.style.insert(.italic)
        case "s", "strike", "del": next.style.insert(.strike)
        case "u": next.style.insert(.underline)
        case "code", "tt": next.style.insert(.code)
        case "pre":
            next.style.insert(.code)
            next.block.code = true
        case "a":
            next.link = element.attribute(forName: "href").flatMap { safeLink($0.stringValue ?? "") }
            if let id = mentionedUser(next.link) {
                next.mention = id
                let name = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let shown = name.isEmpty || name == id ? MatrixID.localpart(id) : String(name.drop { $0 == "@" })
                // 0.2.8 and 0.2.9 split each mention into two links before its last letter; the second continues it.
                try builder.append((builder.runs.last?.mention == id ? "" : "@") + shown, context: next)
                return
            }
        case "blockquote": next.block.quote += 1
        case "br":
            try builder.newline(force: true)
            return
        case "hr":
            try builder.newline()
            try builder.append("—", context: context)
            try builder.newline()
            return
        case "img":
            if let alt = element.attribute(forName: "alt")?.stringValue, !alt.isEmpty {
                try builder.append(alt, context: context)
            }
            return
        case "ul", "ol":
            try builder.newline()
            var number = Int(element.attribute(forName: "start")?.stringValue ?? "1") ?? 1
            guard (-1_000_000...1_000_000).contains(number) else { throw ParseFailure.limit }
            for child in element.children ?? [] {
                guard let item = child as? XMLElement,
                    item.localName?.lowercased() == "li" || item.name?.lowercased() == "li"
                else { continue }
                builder.visitedNodes += 1
                guard builder.visitedNodes <= maximumNodes, depth + 1 <= maximumDepth else { throw ParseFailure.limit }
                try builder.newline()
                var nested = next
                nested.block.list += 1
                try builder.append(
                    name == "ol" ? "\(number). " : "• ", context: Context(block: nested.block, marker: true),
                    literal: true)
                for child in item.children ?? [] {
                    try walk(
                        child, context: nested, depth: depth + 2, revealSpoilers: revealSpoilers, builder: &builder)
                }
                number += 1
            }
            try builder.newline()
            return
        case "p", "div", "span", "li", "html", "body", "h1", "h2", "h3", "h4", "h5", "h6", "table", "thead", "tbody",
            "tfoot", "tr", "td", "th", "font":
            break
        default: throw ParseFailure.unsupported
        }
        let block = ["p", "div", "pre", "blockquote", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "tr"].contains(
            name)
        if block { try builder.newline() }
        if ["h1", "h2", "h3", "h4", "h5", "h6", "th"].contains(name) { next.style.insert(.bold) }
        for child in element.children ?? [] {
            try walk(child, context: next, depth: depth + 1, revealSpoilers: revealSpoilers, builder: &builder)
        }
        if name == "td" || name == "th" { try builder.append("\t", context: Context(), literal: true) }
        if block { try builder.newline() }
    }
}
