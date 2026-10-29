import Foundation
import Testing

@testable import Slatrix

private struct LocalFailure: Error {}

@MainActor
struct LogoutRecoveryControllerTests {
    private let owner = LogoutOwner(sessionID: UUID(), userID: "@owner:example.org", isPreview: false)
    private let controller = LogoutRecoveryController()
    private let serverDown = ServerLogoutFailure(message: "Unable to reach the homeserver.")
    /// What reached each boundary: draft saves, server logouts, local cleanups and reported errors.
    private final class Log {
        var flushes = 0
        var server = 0
        var local = 0
        var reports = 0
    }
    private let log = Log()

    private func signOut(
        current: @escaping () -> LogoutOwner? = { nil }, flush: (() async throws -> Void)? = nil,
        remote: (() async throws -> Void)? = nil
    ) async {
        let owner = owner
        await controller.signOut(
            owner: owner, current: { current() ?? owner },
            flush: { [log] in
                log.flushes += 1
                try await flush?()
            },
            remote: { [log, serverDown] in
                log.server += 1
                if let remote { try await remote() } else { throw serverDown }
            }, report: { [log] _ in log.reports += 1 })
    }
    private func signOutLocally(
        _ request: LogoutRecoveryRequest, flush: (() async throws -> Void)? = nil,
        local: (() async throws -> Void)? = nil
    ) async {
        let owner = owner
        await controller.signOutLocally(
            request, current: { owner },
            flush: { [log] in
                log.flushes += 1
                try await flush?()
            },
            local: { [log] in
                log.local += 1
                try await local?()
            }, report: { [log] _ in log.reports += 1 })
    }

    @Test("If drafts cannot be saved, the server sign-out is never attempted")
    func failedFlushStops() async {
        await signOut(flush: { throw LocalFailure() })
        #expect(log.reports == 1 && log.server == 0 && controller.request == nil)
    }

    @Test("A failed server sign-out offers local sign-out without doing it")
    func serverFailureOffersRecovery() async throws {
        await signOut()
        let request = try #require(controller.request)
        #expect(request.owner == owner && log.reports == 0 && log.local == 0)
    }

    @Test("After Cancel, an already captured local sign-out does nothing")
    func cancelInvalidatesChoice() async throws {
        await signOut()
        let request = try #require(controller.request)
        controller.cancel()
        await signOutLocally(request)
        #expect(controller.request == nil && log.local == 0)
    }

    // capability: auth.sign-out
    @Test("Retry saves drafts again and clears the recovery offer when the server succeeds")
    func retrySucceeds() async throws {
        await signOut()
        let request = try #require(controller.request)
        let owner = owner
        await controller.retry(
            request, current: { owner }, flush: { [log] in log.flushes += 1 }, remote: {}, report: { _ in })
        #expect(controller.request == nil && log.flushes == 2)
    }

    // capability: auth.sign-out
    @Test("Signing out locally saves drafts again, cleans up once and does not retry the server")
    func localSignOut() async throws {
        await signOut()
        let request = try #require(controller.request)
        await signOutLocally(request)
        #expect(log.local == 1 && log.server == 1 && log.flushes == 2 && controller.request == nil)
    }

    @Test("If drafts cannot be saved before local sign-out, the account and the offer stay")
    func localFlushFailureKeepsOffer() async throws {
        await signOut()
        let request = try #require(controller.request)
        await signOutLocally(request, flush: { throw LocalFailure() })
        #expect(log.local == 0 && log.reports == 1 && controller.request?.id == request.id)
    }

    @Test("A failed local cleanup is reported and the offer stays")
    func localCleanupFailureReported() async throws {
        await signOut()
        let request = try #require(controller.request)
        await signOutLocally(request, local: { throw LocalFailure() })
        #expect(log.reports == 1 && controller.request?.id == request.id)
    }

    @Test("A second sign-out while one is running sends nothing, and a reply after an account switch shows nothing")
    func duplicateAndStaleServerReply() async {
        let gate = Gate()
        gate.arm()
        var current = owner
        let pending = Task {
            await signOut(
                current: { current },
                remote: { [serverDown] in
                    await gate.wait()
                    throw serverDown
                })
        }
        #expect(await eventually { gate.isWaiting })
        await signOut()
        #expect(controller.isBusy && log.server == 1)
        current = LogoutOwner(sessionID: UUID(), userID: owner.userID, isPreview: false)
        controller.invalidate()
        #expect(controller.isBusy)
        gate.release()
        await pending.value
        #expect(controller.request == nil && !controller.isBusy)
    }

    @Test("Switching accounts while drafts are saving stops the server sign-out")
    func accountChangeDuringFlush() async {
        let gate = Gate()
        gate.arm()
        var current = owner
        let pending = Task { await signOut(current: { current }, flush: { await gate.wait() }) }
        #expect(await eventually { gate.isWaiting })
        current = LogoutOwner(sessionID: owner.sessionID, userID: "@other:example.org", isPreview: false)
        gate.release()
        await pending.value
        #expect(log.flushes == 1 && log.server == 0 && controller.request == nil)
    }

    @Test("A recovery offer from an earlier attempt cannot act on a later one")
    func outdatedOfferIgnored() async throws {
        await signOut()
        let outdated = try #require(controller.request)
        controller.cancel()
        await signOut()
        let active = try #require(controller.request)
        await signOutLocally(outdated)
        #expect(log.local == 0 && controller.request?.id == active.id)
    }

    @Test("A cancelled sign-out reports nothing and offers nothing")
    func cancellationIsQuiet() async {
        await signOut(remote: { throw CancellationError() })
        #expect(log.reports == 0 && controller.request == nil)
    }

    @Test("A failure that is not the server's is reported instead of offering local sign-out")
    func nonServerFailureReported() async {
        await signOut(remote: { throw LocalFailure() })
        #expect(controller.request == nil && log.reports == 1)
    }
}
