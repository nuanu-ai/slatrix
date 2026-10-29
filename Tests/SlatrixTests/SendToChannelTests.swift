import Foundation
import Testing

@testable import Slatrix

/// Any JSON value, compared by content, so an event's keys can come in any order.
indirect enum JSON: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let array = try? value.decode([JSON].self) {
            self = .array(array)
        } else {
            self = .object(try value.decode([String: JSON].self))
        }
    }
}

struct SendToChannelTests {
    struct Send: Decodable, CustomTestStringConvertible {
        var name: String
        var draft: String
        var replyTo: String
        var content: JSON
        var testDescription: String { name }
    }

    struct Spec: Decodable { var send: [Send] }

    // capability: thread.send-to-channel
    @Test(
        "The channel's copy of a thread reply, from spec/send-to-channel.json",
        arguments: try SharedSpec.decode("spec/send-to-channel.json", as: Spec.self).send)
    func copy(spec: Send) throws {
        let content = try ChannelCopy.content(ComposerFormat.message(draft: spec.draft), replyTo: spec.replyTo)
        #expect(try JSONDecoder().decode(JSON.self, from: Data(content.utf8)) == spec.content)
    }
}
