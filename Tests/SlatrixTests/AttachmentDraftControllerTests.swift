import Foundation
import Testing

@testable import Slatrix

/// Fails manifest commits while switched on.
private final class SaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func set(_ value: Bool) { lock.withLock { failing = value } }
    func call(_ point: AttachmentDraftStore.FaultPoint) throws {
        if point == .beforeManifestCommit, lock.withLock({ failing }) { throw AttachmentDraftError.unavailable }
    }
}

/// Holds key lookups per account until the test releases them.
private final class AccountKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<Data, Never>] = [:]
    private var released = Set<String>()
    private static let key = Data(repeating: 0x6b, count: 32)
    func key(_ account: String) async -> Data {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if released.contains(account) { return true }
                waiting[account] = continuation
                return false
            }
            if ready { continuation.resume(returning: Self.key) }
        }
    }
    func isWaiting(_ account: String) -> Bool { lock.withLock { waiting[account] != nil } }
    func release(_ account: String) {
        let continuation = lock.withLock {
            released.insert(account)
            return waiting.removeValue(forKey: account)
        }
        continuation?.resume(returning: Self.key)
    }
}

@MainActor
final class AttachmentDraftControllerTests {
    private let account = "@controller:example.org"
    private let other = "@other-controller:example.org"
    private let address = AttachmentDraftAddress(roomID: "!controller:example.org")
    private let root: TemporaryDirectory
    private var staged: [URL] = []

    init() throws { root = try TemporaryDirectory() }
    deinit { ComposerAttachmentImporter.discard(staged) }

    private func file(_ name: String) throws -> URL {
        let url = try ComposerAttachmentImporter.stageRestoredData(Data("Fixture \(name)".utf8), filename: name)
        staged.append(url)
        return url
    }
    private func controller(_ fault: SaveFault? = nil) -> AttachmentDraftController {
        AttachmentDraftController(
            store: AttachmentDraftStore(
                directory: root.path("vault"), keyProvider: { _ in Data(repeating: 0x6b, count: 32) },
                fault: { try fault?.call($0) }))
    }
    private func names(_ controller: AttachmentDraftController) -> [String] {
        controller.files[address, default: []].map(\.filename).sorted()
    }

    @Test("Rapid queue changes settle on the last one, separately for a room and its thread, and survive reopening")
    func latestQueueWins() async throws {
        let controller = controller()
        await controller.open(accountID: account)
        let a = try file("a.txt")
        let b = try file("b.txt")
        let thread = AttachmentDraftAddress(roomID: address.roomID, threadRootID: "$thread")
        controller.set([a], at: address)
        controller.set([a, b], at: address)
        controller.set([b], at: address)
        controller.set([a], at: thread)
        try await controller.flush()
        await controller.close()
        await controller.open(accountID: account)
        #expect(names(controller) == ["b.txt"])
        #expect(controller.files[thread]?.map(\.filename) == ["a.txt"])
    }

    @Test("A file is not handed over for sending until its sending state is saved")
    func sendWaitsForDurableState() async throws {
        let fault = SaveFault()
        let controller = controller(fault)
        await controller.open(accountID: account)
        let pending = try file("pending.txt")
        fault.set(true)
        controller.set([pending], at: address)
        await #expect(throws: (any Error).self) { try await controller.prepareSend(pending, at: address) }
        #expect(controller.queues[address] == [pending])
    }

    @Test("After a failed send the queue waits for an explicit resend, and a sent file stays gone")
    func failedSendNeedsResend() async throws {
        let controller = controller()
        await controller.open(accountID: account)
        let pending = try file("pending.txt")
        controller.set([pending], at: address)
        try await controller.prepareSend(pending, at: address)
        await controller.didFail(pending, at: address)
        #expect(controller.needsReview(address) && !controller.canSend(address))
        await #expect(throws: (any Error).self) { try await controller.prepareSend(pending, at: address) }
        controller.allowResend(address)
        try await controller.prepareSend(pending, at: address)
        await controller.didSend(pending, at: address)
        try await controller.flush()
        #expect(controller.queues[address, default: []].isEmpty)
        await controller.close()
        await controller.open(accountID: account)
        #expect(names(controller).isEmpty)
    }

    @Test("A sent file whose local cleanup failed stays out of the queue while the cleanup is retried")
    func failedCleanupNeverResends() async throws {
        let fault = SaveFault()
        let controller = controller(fault)
        await controller.open(accountID: account)
        let sent = try file("already-sent.txt")
        let kept = try file("keep.txt")
        let added = try file("added.txt")
        controller.set([sent, kept], at: address)
        try await controller.flush()
        try await controller.prepareSend(sent, at: address)
        fault.set(true)
        await controller.didSend(sent, at: address)
        #expect(controller.errorMessage != nil && controller.queues[address] == [kept])
        controller.discard([sent])
        controller.set([kept, added], at: address)
        await #expect(throws: (any Error).self) { try await controller.flush() }
        fault.set(false)
        try await controller.flush()
        #expect(controller.errorMessage == nil && names(controller) == ["added.txt", "keep.txt"])
        await controller.close()
        await controller.open(accountID: account)
        #expect(names(controller) == ["added.txt", "keep.txt"])
    }

    @Test("A send cut off by quitting needs review after restart before it can go again")
    func interruptedSendNeedsReview() async throws {
        let controller = controller()
        await controller.open(accountID: account)
        let interrupted = try file("interrupted.txt")
        controller.set([interrupted], at: address)
        try await controller.flush()
        try await controller.prepareSend(interrupted, at: address)
        await controller.close()
        await controller.open(accountID: account)
        #expect(controller.needsReview(address) && !controller.canSend(address))
        let restored = try #require(controller.queues[address]?.first)
        await #expect(throws: (any Error).self) { try await controller.prepareSend(restored, at: address) }
        controller.allowResend(address)
        #expect(controller.canSend(address))
    }

    @Test("Two simultaneous sends of the same file let only one through")
    func oneConcurrentSend() async throws {
        let controller = controller()
        await controller.open(accountID: account)
        let file = try file("one-upload.txt")
        controller.set([file], at: address)
        try await controller.flush()
        let attempts = (0..<2).map { _ in
            Task { () -> Bool in (try? await controller.prepareSend(file, at: address)) != nil }
        }
        var admitted = 0
        for attempt in attempts where await attempt.value { admitted += 1 }
        #expect(admitted == 1)
    }

    @Test("A send abandoned by a closed composer becomes reviewable instead of locking the queue")
    func abandonedSendBecomesReviewable() async throws {
        let fault = SaveFault()
        let controller = controller(fault)
        await controller.open(accountID: account)
        let flight = try file("old-session-flight.txt")
        controller.set([flight], at: address)
        try await controller.flush()
        try await controller.prepareSend(flight, at: address)
        fault.set(true)
        await controller.deactivate()
        fault.set(false)
        await controller.open(accountID: account)
        #expect(controller.needsReview(address) && !controller.canSend(address))
        let retry = try #require(controller.queues[address]?.first)
        controller.allowResend(address)
        try await controller.prepareSend(retry, at: address)
        #expect(controller.queues[address]?.contains(retry) == true)
    }

    @Test("Files that failed to save stay private to their account across an account switch and return with it")
    func failedSaveSurvivesAccountSwitch() async throws {
        let fault = SaveFault()
        let controller = controller(fault)
        await controller.open(accountID: account)
        let retained = try file("retain-on-failure.txt")
        fault.set(true)
        controller.set([retained], at: address)
        await controller.deactivate()
        #expect(!controller.ready && controller.queues.isEmpty)
        #expect(FileManager.default.fileExists(atPath: retained.path))
        await controller.open(accountID: other)
        #expect(controller.ready && controller.queues.isEmpty && controller.files.isEmpty)
        await #expect(throws: (any Error).self) { try await controller.flush() }
        fault.set(false)
        await controller.open(accountID: account)
        #expect(controller.ready && names(controller) == ["retain-on-failure.txt"])
        try await controller.flush()
        await controller.close()
        await controller.open(accountID: account)
        #expect(names(controller) == ["retain-on-failure.txt"])
    }

    @Test("A slow open of an earlier account cannot take over the account opened after it")
    func lateOpenLoses() async throws {
        let keys = AccountKeys()
        let controller = AttachmentDraftController(
            store: AttachmentDraftStore(directory: root.path("opening"), keyProvider: { await keys.key($0) }))
        let older = Task { await controller.open(accountID: account) }
        #expect(await eventually { keys.isWaiting(account) })
        let newer = Task { await controller.open(accountID: other) }
        #expect(await eventually { keys.isWaiting(other) })
        keys.release(other)
        await newer.value
        #expect(controller.ready)
        keys.release(account)
        await older.value
        #expect(controller.ready && controller.queues.isEmpty)
        controller.set([try file("other-account.txt")], at: address)
        try await controller.flush()
        await controller.close()
        await controller.open(accountID: account)
        #expect(controller.queues.isEmpty)
        await controller.close()
        await controller.open(accountID: other)
        #expect(names(controller) == ["other-account.txt"])
    }
}
