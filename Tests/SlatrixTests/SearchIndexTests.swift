import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class Hits: SearchServiceResultsListener, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SearchServiceResult] = []
    private var updatesCount = 0
    var eventIDs: Set<String> {
        lock.withLock { Set(MatrixMapping.searchMessages(results, roomID: nil).map(\.id)) }
    }
    var revision: Int { lock.withLock { updatesCount } }
    func onUpdate(updates: [SearchServiceResultsUpdate]) {
        lock.withLock {
            results.apply(updates.map(\.change))
            updatesCount += 1
        }
    }
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

    // capability: search.messages
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
        // The cache indexes what paging brought in on its own time, and a query's results never grow after it runs,
        // so ask again until every message can be found.
        let everything: Set<String> = ["$alice-new", "$bob-new", "$odd-new", "$alice-old"]
        let deadline = ContinuousClock.now + .seconds(30)
        repeat {
            try await service.setQuery(query: "launch")
        } while await !eventually(timeout: .milliseconds(200), { hits.eventIDs == everything })
            && ContinuousClock.now < deadline
        try #require(hits.eventIDs == everything)
        try await service.setQuery(query: query)
        // A page of hits lands at once, after the query returns; every case finds fewer than all.
        _ = await eventually { !hits.eventIDs.isEmpty && hits.eventIDs != everything }
        return hits.eventIDs
    }

    // capability: search.messages
    @Test(
        "Prefix and multi-word queries match Russian and English word forms in a real index without crashing on punctuation"
    )
    func prefixAndMorphology() async throws {
        let now = Date()
        func message(_ id: String, _ body: String) -> [String: Any] {
            [
                "type": "m.room.message", "event_id": id, "sender": Self.alice,
                "origin_server_ts": Int(now.timeIntervalSince1970 * 1_000),
                "content": ["msgtype": "m.text", "body": body],
            ]
        }
        let server = try await FakeHomeserver(
            room: "!room:localhost",
            messages: [
                message("$ru-genitive", "жду инструменты для рассылок, под коммерцию и сканер"),
                message("$ru-nominative", "Рассылка ушла всем клиентам"),
                message("$ru-other", "нужны инструменты для сканера"),
                message("$en-deploy", "Production deployment succeeded on staging"),
                message("$punct", "Fixed C++ parser in foo:bar (test)"),
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
        _ = try await room.timeline().paginateBackwards(numEvents: 20)

        let hits = Hits()
        let service = client.searchService()
        let handle = await service.subscribeToResults(listener: hits)
        defer { handle.cancel() }

        // Wait for the event cache to index all 5 messages.
        let deadline = ContinuousClock.now + .seconds(30)
        repeat {
            try await service.setQuery(query: "сканер OR сканера OR deployment OR parser OR клиентам")
        } while await !eventually(
            timeout: .milliseconds(200),
            { hits.eventIDs == ["$ru-genitive", "$ru-nominative", "$ru-other", "$en-deploy", "$punct"] })
            && ContinuousClock.now < deadline
        try #require(hits.eventIDs.count == 5)

        func run(_ text: String, mode: MessageSearchQuery.Mode = .query, expectNonEmpty: Bool = true) async throws
            -> Set<String>
        {
            let sdk = try #require(MessageSearchQuery(text, mode: mode).sdkQuery())
            let queryHits = Hits()
            let queryService = client.searchService()
            let queryHandle = await queryService.subscribeToResults(listener: queryHits)
            defer { queryHandle.cancel() }
            try await queryService.setQuery(query: sdk)
            _ = await eventually(timeout: .seconds(5)) {
                expectNonEmpty ? !queryHits.eventIDs.isEmpty : queryHits.revision > 0
            }
            return queryHits.eventIDs
        }

        // Russian prefix matches both "рассылок" and "Рассылка".
        let ruPrefix = try await run("рассыл")
        #expect(ruPrefix == ["$ru-genitive", "$ru-nominative"])
        // Multi-word search requires every term (AND), so "$ru-other" (which only has "инструменты") is excluded.
        let ruAnd = try await run("инструменты рассыл")
        #expect(ruAnd == ["$ru-genitive"])
        // English prefix matches "deployment".
        let enPrefix = try await run("deploy")
        #expect(enPrefix == ["$en-deploy"])
        // Punctuation and colons/parens never crash Tantivy's parser.
        let punct = try await run("foo:bar (test)")
        #expect(punct == ["$punct"])
        // Uppercase Tantivy operators stay safe lowercase word terms and never crash the parser.
        let operators = try await run("AND OR NOT TO", expectNonEmpty: false)
        #expect(operators.isEmpty)
        // Exact phrase mode still requires exact words in order.
        let phrase = try await run("рассыл", mode: .phrase, expectNonEmpty: false)
        #expect(phrase.isEmpty)
    }
}
