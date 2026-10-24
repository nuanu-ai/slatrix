import Foundation
import Testing

@testable import Slatrix

private struct FetchFailure: Error, Equatable {}

@MainActor
struct ThreadRootResolverTests {
    let room = "!room:example.org"
    let root = ChatMessage(
        id: "$original", roomID: "!room:example.org", senderID: "@other:example.org", senderName: "Other",
        body: "Root", timestamp: .distantPast)

    private func resolve(
        candidates: [ChatMessage] = [], validate: @MainActor () throws -> Void = {},
        load: @MainActor (String, String) async throws -> ChatMessage
    ) async throws -> ChatMessage {
        try await ThreadRootResolver.resolve(
            roomID: room, rootID: root.id, candidates: candidates, load: load, validate: validate)
    }

    @Test("A cached root from the same room is used without fetching")
    func cachedRoot() async throws {
        var fetched = false
        let resolved = try await resolve(candidates: [root]) { _, _ in
            fetched = true
            return root
        }
        #expect(resolved == root && !fetched)
    }

    @Test("A missing root is fetched by its exact room and event ID")
    func fetchesMissingRoot() async throws {
        var request: [String] = []
        let resolved = try await resolve { room, id in
            request = [room, id]
            return root
        }
        #expect(resolved == root && request == [room, root.id])
    }

    @Test("A cached event with the root's ID from another room is never used")
    func foreignCachedEvent() async throws {
        var foreign = root
        foreign.roomID = "!other:example.org"
        let resolved = try await resolve(candidates: [foreign]) { _, _ in root }
        #expect(resolved.roomID == room)
    }

    enum Invalid: CaseIterable { case wrongRoom, wrongID, nestedReply, unconfirmed }

    @Test(
        "A loaded event from the wrong room, with the wrong ID, inside another thread, or unconfirmed cannot be the root",
        arguments: Invalid.allCases)
    func rejectsInvalidLoadedRoot(kind: Invalid) async {
        var invalid = root
        switch kind {
        case .wrongRoom: invalid.roomID = "!wrong:example.org"
        case .wrongID: invalid.id = "$wrong"
        case .nestedReply: invalid.threadRootID = "$another-root"
        case .unconfirmed: invalid.sendState = "sending"
        }
        await #expect(throws: ThreadRootResolver.Failure.self) { _ = try await resolve { _, _ in invalid } }
    }

    @Test("A cached thread reply is not substituted for its alleged root")
    func cachedReplyIsNotRoot() async {
        var reply = root
        reply.threadRootID = "$other-root"
        await #expect(throws: ThreadRootResolver.Failure.self) {
            _ = try await resolve(candidates: [reply]) { _, _ in root }
        }
    }

    @Test("A deleted root still opens so its surviving replies stay visible")
    func redactedRoot() async throws {
        var redacted = root
        redacted.isRedacted = true
        let resolved = try await resolve { _, _ in redacted }
        #expect(resolved.isRedacted && resolved.id == root.id)
    }

    @Test("A fetch failure propagates as-is")
    func fetchFailurePropagates() async {
        await #expect(throws: FetchFailure()) { _ = try await resolve { _, _ in throw FetchFailure() } }
    }

    @Test("A stale context cancels before anything is fetched")
    func staleBeforeFetch() async {
        var fetched = false
        await #expect(throws: CancellationError.self) {
            _ = try await resolve(
                validate: { throw CancellationError() },
                load: { _, _ in
                    fetched = true
                    return root
                })
        }
        #expect(!fetched)
    }

    @Test("A context that goes stale during the fetch rejects the late result or error", arguments: [true, false])
    func staleDuringFetch(succeeds: Bool) async {
        var current = true
        let gate = Gate()
        gate.arm()
        let pending = Task {
            try await resolve(
                validate: { if !current { throw CancellationError() } },
                load: { _, _ in
                    await gate.wait()
                    if !succeeds { throw FetchFailure() }
                    return root
                })
        }
        #expect(await eventually { gate.isWaiting })
        current = false
        gate.release()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
    }

    @Test("Cancelling the caller rejects a fetch that completes anyway")
    func cancelledDuringFetch() async {
        let gate = Gate()
        gate.arm()
        let pending = Task {
            try await resolve { _, _ in
                await gate.wait()
                return root
            }
        }
        #expect(await eventually { gate.isWaiting })
        pending.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
    }

    @Test("An already-cancelled attempt never fetches")
    func cancelledBeforeFetch() async {
        var fetched = false
        let gate = Gate()
        gate.arm()
        let pending = Task {
            await gate.wait()
            return try await resolve { _, _ in
                fetched = true
                return root
            }
        }
        #expect(await eventually { gate.isWaiting })
        pending.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(!fetched)
    }
}
