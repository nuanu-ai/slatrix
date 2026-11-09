import Testing

@testable import Slatrix

struct PresencePolicyTests {
    struct Case: Decodable, CustomTestStringConvertible {
        let name: String
        let own, theirs: String?
        let dot: Presence?
        var testDescription: String { name }
    }
    struct Spec: Decodable { let cases: [Case] }

    @Test("Shared case", arguments: try SharedSpec.decode("spec/presence.json", as: Spec.self).cases)
    func sharedCase(_ row: Case) {
        #expect(PresencePolicy.dot(own: row.own, theirs: row.theirs) == row.dot)
    }
}

@MainActor
struct PresenceServiceTests {
    private func watch(_ states: [String: String]) -> PresenceService {
        let service = PresenceService()
        service.start(me: "@me", fetch: { states[$0] }, people: { ["@anna", "@igor", "@zoe"] })
        return service
    }

    // capability: people.presence
    @Test("The people you message get a dot from what the server says about them")
    func dots() async {
        let service = watch(["@me": "online", "@anna": "online", "@igor": "offline"])
        #expect(await eventually { service.dots == ["@anna": .active, "@igor": .away] })
        service.stop()
    }

    @Test("A server that reports you offline while you're connected doesn't share presence, so nobody gets a dot")
    func notShared() async {
        let service = watch(["@me": "offline", "@anna": "online"])
        #expect(await eventually { service.checked })
        #expect(service.dots.isEmpty)
        service.stop()
    }
}
