import Testing

@testable import Slatrix

struct IdentityGatePolicyTests {
    @Test(
        "An unverified device waits for the lookup, confirms an existing identity, and never forces the gate on lookup errors",
        arguments: [
            (IdentityGatePolicy.Identity.unknown, false),
            (.absent, false),
            (.present, true),
            (.unavailable, false),
        ])
    func identityLookup(identity: IdentityGatePolicy.Identity, expected: Bool) {
        #expect(
            IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: true, identity: identity, skipped: false, isOnline: true) == expected)
    }

    // capability: verify.gate
    @Test("A missing device ID prompts while online instead of silently skipping the gate")
    func missingDeviceID() {
        #expect(
            IdentityGatePolicy.shouldPrompt(
                hasDevice: false, isUnverified: true, identity: .unavailable, skipped: false, isOnline: true))
    }

    // capability: verify.gate
    @Test(
        "Verified, device-less, skipped, and offline sessions do not prompt, and Skip persists only when confirmed online"
    )
    func doesNotPrompt() {
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: false, identity: .present, skipped: false, isOnline: true))
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: false, isUnverified: true, identity: .present, skipped: false, isOnline: true))
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: true, identity: .present, skipped: true, isOnline: true))
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: true, isUnverified: true, identity: .present, skipped: false, isOnline: false))
        #expect(
            !IdentityGatePolicy.shouldPrompt(
                hasDevice: false, isUnverified: true, identity: .unavailable, skipped: false, isOnline: false))
        #expect(!IdentityGatePolicy.shouldPersistSkip(isOnline: false, identity: .present))
        #expect(!IdentityGatePolicy.shouldPersistSkip(isOnline: true, identity: .unavailable))
        #expect(IdentityGatePolicy.shouldPersistSkip(isOnline: true, identity: .present))
    }

    @Test("Transient identity lookup failures retry with bounded backoff until a definite result arrives")
    func transientLookupFailureRetriesWithBackoff() async {
        var responses: [Bool?] = [nil, nil, true]
        var slept: [Duration] = []
        let resolved = await IdentityGatePolicy.resolveIdentity(
            delays: [.seconds(2), .seconds(5), .seconds(15)],
            lookup: { responses.removeFirst() },
            sleep: { slept.append($0) })
        #expect(resolved == .present && slept == [.seconds(2), .seconds(5)])

        var alwaysFailing: [Bool?] = [nil, nil, nil]
        var exhaustedSleeps: [Duration] = []
        let unavailable = await IdentityGatePolicy.resolveIdentity(
            delays: [.seconds(2), .seconds(5)],
            lookup: { alwaysFailing.removeFirst() },
            sleep: { exhaustedSleeps.append($0) })
        #expect(unavailable == .unavailable && exhaustedSleeps == [.seconds(2), .seconds(5)])

        var absentSleeps: [Duration] = []
        let absent = await IdentityGatePolicy.resolveIdentity(
            delays: [.seconds(2)], lookup: { false }, sleep: { absentSleeps.append($0) })
        #expect(absent == .absent && absentSleeps.isEmpty)
    }
}
