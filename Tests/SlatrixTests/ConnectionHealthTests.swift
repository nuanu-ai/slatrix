import Testing

@testable import Slatrix

struct ConnectionHealthTests {
    struct Case: Decodable {
        let name: String
        let network: Bool?
        let foreground, running, responded, interrupted, previouslyConnected: Bool
        let state: ConnectionHealth
        let label: String
    }
    struct Spec: Decodable { let cases: [Case] }

    @Test func sharedConnectionStates() throws {
        for row in try SharedSpec.decode("spec/connection-state.json", as: Spec.self).cases {
            let state = ConnectionHealth.resolve(
                network: row.network, foreground: row.foreground,
                running: row.running, responded: row.responded, interrupted: row.interrupted,
                previouslyConnected: row.previouslyConnected)
            #expect(state == row.state, "\(row.name)")
            #expect(state.label == row.label, "\(row.name)")
        }
    }
}
