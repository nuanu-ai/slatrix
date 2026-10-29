import Foundation
import MatrixRustSDK
import Testing

@testable import Slatrix

private struct WrongRecoveryKey: Error {}

private final class FakeEncryption: Encryption, @unchecked Sendable {
    override func verificationState() -> VerificationState { .unverified }
    override func verificationStateListener(listener: VerificationStateListener) -> TaskHandle {
        FakeCancellableHandle(noHandle: .init())
    }
    override func hasDevicesToVerifyAgainst() async throws -> Bool { true }
    let recovered = Recorder<String>()
    override func recover(recoveryKey: String) async throws {
        guard recoveryKey != "wrong" else { throw WrongRecoveryKey() }
        recovered.append(recoveryKey)
    }
}

private final class FakeVerificationController: SessionVerificationController, @unchecked Sendable {
    let delegates = Recorder<SessionVerificationControllerDelegate>()
    let calls = Recorder<String>()
    let requestGate = Gate()
    var delegate: SessionVerificationControllerDelegate? { delegates.all.last }
    override func setDelegate(delegate: SessionVerificationControllerDelegate?) {
        if let delegate { delegates.append(delegate) }
    }
    override func requestDeviceVerification() async throws {
        calls.append("request")
        await requestGate.wait()
    }
    override func startSasVerification() async throws { calls.append("start") }
    override func approveVerification() async throws { calls.append("approve") }
    override func declineVerification() async throws { calls.append("decline") }
    override func cancelVerification() async throws { calls.append("cancel") }
}

private final class VerifyingClient: Client, @unchecked Sendable {
    let controller = FakeVerificationController(noHandle: .init())
    let crypto = FakeEncryption(noHandle: .init())
    override func deviceId() throws -> String { "DEVICE" }
    override func encryption() -> Encryption { crypto }
    override func getSessionVerificationController() async throws -> SessionVerificationController { controller }
}

@MainActor
struct VerificationServiceTests {
    private let client = VerifyingClient(noHandle: .init())
    private let service = VerificationService()
    private var controller: FakeVerificationController { client.controller }

    @Test(
        "Codes can be compared only as seven emoji or three decimals between 1000 and 9191",
        arguments: [
            (7, [], true), (0, [1000, 5000, 9191], true), (6, [], false), (0, [999, 5000, 9192], false),
            (7, [1000, 5000, 9191], false),
        ] as [(Int, [UInt16], Bool)])
    func comparableCodes(emoji: Int, decimals: [UInt16], valid: Bool) {
        #expect(VerificationService.validComparison(emojiCount: emoji, decimals: decimals) == valid)
    }

    /// Requests verification and brings the flow to the code comparison.
    private func compare(_ codes: [UInt16] = [1234, 4567, 8901]) async {
        await service.attach(client: client)
        await service.requestVerification()
        #expect(service.phase == .waitingForOtherDevice)
        controller.delegate?.didAcceptVerificationRequest()
        #expect(await eventually { service.phase == .ready })
        await service.startComparison()
        controller.delegate?.didReceiveVerificationData(data: .decimals(values: codes))
        #expect(await eventually { service.phase != .exchanging })
    }

    // capability: verify.device
    @Test("Verification finishes only after the person confirms the codes match")
    func finishesAfterHumanConfirmation() async {
        await compare()
        #expect(service.phase == .comparison && service.decimals == [1234, 4567, 8901])
        controller.delegate?.didFinish()
        await drainMainActor()
        #expect(service.phase == .comparison)
        await service.confirmMatch()
        #expect(controller.calls.all.contains("approve") && service.phase == .awaitingConfirmation)
        controller.delegate?.didFinish()
        #expect(await eventually { service.phase == .finished })
        #expect(service.decimals.isEmpty)
    }

    @Test("Codes that can't be shown safely fail the flow and cancel it with the SDK")
    func invalidCodesFail() async {
        await compare([1, 2, 3])
        #expect(service.phase == .failed && service.decimals.isEmpty)
        #expect(await eventually { controller.calls.all.contains("cancel") })
    }

    @Test("The other side cancelling during the comparison clears the codes")
    func cancelledDuringComparison() async {
        await compare()
        controller.delegate?.didCancel()
        #expect(await eventually { service.phase == .cancelled })
        #expect(service.decimals.isEmpty)
    }

    @Test("Callbacks from a cancelled flow are ignored")
    func previousFlowIgnored() async {
        await compare()
        let previous = controller.delegate
        await service.cancel()
        #expect(await eventually { !service.isCleaningUp && service.phase == .cancelled })
        previous?.didReceiveVerificationData(data: .decimals(values: [1234, 4567, 8901]))
        previous?.didReceiveVerificationRequest(
            details: SessionVerificationRequestDetails(
                senderProfile: UserProfile(
                    userId: "@me:example.org", displayName: nil, avatarUrl: nil, status: nil, call: nil),
                flowId: "old", deviceId: "OTHER", deviceDisplayName: nil, firstSeenTimestamp: 0))
        await drainMainActor()
        #expect(service.phase == .cancelled && service.decimals.isEmpty && service.request == nil)
    }

    @Test("Closing stays available while a request is still in flight")
    func dismissDuringOperation() async {
        await service.attach(client: client)
        controller.requestGate.arm()
        let request = Task { await service.requestVerification() }
        #expect(await eventually { controller.requestGate.isWaiting })
        #expect(service.isWorking && service.isPresented)
        service.dismiss()
        #expect(!service.isPresented && !service.isWorking)
        controller.requestGate.release()
        await request.value
    }

    // capability: verify.recovery-key
    @Test("A recovery key unlocks history through the SDK, and a key the SDK refuses fails the unlock")
    func recoveryKey() async throws {
        let matrix = MatrixService()
        matrix.configureMessageActionsForChecks(
            client: client, main: nil, thread: nil, rootID: nil, sessionID: UUID(), selectionID: UUID(),
            threadID: UUID())
        await #expect(throws: WrongRecoveryKey.self) { try await matrix.recoverEncryption(recoveryKey: "wrong") }
        try await matrix.recoverEncryption(recoveryKey: "EsTc 1234")
        #expect(client.crypto.recovered.all == ["EsTc 1234"])
    }
}
