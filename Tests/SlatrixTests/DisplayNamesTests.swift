import Testing

@testable import Slatrix

/// Runs the shared cases in `spec/display-names.json`.
struct DisplayNamesTests {
    struct Name: Decodable, CustomTestStringConvertible {
        var `case`: String
        var userId: String
        var memberName, globalName: String?
        var ambiguous: Bool
        var name, mention: String
        var testDescription: String { self.case }
    }

    struct Text: Decodable, CustomTestStringConvertible {
        var `case`: String
        var text: String
        var members: [String: String]
        var result: String
        var testDescription: String { self.case }
    }

    struct Pill: Decodable, CustomTestStringConvertible {
        var `case`: String
        var body: String
        var html: String?
        var members: [String: String]
        var result: String
        var testDescription: String { self.case }
    }

    struct Spec: Decodable {
        var cases: [Name]
        var text: [Text]
        var pills: [Pill]
    }

    private static let spec = Result { try SharedSpec.decode("spec/display-names.json", as: Spec.self) }

    private static func shown(_ body: String, html: String?, members: [String: String]) -> String {
        let rendered = MessageBodyRenderer.shared.render(body: body, formattedBody: html)
        return MessageBodyRenderer.named(rendered.runs) { members[$0] }.map(\.text).joined()
    }

    // capability: people.names
    @Test("A person's name", arguments: try spec.get().cases)
    func name(spec: Name) {
        let name = DisplayNames.name(
            spec.userId, member: spec.memberName, global: spec.globalName, ambiguous: spec.ambiguous)
        #expect(name == spec.name)
        let mention = Self.shown(spec.userId, html: nil, members: [spec.userId: name])
        #expect(mention == spec.mention)
    }

    @Test("IDs in plain text read as mentions", arguments: try spec.get().text)
    func text(spec: Text) {
        #expect(Self.shown(spec.text, html: nil, members: spec.members) == spec.result)
    }

    @Test("Mentions in a message", arguments: try spec.get().pills)
    func pills(spec: Pill) {
        #expect(Self.shown(spec.body, html: spec.html, members: spec.members) == spec.result)
    }
}
