enum IdentityGatePolicy {
    enum Identity {
        case unknown, absent, present, unavailable
    }

    static func shouldPrompt(hasDevice: Bool, isUnverified: Bool, identity: Identity, skipped: Bool) -> Bool {
        isUnverified && !skipped && (identity == .unavailable || hasDevice && identity == .present)
    }
}
