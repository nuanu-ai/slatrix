import Testing

@testable import Slatrix

struct MatrixIDTests {
    @Test(
        "Untrusted IDs need their sigil, a body, a bounded length and no control characters",
        arguments: [
            ("$event", "$", true), ("!room:example.org", "!", true), ("@alice:example.org", "@", true),
            ("anything", "", true), ("$", "$", false), ("", "", false), ("!room", "$", false),
            ("$event\n", "$", false), ("$" + String(repeating: "a", count: 2_047), "$", true),
            ("$" + String(repeating: "a", count: 2_048), "$", false),
        ])
    func validation(value: String, sigil: String, valid: Bool) {
        #expect(MatrixID.isValid(value, sigil: sigil) == valid)
    }

    @Test("Inviting requires a complete user ID", arguments: ["alice", "@alice", "@ali\u{0}ce:example.org"])
    func rejectsIncompleteUserIDs(input: String) {
        #expect(throws: MatrixServiceError.self) { try PeopleMapping.validatedID(input) }
    }
}
