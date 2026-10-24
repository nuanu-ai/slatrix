import Combine
import Foundation

struct LogoutOwner: Equatable {
    let sessionID: UUID
    let userID: String?
    let isPreview: Bool
}

/// Only a failed server request offers local sign-out. Draft or credential
/// cleanup failures must not be mistaken for a failed remote logout.
struct ServerLogoutFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct LogoutRecoveryRequest: Identifiable {
    let id = UUID()
    let owner: LogoutOwner
    let message: String
}

@MainActor
final class LogoutRecoveryController: ObservableObject {
    @Published private(set) var request: LogoutRecoveryRequest?
    @Published private(set) var isBusy = false
    private var operation = UUID()
    private var busyOperation: UUID?

    func invalidate() {
        operation = UUID()
        request = nil
    }

    func cancel() {
        guard !isBusy else { return }
        request = nil
    }

    func signOut(
        owner: LogoutOwner, current: () -> LogoutOwner,
        flush: () async throws -> Void, remote: () async throws -> Void,
        report: (Error) -> Void
    ) async {
        guard !isBusy, current() == owner else { return }
        let token = UUID()
        operation = token
        busyOperation = token
        isBusy = true
        request = nil
        defer {
            if busyOperation == token {
                busyOperation = nil
                isBusy = false
            }
        }
        @MainActor func isCurrent() -> Bool { operation == token && current() == owner }
        do {
            try await flush()
            guard isCurrent() else { return }
        } catch {
            if isCurrent(), !(error is CancellationError) { report(error) }
            return
        }
        do { try await remote() } catch {
            guard isCurrent(), !(error is CancellationError) else { return }
            if let failure = error as? ServerLogoutFailure, !owner.isPreview, owner.userID != nil {
                request = LogoutRecoveryRequest(owner: owner, message: failure.message)
            } else {
                report(error)
            }
        }
    }

    func retry(
        _ captured: LogoutRecoveryRequest, current: () -> LogoutOwner,
        flush: () async throws -> Void, remote: () async throws -> Void,
        report: (Error) -> Void
    ) async {
        guard request?.id == captured.id, current() == captured.owner else { return }
        await signOut(owner: captured.owner, current: current, flush: flush, remote: remote, report: report)
    }

    func signOutLocally(
        _ captured: LogoutRecoveryRequest, current: () -> LogoutOwner,
        flush: () async throws -> Void, local: () async throws -> Void,
        report: (Error) -> Void
    ) async {
        guard !isBusy, request?.id == captured.id, current() == captured.owner else { return }
        let token = UUID()
        operation = token
        busyOperation = token
        isBusy = true
        defer {
            if busyOperation == token {
                busyOperation = nil
                isBusy = false
            }
        }
        @MainActor func isCurrent() -> Bool { operation == token && current() == captured.owner }
        do {
            // Drafts may have changed since the failed request. Never discard
            // unsaved text or queued files merely to recover from a network error.
            try await flush()
            guard isCurrent(), request?.id == captured.id else { return }
            try await local()
            if isCurrent() { request = nil }
        } catch {
            if isCurrent(), !(error is CancellationError) { report(error) }
        }
    }
}
