import Foundation
import Testing

@testable import Slatrix

struct EmojiTests {
    private func top(_ query: String) -> String? { EmojiCatalog.search(query).first?.value }

    @Test("Search finds an emoji by any of Slack's shortcodes, with or without colons")
    func shortcodeSearch() {
        #expect(top(":+1:") == "👍")
        #expect(top("thumbsup") == "👍")
        #expect(top(":heart:") == "❤️")
        #expect(top("tada") == "🎉")
    }

    @Test("An exact shortcode outranks one it starts, which outranks a later word")
    func ranking() throws {
        let results = EmojiCatalog.search("heart").map(\.value)
        let starts = try #require(results.firstIndex(of: "😍"))  // :heart_eyes:
        let laterWord = try #require(results.firstIndex(of: "💔"))  // :broken_heart:
        #expect(results.first == "❤️")
        #expect(starts < laterWord)
        #expect(top("smile") == "😄")
        #expect(EmojiCatalog.search("thumbs up").first?.value == "👍")
        #expect(EmojiCatalog.search("zzzqqq").isEmpty)
        #expect(EmojiCatalog.search("  ").isEmpty)
    }

    @Test("A reaction's shortcode is Slack's, with its skin tone, and its key when it is not an emoji")
    func shortcodeLookup() {
        #expect(EmojiCatalog.shortcode(for: "👍") == ":+1:")
        #expect(EmojiCatalog.shortcode(for: "👍🏽") == ":+1::skin-tone-4:")
        // Another client may send a heart without its emoji presentation selector.
        #expect(EmojiCatalog.shortcode(for: "\u{2764}") == ":heart:")
        #expect(EmojiCatalog.shortcode(for: "lgtm") == "lgtm")
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

    @Test("A used emoji moves to the front of the recent list without repeating")
    func recentOrder() {
        #expect(EmojiRecents.adding("🎉", to: ["👍", "🎉", "🔥"]) == ["🎉", "👍", "🔥"])
        #expect(EmojiRecents.adding("🚀", to: ["👍"]) == ["🚀", "👍"])
    }

    @Test("The toolbar offers the three most recent emoji, filled from Slack's defaults")
    func quickReactions() {
        #expect(EmojiRecents.quick(["🎉", "👍", "🔥", "🚀"]) == ["🎉", "👍", "🔥"])
        let filled = EmojiRecents.quick(["✅"])
        #expect(filled.first == "✅")
        #expect(filled.count == 3 && Set(filled).count == 3)
        #expect(EmojiRecents.quick([]).count == 3)
    }

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
