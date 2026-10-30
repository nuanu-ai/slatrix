import MatrixRustSDK
import Testing

@testable import Slatrix

@MainActor
struct ChannelPrivacyTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var joinRule: String?
        var `private`: Bool
        var testDescription: String { name }

        var rule: JoinRule? {
            switch joinRule {
            case nil: nil
            case "public": .public
            case "invite": .invite
            case "knock": .knock
            case "private": .private
            case "restricted": .restricted(rules: [])
            case "knock_restricted": .knockRestricted(rules: [])
            case let custom?: .custom(repr: custom)
            }
        }
    }

    struct Spec: Decodable { var cases: [Case] }

    // capability: home.private-channel-icon
    @Test(
        "A channel is private as its join rule says, in shared cases",
        arguments: try SharedSpec.decode("spec/channel-privacy.json", as: Spec.self).cases)
    func privacy(spec: Case) async {
        let refresher = RoomListRefresher()
        refresher.attach(FakeClient(rooms: [FakeRoom(roomInfo(id: "!room:example.org", joinRule: spec.rule))]))
        refresher.request()
        #expect(await eventually { refresher.rooms.count == 1 })
        #expect(refresher.rooms.first?.isPrivate == spec.private)
    }
}
