import Foundation

/// One emoji the picker offers: what it inserts, where it sits and what Slack calls it.
struct Emoji: Hashable, Sendable {
    enum Category: Int, CaseIterable, Sendable {
        case smileys, people, nature, food, activities, travel, objects, symbols, flags
    }
    let value: String
    let category: Category
    /// Slack's shortcodes, its own first: `+1`, `thumbsup`.
    let shortcodes: [String]
    let name: String
    /// The light-skinned form of an emoji that takes a skin tone.
    let toned: String?

    func value(tone: SkinTone) -> String {
        guard let toned, let modifier = tone.modifier else { return value }
        return toned.replacingOccurrences(of: SkinTone.light.modifier!, with: modifier)
    }
}

enum SkinTone: Int, CaseIterable, Sendable {
    case none, light, mediumLight, medium, mediumDark, dark
    /// U+1F3FB through U+1F3FF.
    var modifier: String? { self == .none ? nil : String(UnicodeScalar(0x1F3FA + UInt32(rawValue))!) }
}

enum EmojiCatalog {
    static let all: [Emoji] = source.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, let index = Int(fields[1]), let category = Emoji.Category(rawValue: index) else {
            return nil
        }
        return Emoji(
            value: fields[0], category: category, shortcodes: fields[2].split(separator: " ").map(String.init),
            name: fields[3], toned: fields.count > 4 ? fields[4] : nil)
    }

    private static let byKey = Dictionary(all.map { (key($0.value), $0) }, uniquingKeysWith: { first, _ in first })

    /// Without presentation selectors or skin tones, so a heart sent as U+2764 alone, or a toned thumb, finds its
    /// emoji.
    private static func key(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value != 0xFE0F && tone($0) == nil }))
    }
    private static func tone(_ scalar: Unicode.Scalar) -> Int? {
        (0x1F3FB...0x1F3FF).contains(scalar.value) ? Int(scalar.value - 0x1F3FA) : nil
    }

    static func emoji(for value: String) -> Emoji? { byKey[key(value)] }

    /// `:+1:`, `:+1::skin-tone-4:` for a toned one, as Slack writes them; anything else as it is.
    static func shortcode(for value: String) -> String {
        guard let emoji = emoji(for: value), let code = emoji.shortcodes.first else { return value }
        // Slack numbers the five tones 2 through 6.
        let tone = value.unicodeScalars.lazy.compactMap(tone).first.map { ":skin-tone-\($0 + 1):" } ?? ""
        return ":\(code):" + tone
    }

    /// Exact shortcodes first, then shortcodes the query starts, then words that start with it, then anything
    /// that contains it; picker order within each.
    static func search(_ query: String) -> [Emoji] {
        let code = query.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":")))
            .lowercased()
        guard !code.isEmpty else { return [] }
        let words = code.replacingOccurrences(of: "_", with: " ")
        var tiers: [[Emoji]] = [[], [], [], []]
        for emoji in all {
            let codes = emoji.shortcodes
            if codes.contains(code) {
                tiers[0].append(emoji)
            } else if codes.contains(where: { $0.hasPrefix(code) }) {
                tiers[1].append(emoji)
            } else if emoji.name.hasPrefix(words) || emoji.name.contains(" " + words)
                || codes.contains(where: { $0.contains("_" + code) || $0.contains("-" + code) })
            {
                tiers[2].append(emoji)
            } else if emoji.name.contains(words) || codes.contains(where: { $0.contains(code) }) {
                tiers[3].append(emoji)
            }
        }
        return tiers.flatMap { $0 }
    }
}

/// Recently used emoji, newest first, as Element keeps them in `io.element.recent_emoji`.
enum EmojiRecents {
    /// Slack's one-click reactions before you have used any.
    private static let defaults = ["✅", "👀", "🙌", "👍", "🎉"]

    static func adding(_ emoji: String, to recent: [String]) -> [String] { [emoji] + recent.filter { $0 != emoji } }

    /// The one-click reactions: three on the hover toolbar, five in Android's message sheet.
    static func quick(_ recent: [String], count: Int = 3) -> [String] {
        Array((recent + defaults.filter { !recent.contains($0) }).prefix(count))
    }
}

extension MessageReaction {
    /// "Alice, Bob and 3 others reacted with :+1:", you first; `name` resolves a member's display name.
    func tooltip(me: String?, name: (String) -> String?) -> String {
        let ordered = senders.filter { $0 == me } + senders.filter { $0 != me }
        let names = ordered.map { $0 == me ? "You" : name($0) ?? MatrixID.localpart($0) }
        let who =
            switch names.count {
            case 0: "\(count) \(count == 1 ? "person" : "people")"
            case 1: names[0]
            case 2, 3: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            default: "\(names[0]), \(names[1]) and \(names.count - 2) others"
            }
        return "\(who) reacted with \(EmojiCatalog.shortcode(for: key))"
    }
}

/// Where the arrow keys take the selection in a grid of non-empty sections that each start a new row.
enum EmojiGrid {
    enum Direction { case up, down, left, right }

    static func move(_ index: Int, _ direction: Direction, sizes: [Int], columns: Int) -> Int {
        let starts = sizes.indices.map { sizes[..<$0].reduce(0, +) }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return 0 }
        let section = starts.lastIndex { $0 <= index } ?? 0
        let position = index - starts[section]
        let column = position % columns
        switch direction {
        case .left: return max(0, index - 1)
        case .right: return min(total - 1, index + 1)
        case .down:
            if position / columns < (sizes[section] - 1) / columns {
                return starts[section] + min(position + columns, sizes[section] - 1)
            }
            guard section + 1 < sizes.count else { return index }
            return starts[section + 1] + min(column, sizes[section + 1] - 1)
        case .up:
            if position >= columns { return index - columns }
            guard section > 0 else { return index }
            let lastRow = (sizes[section - 1] - 1) / columns * columns
            return starts[section - 1] + min(lastRow + column, sizes[section - 1] - 1)
        }
    }
}
