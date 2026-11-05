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

    struct Setting: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var list: JSONValue
        var roomID: String
        var eventID: String
        var saved: Bool
        var now: Int64
        var expected: JSONValue
        var testDescription: String { name }
        enum CodingKeys: String, CodingKey {
            case name, list, saved, now, expected
            case roomID = "room_id"
            case eventID = "event_id"
        }
    }

    struct Changing: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var list: JSONValue
        var roomID: String
        var eventID: String
        var state: LaterState
        var now: Int64
        var expected: JSONValue
        var testDescription: String { name }
        enum CodingKeys: String, CodingKey {
            case name, list, state, now, expected
            case roomID = "room_id"
            case eventID = "event_id"
        }
    }

    struct Reminding: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var list: JSONValue
        var roomID: String
        var eventID: String
        var remindAt: Int64?
        var now: Int64
        var expected: JSONValue
        var testDescription: String { name }
        enum CodingKeys: String, CodingKey {
            case name, list, now, expected
            case roomID = "room_id"
            case eventID = "event_id"
            case remindAt = "remind_at"
        }
    }

    struct Tabs: Decodable, Sendable, CustomTestStringConvertible {
        struct Expected: Decodable, Equatable, Sendable {
            var inProgress: [String]
            var archived: [String]
            var completed: [String]
            var overdue: [String]
            enum CodingKeys: String, CodingKey {
                case archived, completed, overdue
                case inProgress = "in_progress"
            }
        }
        var name: String
        var list: JSONValue
        var now: Int64
        var expected: Expected
        var testDescription: String { name }
    }

    struct Notifying: Decodable, Sendable, CustomTestStringConvertible {
        struct Reminder: Decodable, Equatable, Sendable {
            var roomID: String
            var eventID: String
            var remindAt: Int64
            enum CodingKeys: String, CodingKey {
                case roomID = "room_id"
                case eventID = "event_id"
                case remindAt = "remind_at"
            }
        }
        var name: String
        var list: JSONValue
        var now: Int64
        var expected: [Reminder]
        var testDescription: String { name }
    }

    struct Presets: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var now: Int64
        var timeZone: String
        var expected: [String: Int64]
        var testDescription: String { name }
        enum CodingKeys: String, CodingKey {
            case name, now, expected
            case timeZone = "time_zone"
        }
    }

    struct Spec: Decodable {
        var eventType: String
        var reading: [Reading]
        var merging: [Merging]
        var setting: [Setting]
        var changing: [Changing]
        var reminding: [Reminding]
        var tabs: [Tabs]
        var notifying: [Notifying]
        var presets: [Presets]
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
        #expect((merged.content(over: remote) != nil) == spec.writes)
    }

    @Test("Saving and removing change Later as in every shared case", arguments: try spec.get().setting)
    func setting(spec: Setting) throws {
        let changed = SavedMessages(json: spec.list.text).setting(
            roomID: spec.roomID, eventID: spec.eventID, saved: spec.saved,
            at: Date(timeIntervalSince1970: Double(spec.now) / 1_000))
        #expect(try JSONValue(json: changed.json) == spec.expected)
    }

    // capability: later.complete
    // capability: later.archive
    @Test(
        "Completing, archiving and bringing back change Later as in every shared case",
        arguments: try spec.get().changing)
    func changing(spec: Changing) throws {
        let changed = SavedMessages(json: spec.list.text).changing(
            roomID: spec.roomID, eventID: spec.eventID, to: spec.state, at: Self.date(spec.now))
        #expect(try JSONValue(json: changed.json) == spec.expected)
    }

    // capability: later.remind
    @Test("Reminders change Later as in every shared case", arguments: try spec.get().reminding)
    func reminding(spec: Reminding) throws {
        let changed = SavedMessages(json: spec.list.text).reminding(
            roomID: spec.roomID, eventID: spec.eventID, at: spec.remindAt.map(Self.date), now: Self.date(spec.now))
        #expect(try JSONValue(json: changed.json) == spec.expected)
    }

    // capability: later.complete
    // capability: later.archive
    // capability: later.remind
    @Test("Later's tabs list and order messages as in every shared case", arguments: try spec.get().tabs)
    func tabs(spec: Tabs) {
        let list = SavedMessages(json: spec.list.text)
        let now = Self.date(spec.now)
        let ids = { (state: LaterState) in list.tab(state).map(\.eventID) }
        let shown = Tabs.Expected(
            inProgress: ids(.inProgress), archived: ids(.archived), completed: ids(.completed),
            overdue: list.tab(.inProgress).filter { $0.isOverdue(at: now) }.map(\.eventID))
        #expect(shown == spec.expected)
    }

    // capability: later.remind
    @Test("A device notifies of reminders as in every shared case", arguments: try spec.get().notifying)
    func notifying(spec: Notifying) {
        let reminders = SavedMessages(json: spec.list.text).reminders(after: Self.date(spec.now)).map {
            Notifying.Reminder(
                roomID: $0.roomID, eventID: $0.eventID,
                remindAt: Int64(($0.remindAt?.timeIntervalSince1970 ?? 0) * 1_000))
        }
        #expect(reminders == spec.expected)
    }

    // capability: later.remind
    @Test("Remind me's choices land when every shared case says", arguments: try spec.get().presets)
    func presets(spec: Presets) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: spec.timeZone))
        let keys: [ReminderPreset: String] = [
            .in20Minutes: "in_20_minutes", .in1Hour: "in_1_hour", .in3Hours: "in_3_hours", .tomorrow: "tomorrow",
            .nextWeek: "next_week",
        ]
        let times = Dictionary(
            uniqueKeysWithValues: ReminderPreset.allCases.map {
                (keys[$0] ?? "", Int64($0.date(from: Self.date(spec.now), in: calendar).timeIntervalSince1970 * 1_000))
            })
        #expect(times == spec.expected)
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func references(_ count: Int) -> [SavedMessageReference] {
        (1...count).map {
            SavedMessageReference(
                roomID: "!design:example.org", eventID: "$\($0)", savedAt: Date(timeIntervalSince1970: Double($0)))
        }
    }

    @Test("Later keeps its newest ten thousand saved messages")
    func savedLimit() {
        let list = SavedMessages(saved: Self.references(10_001))
        #expect(list.saved.first?.eventID == "$10001")
        #expect(list.saved.last?.eventID == "$2")
    }

    @Test("Later remembers its newest thousand removals, however far ahead a device's clock runs")
    func removalLimit() {
        let ahead = SavedMessageReference(
            roomID: "!general:example.org", eventID: "$ahead", savedAt: Date(timeIntervalSince1970: 4_000_000_000))
        let list = SavedMessages(saved: [ahead], removed: Self.references(1_001))
        #expect(list.removed.first?.eventID == "$1001")
        #expect(list.removed.last?.eventID == "$2")
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
        let client = LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })

        client.sync(#"{"saved":[\#(three),\#(one)],"removed":[]}"#)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three", "$one"] })
        let removedLater = #"{"room_id":"!design:example.org","event_id":"$one","ts":1761955500000}"#
        client.sync(#"{"saved":[\#(three)],"removed":[\#(removedLater)]}"#)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three"] })
    }

    // capability: later.complete
    // capability: later.remind
    @Test("Completing one message and setting a reminder on another here reach the account for other devices")
    func changesSync() async {
        let client = LaterClient(server: #"{"saved":[\#(three),\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.count == 2 })
        let due = Date(timeIntervalSince1970: 1_900_000_000)
        later.set(roomID: "!design:example.org", eventID: "$one", state: .completed)
        later.remind(roomID: "!general:example.org", eventID: "$three", at: due)
        #expect(
            await eventually {
                let account = SavedMessages(json: client.server)
                return account.tab(.completed).map(\.eventID) == ["$one"]
                    && account.tab(.inProgress).map(\.remindAt) == [due]
            })
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
        let client = LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#)
        let matrix = MatrixService()
        matrix.savedMessages.attach(client, accountID: owner)
        #expect(await eventually { matrix.savedMessages.list.saved.map(\.eventID) == ["$one"] })
        client.failsWrites = true
        matrix.savedMessages.set(roomID: "!general:example.org", eventID: "$two", saved: true)
        #expect(await eventually { !client.attempts.all.isEmpty })
        #expect(matrix.savedMessages.list.saved.map(\.eventID) == ["$two", "$one"])
        client.land(#"{"saved":[\#(three),\#(one)],"removed":[]}"#)

        client.failsWrites = false
        matrix.applyConnection(
            MatrixConnectionFeedback(state: .running, isRetrying: false, canRetry: false, errorMessage: nil))
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$three", "$one"] })
    }

    @Test("Signing in again never writes the device's old list over what the account holds")
    func signInAgain() async {
        let removedLater = #"{"room_id":"!design:example.org","event_id":"$one","ts":1761955500000}"#
        let client = LaterClient(server: #"{"saved":[\#(three)],"removed":[\#(removedLater)]}"#)
        let later = SavedMessagesService()
        let kept = SavedMessageReference(
            roomID: "!design:example.org", eventID: "$one", savedAt: Date(timeIntervalSince1970: 1_761_955_200))
        later.merge(SavedMessages(saved: [kept]), accountID: owner)
        later.attach(client, accountID: owner)

        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three"] })
        #expect(client.server.map(savedIDs) == ["$three"])
    }

    @Test("A save after the account couldn't be read reads it again and reaches it")
    func failedRead() async {
        let client = LaterClient(server: #"{"saved":[\#(three)],"removed":[]}"#)
        client.failsReads = true
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { client.reads.all == [true] })

        client.failsReads = false
        later.set(roomID: "!general:example.org", eventID: "$two", saved: true)
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$three"] })
    }

    @Test("A save here survives another device writing the account's list without it")
    func concurrentWrite() async {
        let client = LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
        later.set(roomID: "!general:example.org", eventID: "$two", saved: true)
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$one"] })

        // Written by a device that hadn't seen $two yet, after this one wrote.
        client.sync(#"{"saved":[\#(three),\#(one)],"removed":[]}"#)
        #expect(await eventually { client.server.map(savedIDs) == ["$two", "$three", "$one"] })
    }

    @Test("A save here outlasts another device's list that lands while this one's write waits for its reply")
    func syncDuringWrite() async {
        let client = LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#)
        let later = SavedMessagesService()
        later.attach(client, accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
        client.replies.arm()
        later.set(roomID: "!general:example.org", eventID: "$two", saved: true)
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
        later.attach(LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#), accountID: owner)
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
        later.attach(nil, accountID: nil)
        #expect(later.list.saved.map(\.eventID) == ["$one"])

        later.attach(LaterClient(server: #"{"saved":[\#(three)],"removed":[]}"#), accountID: "@other:example.org")
        #expect(await eventually { later.list.saved.map(\.eventID) == ["$three"] })
    }

    @Test("A Later service that is let go while attached is freed, though its client lives on")
    func released() async {
        let client = LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#)
        weak var released: SavedMessagesService?
        do {
            let later = SavedMessagesService()
            later.attach(client, accountID: owner)
            #expect(await eventually { later.list.saved.map(\.eventID) == ["$one"] })
            released = later
        }
        #expect(await eventually { released == nil })
    }

    @Test("The preview starts with an empty Later, never the last account's")
    func preview() async {
        let matrix = MatrixService()
        matrix.savedMessages.attach(LaterClient(server: #"{"saved":[\#(one)],"removed":[]}"#), accountID: owner)
        #expect(await eventually { matrix.savedMessages.list.saved.map(\.eventID) == ["$one"] })
        matrix.savedMessages.attach(nil, accountID: nil)

        matrix.enterPreview()
        #expect(matrix.savedMessages.list.saved.isEmpty)
    }
}
