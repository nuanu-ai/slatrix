import Combine
import Foundation
import MatrixRustSDK

private final class VerificationObserver: SessionVerificationControllerDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case request(SessionVerificationRequestDetails)
        case accepted, started
        case data(SessionVerificationData)
        case failed, cancelled, finished
    }
    let receive: @Sendable (Event) -> Void
    init(_ receive: @escaping @Sendable (Event) -> Void) { self.receive = receive }
    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) { receive(.request(details)) }
    func didAcceptVerificationRequest() { receive(.accepted) }
    func didStartSasVerification() { receive(.started) }
    func didReceiveVerificationData(data: SessionVerificationData) { receive(.data(data)) }
    func didFail() { receive(.failed) }
    func didCancel() { receive(.cancelled) }
    func didFinish() { receive(.finished) }
}

private final class DeviceVerificationObserver: VerificationStateListener, @unchecked Sendable {
    let receive: @Sendable (VerificationState) -> Void
    init(_ receive: @escaping @Sendable (VerificationState) -> Void) { self.receive = receive }
    func onUpdate(status: VerificationState) { receive(status) }
}

@MainActor
final class VerificationService: ObservableObject {
    enum Phase: Equatable {
        case idle, preparing, incoming, requesting, waitingForOtherDevice, ready, exchanging, comparison,
            awaitingConfirmation, cancelling, finished, cancelled, failed
        var isActive: Bool {
            switch self {
            case .incoming, .requesting, .waitingForOtherDevice, .ready, .exchanging, .comparison,
                .awaitingConfirmation:
                true
            default: false
            }
        }
    }
    enum DeviceStatus { case unknown, unverified, verified }
    struct Emoji: Identifiable, Equatable {
        let id: Int
        let symbol: String
        let name: String
    }
    struct Request: Equatable {
        let userID: String
        let name: String
        let deviceID: String
        let deviceName: String?
        let flowID: String
        let firstSeen: Date
    }

    @Published var isPresented = false
    @Published private(set) var phase = Phase.idle
    @Published private(set) var deviceStatus = DeviceStatus.unknown
    @Published private(set) var request: Request?
    @Published private(set) var emojis: [Emoji] = []
    @Published private(set) var decimals: [UInt16] = []
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAvailable = false
    @Published private(set) var ownDeviceID: String?
    @Published private(set) var isCleaningUp = false

    private var client: Client?
    private var controller: SessionVerificationController?
    private var controllerTask: Task<SessionVerificationController, Error>?
    private var observer: VerificationObserver?
    private var statusHandle: TaskHandle?
    private var generation = UUID()
    private var flowGeneration = UUID()
    private var operationTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var attachRetryTask: Task<Void, Never>?
    private var cleanupController: SessionVerificationController?
    private var acceptedByUser = false
    private var confirmedByUser = false

    func attach(client: Client) async {
        detach()
        let token = generation
        self.client = client
        ownDeviceID = try? client.deviceId()
        let encryption = client.encryption()
        updateDeviceStatus(encryption.verificationState())
        statusHandle = encryption.verificationStateListener(
            listener: DeviceVerificationObserver { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token else { return }
                    self.updateDeviceStatus(state)
                }
            })
        scheduleAttachRetries(token: token)
    }

    func detach() {
        generation = UUID()
        flowGeneration = UUID()
        operationTask?.cancel()
        operationTask = nil
        cleanupTask?.cancel()
        cleanupTask = nil
        attachRetryTask?.cancel()
        attachRetryTask = nil
        controllerTask?.cancel()
        controllerTask = nil
        controller?.setDelegate(delegate: nil)
        statusHandle?.cancel()
        statusHandle = nil
        observer = nil
        controller = nil
        client = nil
        isPresented = false
        phase = .idle
        deviceStatus = .unknown
        isAvailable = false
        ownDeviceID = nil
        request = nil
        emojis = []
        decimals = []
        errorMessage = nil
        isWorking = false
        acceptedByUser = false
        confirmedByUser = false
        isCleaningUp = false
        cleanupController = nil
    }

    func requestVerification() async {
        guard !isWorking, !phase.isActive, !isCleaningUp else {
            isPresented = true
            return
        }
        if cleanupController != nil {
            beginCleanup(terminal: .cancelled)
            isPresented = true
            return
        }
        rotateFlowObserver()
        attachRetryTask?.cancel()
        attachRetryTask = nil
        isPresented = true
        phase = .preparing
        isWorking = true
        errorMessage = nil
        request = nil
        emojis = []
        decimals = []
        acceptedByUser = false
        confirmedByUser = false
        await perform { [self] token, flow in
            guard let client else { throw VerificationError.signedOut }
            let controller = try await ensureController(token: token)
            guard isCurrent(token, flow) else { return }
            let hasOtherDevice = try await client.encryption().hasDevicesToVerifyAgainst()
            guard isCurrent(token, flow) else { return }
            guard hasOtherDevice else { throw VerificationError.noOtherDevice }
            acceptedByUser = true
            phase = .requesting
            try await controller.requestDeviceVerification()
            if isCurrent(token, flow), phase == .requesting { phase = .waitingForOtherDevice }
        }
    }

    func accept() async {
        guard phase == .incoming, !isWorking, let request, let controller else { return }
        isWorking = true
        errorMessage = nil
        await perform { [self] token, flow in
            try await controller.acknowledgeVerificationRequest(senderId: request.userID, flowId: request.flowID)
            guard isCurrent(token, flow) else { return }
            acceptedByUser = true
            try await controller.acceptVerificationRequest()
            if isCurrent(token, flow), phase == .incoming { phase = .ready }
        }
    }

    func startComparison() async {
        guard phase == .ready, !isWorking, let controller else { return }
        isWorking = true
        phase = .exchanging
        errorMessage = nil
        await perform { _, _ in try await controller.startSasVerification() }
    }

    func confirmMatch() async {
        guard phase == .comparison, acceptedByUser, !isWorking, let controller,
            Self.validComparison(emojiCount: emojis.count, decimals: decimals)
        else { return }
        confirmedByUser = true
        isWorking = true
        phase = .awaitingConfirmation
        errorMessage = nil
        await perform { _, _ in try await controller.approveVerification() }
    }

    func rejectMismatch() async {
        guard phase == .comparison, !isWorking, let controller else { return }
        isWorking = true
        await perform { [self] token, flow in
            try await controller.declineVerification()
            guard isCurrent(token, flow), phase != .finished else { return }
            clearComparison()
            phase = .cancelled
            errorMessage = "The codes did not match. Verification was stopped."
            beginCleanup(terminal: .cancelled)
        }
    }

    func cancel() async {
        beginCleanup(terminal: .cancelled)
    }

    func dismiss() {
        if phase.isActive || isWorking || phase == .preparing || cleanupController != nil {
            beginCleanup(terminal: .cancelled)
        }
        clearComparison()
        isPresented = false
    }

    static func validComparison(emojiCount: Int, decimals: [UInt16]) -> Bool {
        (emojiCount == 7 && decimals.isEmpty)
            || (emojiCount == 0 && decimals.count == 3 && decimals.allSatisfy { (1000...9191).contains($0) })
    }

    private enum VerificationError: LocalizedError {
        case signedOut, noOtherDevice, replaced
        var errorDescription: String? {
            switch self {
            case .signedOut: "Sign in to verify this session."
            case .noOtherDevice: "No other verified device found. Use your recovery key instead."
            case .replaced: "The signed-in session changed. Open verification again."
            }
        }
    }

    private func ensureController(token: UUID) async throws -> SessionVerificationController {
        if let controller { return controller }
        guard let client else { throw VerificationError.signedOut }
        if controllerTask == nil { controllerTask = Task { try await client.getSessionVerificationController() } }
        guard let lookup = controllerTask else { throw VerificationError.replaced }
        let next: SessionVerificationController
        do { next = try await lookup.value } catch {
            if generation == token { controllerTask = nil }
            throw error
        }
        guard generation == token, !isCleaningUp else { throw VerificationError.replaced }
        controllerTask = nil
        if let controller { return controller }
        controller = next
        installObserver(token: token, flow: flowGeneration)
        isAvailable = true
        return next
    }

    private func installObserver(token: UUID, flow: UUID) {
        let observer = VerificationObserver { [weak self] event in
            Task { @MainActor [weak self] in
                self?.dispatch(event, token: token, flow: flow)
            }
        }
        self.observer = observer
        controller?.setDelegate(delegate: observer)
    }

    private func rotateFlowObserver() {
        flowGeneration = UUID()
        installObserver(token: generation, flow: flowGeneration)
    }

    private func isCurrent(_ token: UUID, _ flow: UUID) -> Bool {
        generation == token && flowGeneration == flow && !Task.isCancelled && !isCleaningUp
    }

    private func dispatch(_ event: VerificationObserver.Event, token: UUID, flow: UUID) {
        guard generation == token, flowGeneration == flow, !isCleaningUp else { return }
        receive(event)
    }

    private func perform(_ action: @escaping @MainActor (UUID, UUID) async throws -> Void) async {
        let token = generation
        let flow = flowGeneration
        let task = Task { [weak self] in
            guard let self, self.isCurrent(token, flow) else { return }
            do { try await action(token, flow) } catch {
                if self.isCurrent(token, flow) { self.fail(error, token: token) }
            }
            if self.isCurrent(token, flow) {
                self.isWorking = false
                self.operationTask = nil
            }
        }
        operationTask = task
        await task.value
    }

    private func beginCleanup(terminal: Phase) {
        guard !isCleaningUp else { return }
        let pending = operationTask
        let oldController = cleanupController ?? controller
        let incoming = request
        flowGeneration = UUID()
        controller?.setDelegate(delegate: nil)
        observer = nil
        pending?.cancel()
        operationTask = nil
        clearComparison()
        isWorking = false
        guard oldController != nil || pending != nil else {
            phase = terminal
            return
        }
        isCleaningUp = true
        cleanupController = oldController
        phase = terminal == .failed ? .failed : .cancelling
        let token = generation
        cleanupTask = Task { [weak self] in
            // UniFFI does not cancel Rust futures when Swift Tasks are cancelled. Wait before cancelling the native
            // flow or allowing another request.
            await pending?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            do {
                if let oldController {
                    if let incoming {
                        // This can already be acknowledged by the in-flight accept operation.
                        do {
                            try await oldController.acknowledgeVerificationRequest(
                                senderId: incoming.userID, flowId: incoming.flowID)
                        } catch {}
                    }
                    do { try await oldController.cancelVerification() } catch {
                        guard let sdkError = error as? ClientError, case .Generic(let message, _) = sdkError,
                            message.lowercased().contains("verification request missing")
                        else { throw error }
                    }
                }
                guard self.generation == token, !Task.isCancelled else { return }
                self.cleanupController = nil
                self.isCleaningUp = false
                self.cleanupTask = nil
                if self.phase == .cancelling { self.phase = terminal }
                self.rotateFlowObserver()
                if self.controller == nil, !self.isPresented { self.scheduleAttachRetries(token: token) }
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.isCleaningUp = false
                self.cleanupTask = nil
                self.phase = .failed
                self.errorMessage =
                    "Couldn’t cancel the previous request. Try cancelling again."
            }
        }
    }

    private func scheduleAttachRetries(token: UUID) {
        attachRetryTask?.cancel()
        attachRetryTask = Task { [weak self] in
            for attempt in 0..<8 {
                guard let self, self.generation == token, !Task.isCancelled,
                    !self.phase.isActive, self.phase == .idle || !self.isPresented, !self.isWorking, !self.isCleaningUp
                else { return }
                do {
                    _ = try await self.ensureController(token: token)
                    return
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    if attempt == 7 {
                        self.errorMessage =
                            "Verification isn’t ready yet. Try again in a moment."
                        return
                    }
                    do { try await Task.sleep(for: .seconds(min(1 << min(attempt, 3), 8))) } catch { return }
                }
            }
        }
    }

    private func receive(_ event: VerificationObserver.Event) {
        switch event {
        case .request(let details):
            guard !phase.isActive, !isWorking else { return }
            guard cleanupController == nil else { return }
            rotateFlowObserver()
            request = Request(
                userID: details.senderProfile.userId,
                name: details.senderProfile.displayName ?? details.senderProfile.userId, deviceID: details.deviceId,
                deviceName: details.deviceDisplayName, flowID: details.flowId,
                firstSeen: Date(timeIntervalSince1970: Double(details.firstSeenTimestamp) / 1000))
            clearComparison()
            errorMessage = nil
            phase = .incoming
            isPresented = true
        case .accepted:
            guard acceptedByUser, [.requesting, .waitingForOtherDevice, .incoming].contains(phase) else { return }
            phase = .ready
        case .started:
            guard acceptedByUser, phase.isActive, phase != .comparison, phase != .awaitingConfirmation else { return }
            phase = .exchanging
        case .data(let data):
            guard acceptedByUser, phase.isActive, phase != .awaitingConfirmation else { return }
            switch data {
            case .emojis(let values, _):
                emojis = values.enumerated().map {
                    Emoji(id: $0.offset, symbol: $0.element.symbol(), name: $0.element.description())
                }
                decimals = []
            case .decimals(let values):
                decimals = values
                emojis = []
            }
            guard Self.validComparison(emojiCount: emojis.count, decimals: decimals) else {
                clearComparison()
                phase = .failed
                errorMessage = "Couldn’t verify this device. Try again."
                beginCleanup(terminal: .failed)
                return
            }
            phase = .comparison
        case .finished:
            // Finished counts only after the person confirmed the codes match.
            guard confirmedByUser, phase == .awaitingConfirmation else { return }
            clearComparison()
            phase = .finished
        case .cancelled:
            guard phase.isActive else { return }
            clearComparison()
            phase = .cancelled
            errorMessage = "Verification was cancelled or timed out. Try again."
            beginCleanup(terminal: .cancelled)
        case .failed:
            guard phase.isActive else { return }
            clearComparison()
            phase = .failed
            errorMessage = "Verification failed. Start again from the other device."
            beginCleanup(terminal: .failed)
        }
    }

    private func updateDeviceStatus(_ state: VerificationState) {
        switch state {
        case .unknown: deviceStatus = .unknown
        case .verified: deviceStatus = .verified
        case .unverified: deviceStatus = .unverified
        }
    }

    private func clearComparison() {
        emojis = []
        decimals = []
        acceptedByUser = false
        confirmedByUser = false
    }
    private func fail(_ error: Error, token: UUID) {
        guard generation == token else { return }
        clearComparison()
        phase = .failed
        errorMessage =
            (error as? VerificationError)?.localizedDescription
            ?? "Verification failed. Check your connection and try again."
        beginCleanup(terminal: .failed)
    }
}
