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
}
