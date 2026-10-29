import Foundation
import Testing

@testable import Slatrix

/// Slack's @ autocomplete, from the shared cases in `spec/mention-search.json`.
struct MentionSearchTests {
    struct Member: Decodable {
        var id: String
        var name: String
        var membership: String?
    }

    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var before: String
        var members: [Member]
        var recentSenders: [String]?
        var offersRoom: Bool
        var range: [Int]?
        var suggestions: [String]?
        var testDescription: String { name }
    }

    struct Spec: Decodable { var cases: [Case] }

    // capability: composer.mentions
    @Test("Shared case", arguments: try SharedSpec.decode("spec/mention-search.json", as: Spec.self).cases)
    func shared(spec: Case) {
        let found = MentionSearch.suggestions(
            before: spec.before,
            members: spec.members.map { ChatUser(id: $0.id, name: $0.name, membership: $0.membership ?? "join") },
            recentSenders: spec.recentSenders ?? [], offersRoom: spec.offersRoom)
        let ids = found?.candidates.map {
            switch $0 {
            case .member(let member): member.id
            case .room: "@room"
            }
        }
        #expect(ids == spec.suggestions)
        if let range = spec.range {
            #expect(found?.range == NSRange(location: range[0], length: range[1]))
        }
    }

    @Test("Everyone a query names is listed, however many")
    func everyone() {
        let members = (0..<40).map { ChatUser(id: "@p\($0):example.org", name: "Person \($0)", membership: "join") }
        let found = MentionSearch.suggestions(before: "@person", members: members, recentSenders: [], offersRoom: true)
        #expect(found?.candidates.count == members.count)
    }
}
