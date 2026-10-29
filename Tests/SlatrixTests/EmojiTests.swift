import Foundation
import Testing

@testable import Slatrix

struct EmojiTests {
    struct Search: Decodable, CustomTestStringConvertible {
        var name: String
        var query: String
        var first: String?
        var order: [String]?
        var testDescription: String { name }
    }
    struct Shortcode: Decodable, CustomTestStringConvertible {
        var name: String
        var value: String
        var shortcode: String
        var testDescription: String { name }
    }
    struct Quick: Decodable, CustomTestStringConvertible {
        var name: String
        var recent: [String]
        var count: Int
        var quick: [String]
        var testDescription: String { name }
    }
    struct Adding: Decodable, CustomTestStringConvertible {
        var name: String
        var emoji: String
        var recent: [String]
        var after: [String]
        var testDescription: String { name }
    }
    struct Spec: Decodable {
        var search: [Search]
        var shortcode: [Shortcode]
        var quick: [Quick]
        var adding: [Adding]
    }
    private static let spec = Result { try SharedSpec.decode("spec/emoji.json", as: Spec.self) }

    // capability: message.react.picker
    @Test("Shared search case", arguments: try spec.get().search)
    func search(spec: Search) throws {
        let results = EmojiCatalog.search(spec.query).map(\.value)
        #expect(results.first == spec.first)
        let positions = try (spec.order ?? []).map { try #require(results.firstIndex(of: $0)) }
        #expect(positions == positions.sorted())
    }

    @Test("Shared shortcode case", arguments: try spec.get().shortcode)
    func shortcode(spec: Shortcode) {
        #expect(EmojiCatalog.shortcode(for: spec.value) == spec.shortcode)
    }

    // capability: message.react.quick
    @Test("Shared quick reactions case", arguments: try spec.get().quick)
    func quick(spec: Quick) {
        #expect(EmojiRecents.quick(spec.recent, count: spec.count) == spec.quick)
    }

    @Test("Shared recent emoji case", arguments: try spec.get().adding)
    func adding(spec: Adding) {
        #expect(EmojiRecents.adding(spec.emoji, to: spec.recent) == spec.after)
    }

    @Test("A chosen skin tone applies to emoji that take one and leaves the rest alone")
    func skinTone() throws {
        let thumbs = try #require(EmojiCatalog.search(":+1:").first)
        let grinning = try #require(EmojiCatalog.search(":grinning:").first)
        let holding = try #require(EmojiCatalog.search(":people_holding_hands:").first)
        #expect(thumbs.value(tone: .mediumDark) == "👍🏾")
        #expect(thumbs.value(tone: .none) == "👍")
        #expect(grinning.value(tone: .dark) == "😀")
        #expect(holding.value(tone: .light) == "🧑🏻‍🤝‍🧑🏻")
    }

    @Test("Every category has emoji, and every emoji has a shortcode and a name")
    func catalogShape() {
        let all = EmojiCatalog.all
        #expect(Set(all.map(\.category)) == Set(Emoji.Category.allCases))
        #expect(all.allSatisfy { !$0.shortcodes.isEmpty && !$0.name.isEmpty && !$0.value.isEmpty })
    }

    @Test("Arrows move through the grid by cell and by row, across sections and onto shorter rows")
    func gridMoves() {
        // Two sections in three columns: [0 1 2] [3] then [4 5 6] [7 8 9] [10 11 12] [13].
        func move(_ index: Int, _ direction: EmojiGrid.Direction) -> Int {
            EmojiGrid.move(index, direction, sizes: [4, 10], columns: 3)
        }
        #expect(move(1, .down) == 3)
        #expect(move(3, .down) == 4)
        #expect(move(8, .up) == 5)
        #expect(move(5, .up) == 3)
        #expect(move(3, .right) == 4)
        #expect(move(4, .left) == 3)
        #expect(move(13, .down) == 13)
        #expect(move(13, .right) == 13)
        #expect(move(1, .up) == 1)
    }

    // capability: message.reactions.show
    @Test("A reaction's tooltip names who reacted, you first, and counts the rest")
    func reactionTooltip() {
        let names = ["@a:x": "Alice", "@b:x": "Bob", "@c:x": "Carol", "@d:x": "Dan", "@e:x": "Erin"]
        func tooltip(_ senders: [String], key: String = "👍") -> String {
            MessageReaction(key: key, count: senders.count, mine: senders.contains("@me:x"), senders: senders)
                .tooltip(me: "@me:x") { names[$0] }
        }
        #expect(tooltip(["@a:x"]) == "Alice reacted with :+1:")
        #expect(tooltip(["@a:x", "@me:x"]) == "You and Alice reacted with :+1:")
        #expect(tooltip(["@a:x", "@b:x", "@c:x"], key: "🎉") == "Alice, Bob and Carol reacted with :tada:")
        #expect(tooltip(["@a:x", "@b:x", "@c:x", "@d:x", "@e:x"]) == "Alice, Bob and 3 others reacted with :+1:")
        // Someone the room hasn't loaded yet goes by their user name.
        #expect(tooltip(["@zoe:example.org"]) == "zoe reacted with :+1:")
    }

    // capability: message.thread-summary
    @Test("The replies bar says how long ago the last reply came")
    func lastReply() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en_US")
        func text(_ seconds: TimeInterval) -> String {
            ThreadReply.lastReplyText(now.addingTimeInterval(-seconds), now: now, locale: locale)
        }
        #expect(text(20) == "Last reply just now")
        #expect(text(5 * 60) == "Last reply 5 minutes ago")
        #expect(text(2 * 3_600 + 60) == "Last reply 2 hours ago")
        #expect(text(3 * 86_400) == "Last reply 3 days ago")
        // A clock a little behind the server's never reads as a reply from the future.
        #expect(text(-30) == "Last reply just now")
    }
}
