import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

/// Any JSON value, so a case hands the app content exactly as the spec writes it and compares what the app writes.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

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
        var roomID: String
        var eventID: String
        var now: Int64
        var expected: JSONValue
        var testDescription: String { name }
        enum CodingKeys: String, CodingKey {
            case name, list, now, expected
            case roomID = "room_id"
            case eventID = "event_id"
        }
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

    // capability: message.save.sync
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
            roomID: spec.roomID, eventID: spec.eventID, at: Date(timeIntervalSince1970: Double(spec.now) / 1_000))
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

/// One account's Later on the server, as this device's SDK reads, hears and writes it.
final class LaterClient: Client, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [RawAccountDataListener] = []
    private var content: String?
    private var failing = false
    /// Every write tried, whether or not it reached the server.
    let attempts = Recorder<String>()
    /// The type every read, write and subscription named.
    let types = Recorder<String>()
    /// Holds a write's reply after it lands, until the test releases it.
    let replies = Gate()
    init(stored: String? = nil) {
        content = stored
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    /// What the account holds: the last write to land, or the last list a sync brought.
    var server: String? { lock.withLock { content } }
    var failsWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    override func accountData(eventType: String) async throws -> String? {
        types.append(eventType)
        return lock.withLock { content }
    }
    override func observeRawAccountDataEvent(eventType: String, listener: RawAccountDataListener) -> TaskHandle {
        types.append(eventType)
        lock.withLock { listeners.append(listener) }
        return FakeCancellableHandle(noHandle: .init())
    }
    override func setAccountData(eventType: String, content: String) async throws {
        types.append(eventType)
        // Decided before the attempt shows, so a test that sees a failed attempt knows it failed.
        let fails = failsWrites
        attempts.append(content)
        if fails { throw ClientError.Generic(msg: "fixture is offline", details: nil) }
        lock.withLock { self.content = content }
        await replies.wait()
    }
    /// A sync bringing what another device wrote.
    func sync(_ content: String) {
        let current = lock.withLock {
            self.content = content
            return listeners
        }
        for listener in current { listener.onChange(content: content) }
    }
}

/// The saved event IDs of written content, newest first.
private func savedIDs(_ content: String) -> [String] {
    guard case .object(let object) = try? JSONValue(json: content), case .array(let saved) = object["saved"] else {
        return []
    }
    return saved.compactMap {
        guard case .object(let entry) = $0, case .string(let id) = entry["event_id"] else { return nil }
        return id
    }
}

/// Later kept in step with the account's data, against an SDK fake.
@MainActor
struct SavedMessagesServiceTests {
    private let owner = "@owner:example.org"
    private let one = #"{"room_id":"!design:example.org","event_id":"$one","ts":1761955200000}"#
    private let three = #"{"room_id":"!general:example.org","event_id":"$three","ts":1761955400000}"#

    // capability: message.save.sync
    @Test("Saves and removals made on another device show in Later after their sync")
    func otherDevice() async {
        let client = LaterClient(stored: #"{"saved":[\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })

        client.sync(#"{"saved":[\#(three),\#(one)],"removed":[]}"#)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three", "$one"] })
        let removedLater = #"{"room_id":"!design:example.org","event_id":"$one","ts":1761955500000}"#
        client.sync(#"{"saved":[\#(three)],"removed":[\#(removedLater)]}"#)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three"] })
    }

    @Test("A device's first run puts the list it kept into the account, under the shared type")
    func firstRun() async throws {
        let client = LaterClient()
        let later = SavedMessagesService()
        let kept = SavedMessageReference(
            roomID: "!design:example.org", eventID: "$one", savedAt: Date(timeIntervalSince1970: 1_761_955_200))
        later.merge(SavedMessages(saved: [kept]), accountID: owner)
        later.attach(client, accountID: owner)

        #expect(await eventually { client.server != nil })
        #expect(try JSONValue(json: client.server ?? "") == JSONValue(json: #"{"saved":[\#(one)],"removed":[]}"#))
        #expect(Set(client.types.all) == [try SavedMessagesRuleTests.spec.get().eventType])
    }

    @Test("A save made offline stays in Later and reaches the account once the connection is back")
    func offline() async {
        let client = LaterClient(stored: #"{"saved":[\#(one)],"removed":[]}"#)
        let matrix = MatrixService()
        matrix.savedMessages.attach(client, accountID: owner)
        #expect(await eventually { matrix.savedMessages.list.saved.map(\.eventID) == ["$one"] })
        client.failsWrites = true
        matrix.savedMessages.toggle(roomID: "!general:example.org", eventID: "$two")
        #expect(await eventually { !client.attempts.all.isEmpty })
        #expect(matrix.savedMessages.list.saved.map(\.eventID) == ["$two", "$one"])

        client.failsWrites = false
        matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$one"] })
    }

    @Test("A save here survives another device writing the account's list without it")
    func concurrentWrite() async {
        let client = LaterClient(stored: #"{"saved":[\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
        later.toggle(roomID: "!general:example.org", eventID: "$two")
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$one"] })

        // Written by a device that hadn't seen $two yet, after this one wrote.
        client.sync(#"{"saved":[\#(three),\#(one)],"removed":[]}"#)
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$three", "$one"] })
    }

    @Test("A save here outlasts another device's list that lands while this one's write waits for its reply")
    func syncDuringWrite() async {
        let client = LaterClient(stored: #"{"saved":[\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
        client.replies.arm()
        later.toggle(roomID: "!general:example.org", eventID: "$two")
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$one"] })

        // Written by a device that hadn't seen $two yet, after this one's write landed.
        client.sync(#"{"saved":[\#(one)],"removed":[]}"#)
        await drainMainActor()
        client.replies.release()
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$one"] })
    }

    @Test("Signing out keeps the account's Later for its last local save, and the next account starts from its own")
    func accounts() async {
        let later = SavedMessagesService()
        later.attach(LaterClient(stored: #"{"saved":[\#(one)],"removed":[]}"#), accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
        later.attach(nil, accountID: nil)
        #expect(later.list.saved.map(\.eventID) == ["$one"])

        later.attach(LaterClient(stored: #"{"saved":[\#(three)],"removed":[]}"#), accountID: "@other:example.org")
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three"] })
    }

    @Test("The preview starts with an empty Later, never the last account's")
    func preview() async {
        let matrix = MatrixService()
        matrix.savedMessages.attach(LaterClient(stored: #"{"saved":[\#(one)],"removed":[]}"#), accountID: owner)
        #expect(await eventually { matrix.savedMessages.list.saved.map(\.eventID) == ["$one"] })
        matrix.savedMessages.attach(nil, accountID: nil)

        matrix.enterPreview()
        #expect(matrix.savedMessages.list.saved.isEmpty)
    }
}
