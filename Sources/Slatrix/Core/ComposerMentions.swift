import Foundation

/// The composer's mention tokens: "@Name" on screen, Element's Markdown link in drafts and sent messages.
enum ComposerMentions {
    struct Token: Equatable {
        /// Where "@Name" sits in the editor's text.
        var range: NSRange
        var userID: String
    }

    static func markdown(_ display: String, tokens: [Token]) -> String {
        let text = display as NSString
        var result = ""
        var cursor = 0
        for token in tokens.sorted(by: { $0.range.location < $1.range.location })
        where token.range.location >= cursor && NSMaxRange(token.range) <= text.length {
            result += text.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
            let name = text.substring(with: token.range).dropFirst().map {
                $0.isASCII && ($0.isPunctuation || $0.isSymbol) ? "\\\($0)" : String($0)
            }
            result += "[\(name.joined())](\(MatrixID.permalink(token.userID)))"
            cursor = NSMaxRange(token.range)
        }
        return result + text.substring(from: cursor)
    }

    /// Mention links become tokens, and so do bare IDs from messages sent before tokens existed, named by `name`.
    static func tokens(in markdown: String, name: (String) -> String?) -> (display: String, tokens: [Token]) {
        guard let pattern else { return (markdown, []) }
        let text = markdown as NSString
        var display = ""
        var tokens: [Token] = []
        var cursor = 0
        for match in pattern.matches(in: markdown, range: NSRange(location: 0, length: text.length)) {
            let linked = match.range(at: 2).location != NSNotFound
            let id =
                linked
                ? text.substring(with: match.range(at: 2)).removingPercentEncoding ?? ""
                : text.substring(with: match.range)
            guard MatrixID.isUser(id) else { continue }
            display += text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let label =
                linked
                ? text.substring(with: match.range(at: 1)).replacingOccurrences(
                    of: #"\\(.)"#, with: "$1", options: .regularExpression)
                : name(id) ?? ""
            let shown = "@" + (label.isEmpty ? MatrixID.localpart(id) : label)
            tokens.append(
                Token(range: NSRange(location: display.utf16.count, length: shown.utf16.count), userID: id))
            display += shown
            cursor = NSMaxRange(match.range)
        }
        return (display + text.substring(from: cursor), tokens)
    }

    private static let pattern = try? NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\]])*)\]\(https://matrix\.to/#/([^)\s]+)\)|(?<![A-Za-z0-9_])"# + MatrixID.userPattern)
}
