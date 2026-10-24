import Testing

@testable import Slatrix

struct IdentityGatePolicyTests {
    @Test(
        "An unverified device waits for the lookup, then confirms existing or temporarily unavailable identity",
        arguments: [
            (IdentityGatePolicy.Identity.unknown, false),
            (.absent, false),
            (.present, true),
            (.unavailable, true),
        ])
    func identityLookup(identity: IdentityGatePolicy.Identity, expected: Bool) {
        #expect(
            IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: true, identity: identity, skipped: false) == expected)
    }

    @Test("A missing device ID makes an unverified session unavailable instead of silently skipping the gate")
    func missingDeviceID() {
        #expect(
            IdentityGatePolicy.shouldPrompt(
                hasDevice: false, isUnverified: true, identity: .unavailable, skipped: false))
    }

    @Test("Verified, device-less, and skipped sessions do not prompt")
    func doesNotPrompt() {
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: false, identity: .present, skipped: false))
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: false, isUnverified: true, identity: .present, skipped: false))
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: true, identity: .present, skipped: true))
    }
}
