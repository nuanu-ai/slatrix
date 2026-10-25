import Foundation
import Testing

@testable import Slatrix

extension Tag {
    @Tag static var budget: Tag
}

/// Budgets time the machine, so they run only when asked, alone and one at a time:
/// `SLATRIX_BUDGETS=1 scripts/test.sh --filter Budget --no-parallel`.
let budgetsEnabled = ProcessInfo.processInfo.environment["SLATRIX_BUDGETS"] != nil

/// The fastest of a few runs: scheduling noise only ever adds time. Each run times its own work, leaving setup out.
@MainActor
func fastest(of runs: Int = 3, _ run: () async throws -> Duration) async rethrows -> Duration {
    var best = Duration.seconds(3_600)
    for _ in 0..<runs { best = min(best, try await run()) }
    return best
}

extension Duration {
    var milliseconds: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
}

/// A busy conversation: one-liners and paragraphs, formatted bodies, runs by one sender, reactions, threads and a
/// new day every 60 messages. `tag` makes every body new, so no cache built by an earlier run helps.
func busyConversation(_ count: Int, roomID: String, tag: String) -> [ChatMessage] {
    let words = "the deploy went out after we fixed the flaky check and moved the release notes into the shared doc"
        .split(separator: " ")
    let senders = [
        "@ana:example.org", "@ben:example.org", "@chen:example.org", "@dara:example.org", "@eli:example.org",
    ]
    return (0..<count).map { index in
        let length = [4, 9, 16, 30, 60][index % 5]
        var body = (0..<length).map { words[($0 * 7 + index) % words.count] }.joined(separator: " ")
        if index % 9 == 0 { body += "\n\nSecond paragraph with the details, " + body }
        body = "\(tag) \(index) " + body
        let sender = senders[(index / 3) % senders.count]
        var message = ChatMessage(
            id: "$\(tag)-\(index)", roomID: roomID, senderID: sender, senderName: String(sender.dropFirst().prefix(4)),
            body: body, timestamp: Date(timeIntervalSince1970: 1_761_192_000 + Double(index) * 1_440))
        if index % 4 == 0 {
            message.formattedBody =
                "<p><strong>\(tag) \(index)</strong> \(body) <a href=\"https://example.org/\(index)\">link</a> "
                + "<code>make check</code></p>"
        }
        if index % 7 == 0 { message.reactions = [MessageReaction(key: "👍", count: 3, mine: index % 14 == 0)] }
        if index % 11 == 0 { message.replyCount = 2 }
        return message
    }
}
