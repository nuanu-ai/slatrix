import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private final class Subscriptions: RoomListService, @unchecked Sendable {
    let snapshots = Recorder<[String]>()
    var fail = false
    var last: [String]? { snapshots.all.last }
    override func setRoomSubscriptions(roomIds: [String]) async throws {
        snapshots.append(roomIds)
        if fail { throw MatrixServiceError.request("subscription failed") }
    }
}

private struct HydrationFailure: Error {}

@MainActor
struct RoomSubscriptionCoordinatorTests {
    private let sdk = Subscriptions(noHandle: .init())
    let coordinator = RoomSubscriptionCoordinator()
    init() { coordinator.attach(sdk) }

    @Test("The selected room and the feed rooms share one deduplicated subscription")
    func selectionAndFeedCombine() async throws {
        try await coordinator.setActiveRoom("!selected:example.org")
        try await coordinator.setFeedRooms(["!selected:example.org", "!feed:example.org"])
        #expect(sdk.last == ["!feed:example.org", "!selected:example.org"])
        try await coordinator.setFeedRooms([])
        #expect(sdk.last == ["!selected:example.org"])
    }

    @Test("A room being set up stays subscribed until its own operation ends, whatever the selection does")
    func mutationLeases() async throws {
        try await coordinator.setActiveRoom("!active:example.org")
        try await coordinator.setFeedRooms(["!feed:example.org"])
        try await coordinator.withMutationRoom(roomID: "!outer:example.org") {
            try await coordinator.withMutationRoom(roomID: "!inner:example.org") {
                try await coordinator.setActiveRoom("!new-active:example.org")
                try await coordinator.setFeedRooms([])
                #expect(sdk.last == ["!inner:example.org", "!new-active:example.org", "!outer:example.org"])
            }
            #expect(sdk.last == ["!new-active:example.org", "!outer:example.org"])
        }
        #expect(sdk.last == ["!new-active:example.org"])
    }

    @Test("A failed setup releases its room")
    func failedMutationReleases() async throws {
        try await coordinator.setActiveRoom("!active:example.org")
        await #expect(throws: HydrationFailure.self) {
            try await coordinator.withMutationRoom(roomID: "!failing:example.org") { throw HydrationFailure() }
        }
        #expect(sdk.last == ["!active:example.org"])
    }

    @Test("A setup whose subscription fails never runs, and later snapshots leave its room out")
    func failedSubscriptionBlocksMutation() async throws {
        try await coordinator.setActiveRoom("!active:example.org")
        sdk.fail = true
        var ran = false
        await #expect(throws: MatrixServiceError.self) {
            try await coordinator.withMutationRoom(roomID: "!unsubscribed:example.org") { ran = true }
        }
        sdk.fail = false
        try await coordinator.setFeedRooms(["!feed:example.org"])
        #expect(!ran)
        #expect(sdk.last == ["!active:example.org", "!feed:example.org"])
    }

    @Test("Releasing an old account's setup room never touches the new account's subscriptions")
    func oldLeaseIgnoresNewAccount() async throws {
        let replacement = Subscriptions(noHandle: .init())
        await #expect(throws: CancellationError.self) {
            try await coordinator.withMutationRoom(roomID: "!old:example.org") { coordinator.attach(replacement) }
        }
        try await coordinator.setActiveRoom("!replacement:example.org")
        #expect(replacement.snapshots.all == [["!replacement:example.org"]])
    }
}
