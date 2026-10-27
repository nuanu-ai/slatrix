import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class Hits: SearchServiceResultsListener, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SearchServiceResult] = []
    var eventIDs: Set<String> {
        lock.withLock { Set(MatrixMapping.searchMessages(results, roomID: nil).map(\.id)) }
    }
    func onUpdate(updates: [SearchServiceResultsUpdate]) { lock.withLock { results.apply(updates.map(\.change)) } }
}

/// The From and Date filters as the SDK's own search index reads them: a real client pages through synthetic history
/// from a `FakeHomeserver`, which indexes it, then each query runs against that index.
@MainActor
struct SearchIndexTests {
    static let alice = "@alice:localhost"
    static let bob = "@bob:localhost"
    /// Legal in a historical user ID, and each one means something to the query grammar.
    static let odd = "@o\"brien\\x+y/z=:localhost"

    enum Case: String, CaseIterable {
        case sender, date, senderAndDate, oddSender, oddSenderAlone
    }

    @Test("Search filters narrow hits in a real index", arguments: Case.allCases)
    func filters(_ kind: Case) async throws {
        let query =
            switch kind {
            case .sender: MessageSearchQuery("launch", senderID: Self.alice)
            case .date: MessageSearchQuery("launch", date: .week)
            case .senderAndDate: MessageSearchQuery("launch", senderID: Self.alice, date: .week)
            case .oddSender: MessageSearchQuery("launch", senderID: Self.odd)
            case .oddSenderAlone: MessageSearchQuery("", senderID: Self.odd)
            }
        let expected: Set<String> =
            switch kind {
            case .sender: ["$alice-new", "$alice-old"]
            case .date: ["$alice-new", "$bob-new", "$odd-new"]
            case .senderAndDate: ["$alice-new"]
            case .oddSender, .oddSenderAlone: ["$odd-new"]
            }
        #expect(try await hits(try #require(query.sdkQuery())) == expected)
    }

    /// The event IDs a query finds among a few messages that all say "launch": Alice's from today and from 40 days
    /// ago, Bob's and the odd sender's from today.
    private func hits(_ query: String) async throws -> Set<String> {
        let now = Date()
        func message(_ id: String, _ sender: String, daysAgo: Double) -> [String: Any] {
            [
                "type": "m.room.message", "event_id": id, "sender": sender,
                "origin_server_ts": Int((now.timeIntervalSince1970 - daysAgo * 86_400) * 1_000),
                "content": ["msgtype": "m.text", "body": "launch notes from \(id.dropFirst())"],
            ]
        }
        let server = try await FakeHomeserver(
            room: "!room:localhost",
            messages: [
                message("$alice-new", Self.alice, daysAgo: 0), message("$bob-new", Self.bob, daysAgo: 0),
                message("$odd-new", Self.odd, daysAgo: 0), message("$alice-old", Self.alice, daysAgo: 40),
            ])
        let scratch = try TemporaryDirectory()
        let client = try await ClientBuilder().homeserverUrl(url: server.url).sessionPaths(
            dataPath: scratch.path("data").path, cachePath: scratch.path("cache").path
        ).withSearchIndexStore(path: scratch.path("index").path, password: nil).build()
        try await client.restoreSession(
            session: Session(
                accessToken: "token", refreshToken: nil, userId: "@me:localhost", deviceId: "DEVICE",
                homeserverUrl: server.url, oauthData: nil, slidingSyncVersion: .native))
        let room = try await client.joinRoomById(roomId: server.room)
        // Paging back puts the history in the event cache, which indexes it.
        _ = try await room.timeline().paginateBackwards(numEvents: 20)

        let hits = Hits()
        let service = client.searchService()
        let handle = await service.subscribeToResults(listener: hits)
        defer { handle.cancel() }
        try await service.setQuery(query: query)
        // A page of hits lands at once, after the query returns.
        _ = await eventually { !hits.eventIDs.isEmpty }
        return hits.eventIDs
    }
}
