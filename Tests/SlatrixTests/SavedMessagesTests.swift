import Foundation
import Testing

@testable import Slatrix

/// Any JSON value, so a case hands the app content exactly as the spec writes it and compares what the app writes.
enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int64), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? value.decode(Int64.self) {
            self = .int(int)
        } else if let double = try? value.decode(Double.self) {
            self = .double(double)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: JSONValue].self))
        }
    }

    init(json: String) throws { self = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .int(let int): try value.encode(int)
        case .double(let double): try value.encode(double)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    var text: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
}

/// Later as one list per account, from the shared cases in `spec/saved-messages.json`.
struct SavedMessagesRuleTests {
    struct Reading: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var content: JSONValue
        var expected: JSONValue
        var testDescription: String { name }
    }

    struct Merging: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var local: JSONValue
        var remote: JSONValue
        var expected: JSONValue
        var writes: Bool
        var testDescription: String { name }
    }

    struct Toggling: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var list: JSONValue
        var room_id: String
        var event_id: String
        var now: Int64
        var expected: JSONValue
        var testDescription: String { name }
    }

    struct Spec: Decodable {
        var eventType: String
        var reading: [Reading]
        var merging: [Merging]
        var toggling: [Toggling]
    }

    static let spec = Result { try SharedSpec.decode("spec/saved-messages.json", as: Spec.self) }

    @Test("Later reads account data as in every shared case", arguments: try spec.get().reading)
    func reading(spec: Reading) throws {
        #expect(try JSONValue(json: SavedMessages(json: spec.content.text).json) == spec.expected)
    }

    // capability: message.save
    @Test("A device's Later merges with the account's as in every shared case", arguments: try spec.get().merging)
    func merging(spec: Merging) throws {
        let remote = SavedMessages(json: spec.remote == .null ? nil : spec.remote.text)
        let merged = SavedMessages(json: spec.local.text).merged(with: remote)
        #expect(try JSONValue(json: merged.json) == spec.expected)
        #expect((merged != remote) == spec.writes)
    }

    @Test("Saving and removing change Later as in every shared case", arguments: try spec.get().toggling)
    func toggling(spec: Toggling) throws {
        let toggled = SavedMessages(json: spec.list.text).toggled(
            roomID: spec.room_id, eventID: spec.event_id, at: Date(timeIntervalSince1970: Double(spec.now) / 1_000))
        #expect(try JSONValue(json: toggled.json) == spec.expected)
    }

    @Test("Each list keeps its newest ten thousand")
    func limit() throws {
        let saved = (0...10_000).map {
            SavedMessageReference(
                roomID: "!design:example.org", eventID: "$\($0)", savedAt: Date(timeIntervalSince1970: Double($0)))
        }
        let list = SavedMessages(saved: saved, removed: [])
        #expect(list.saved.first?.eventID == "$10000")
        #expect(list.saved.last?.eventID == "$1")
    }
}
