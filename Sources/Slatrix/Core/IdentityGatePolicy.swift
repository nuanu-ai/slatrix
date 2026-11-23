enum IdentityGatePolicy {
    enum Identity {
        case unknown, absent, present, unavailable
    }

    static func shouldPrompt(
        hasDevice: Bool, isUnverified: Bool, identity: Identity, skipped: Bool, isOnline: Bool = true
    ) -> Bool {
        isOnline && isUnverified && !skipped
            && ((hasDevice && identity == .present) || (!hasDevice && identity == .unavailable))
    }

    /// Persist Skip only after an online lookup confirmed the account has a cross-signing identity to confirm.
    static func shouldPersistSkip(isOnline: Bool, identity: Identity) -> Bool {
        isOnline && identity == .present
    }

    static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]

    /// Looks up whether the account has a cross-signing identity, retrying transient network failures (nil) with
    /// bounded backoff while online until a definite result arrives or the task cancels.
    static func resolveIdentity(
        delays: [Duration] = retryDelays,
        lookup: () async -> Bool?,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async -> Identity {
        if let definite = await lookup() { return definite ? .present : .absent }
        for delay in delays {
            guard !Task.isCancelled else { return .unknown }
            do { try await sleep(delay) } catch { return .unknown }
            guard !Task.isCancelled else { return .unknown }
            if let definite = await lookup() { return definite ? .present : .absent }
        }
        return .unavailable
    }
}
