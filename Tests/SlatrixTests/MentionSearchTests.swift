import Foundation
import Testing

@testable import Slatrix

private func person(_ localpart: String, _ name: String, membership: String = "join") -> ChatUser {
    ChatUser(id: "@\(localpart):example.org", name: name, membership: membership)
}

private let agent = person("agent", "AI Agent")
private let aisha = person("aisha", "Aisha Khan")
private let bob = person("bob", "Bob Stone")
private let team = [aisha, agent, bob]

/// Slack's @ autocomplete: which query the caret is in, and who it names, best first.
struct MentionSearchTests {
    private func names(_ text: String, members: [ChatUser] = team, recent: [String] = []) -> [String]? {
        MentionSearch.suggestions(before: text, members: members, recentSenders: recent)?.candidates.map {
            switch $0 {
            case .member(let member): member.name
            case .room: "@room"
            }
        }
    }

    @Test("A query keeps matching across a space while the words still name someone")
    func spaces() {
        #expect(names("Hi @AI A") == ["AI Agent"])
        #expect(names("Hi @Agent") == ["AI Agent"])
    }

    @Test(
        "Typing on after a finished name, an email address or a line break opens nothing",
        arguments: ["@AI Agent thanks", "mail dima@example.org", "@bob\nnext", "@ ", "no at here"])
    func closed(text: String) {
        #expect(names(text) == nil)
    }

    @Test("The query and its @ are what a chosen mention replaces")
    func range() {
        let suggestions = MentionSearch.suggestions(before: "Hi @AI A", members: team, recentSenders: [])
        #expect(suggestions?.range == NSRange(location: 3, length: 5))
    }

    @Test("A name that starts with the query comes before a later word, then the user ID, then anywhere in the name")
    func ranking() {
        let members = [
            person("zed", "Mia Zed"), person("lou", "Lou Mial"), person("miagi", "Kay Lee"),
            person("ann", "Mia Ann"), person("tom", "Tom Amiato"),
        ]
        #expect(names("@mia", members: members) == ["Mia Ann", "Mia Zed", "Lou Mial", "Kay Lee", "Tom Amiato"])
    }

    @Test("Within a group, people who spoke here lately come first, the latest first")
    func recentSpeakers() {
        let members = [person("ann", "Mia Ann"), person("bo", "Mia Bo"), person("cy", "Mia Cy")]
        let recent = ["@cy:example.org", "@bo:example.org", "@cy:example.org"]
        #expect(names("@mia", members: members, recent: recent) == ["Mia Cy", "Mia Bo", "Mia Ann"])
    }

    @Test("Case and accents don't matter")
    func folding() {
        #expect(names("@jose", members: [person("jose", "JOSÉ Núñez")]) == ["JOSÉ Núñez"])
        #expect(names("@nun", members: [person("jose", "JOSÉ Núñez")]) == ["JOSÉ Núñez"])
    }

    @Test("Joined members come before invited ones; people who left or were banned never show")
    func membership() {
        let members = [
            person("al", "Al Invited", membership: "invite"), person("am", "Am Joined"),
            person("an", "An Left", membership: "leave"), person("ao", "Ao Banned", membership: "ban"),
        ]
        #expect(names("@a", members: members) == ["Am Joined", "Al Invited"])
    }

    @Test("A long list stops at its limit")
    func limit() {
        let members = (0..<40).map { person("p\($0)", "Person \($0)") }
        #expect(names("@person", members: members)?.count == MentionSearch.limit)
    }

    @Test("@room comes last for what Slack users type: room, channel or here", arguments: ["@ro", "@channel", "@her"])
    func room(text: String) {
        #expect(names(text)?.last == "@room")
    }

    @Test("@room stays out when the query names only people")
    func noRoom() {
        #expect(names("@bob")?.contains("@room") == false)
    }
}
