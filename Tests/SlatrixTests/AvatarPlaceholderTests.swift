import Testing

@testable import Slatrix

/// Initials and color for a name without a photo, from the shared cases in `spec/avatar.json`.
@MainActor
struct AvatarPlaceholderTests {
    struct Case: Decodable, CustomTestStringConvertible {
        var value: String
        var initials: String
        var color: Int
        var testDescription: String { "\"\(value)\"" }
    }

    struct Spec: Decodable { var cases: [Case] }
    struct Tokens: Decodable { var avatarColors: [String] }

    @Test("Shared case", arguments: try SharedSpec.decode("spec/avatar.json", as: Spec.self).cases)
    func placeholder(spec: Case) throws {
        let colors = try SharedSpec.decode("design/tokens.json", as: Tokens.self).avatarColors
        #expect(initials(spec.value) == spec.initials)
        #expect(
            DesignTokenTests.matches(
                avatarColor(spec.value), try #require(colors.indices.contains(spec.color) ? colors[spec.color] : nil)))
    }
}
