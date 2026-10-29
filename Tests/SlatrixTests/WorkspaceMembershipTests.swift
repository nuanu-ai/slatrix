import Testing

@testable import Slatrix

struct WorkspaceMembershipTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var direct: Bool
        var spaceIds: [String]
        var spaceId: String?
        var included: Bool
        var testDescription: String { name }
    }

    struct Spec: Decodable { var cases: [Case] }

    @Test(
        "Workspace scope matches shared cases",
        arguments: try SharedSpec.decode("spec/workspace-membership.json", as: Spec.self).cases)
    func scope(spec: Case) {
        #expect(
            WorkspaceMembership.includes(direct: spec.direct, spaceIDs: spec.spaceIds, spaceID: spec.spaceId)
                == spec.included)
    }
}
