import AVFoundation
import Foundation

/// The one audio or voice clip a window plays at a time, as Slack desktop plays one clip at a time:
/// starting another stops the previous one. Its file downloads whole first so encrypted audio decrypts.
@Observable @MainActor final class InlineAudio {
    private(set) var eventID: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var errorEventID: String?
    private(set) var errorMessage: String?

    private var owner: ObjectIdentifier?
    /// Monotonic token so a cancelled or superseded download/duration load can never take over playback.
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored var onWillPlay: (() -> Void)?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var lease: AttachmentPreviewLease?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var failureObserver: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    @MainActor struct Slot {
        let audio: InlineAudio
        let message: ChatMessage
        let matrix: MatrixService
        let owner: AnyObject

        var isCurrent: Bool { audio.eventID == message.eventID && audio.owner == ObjectIdentifier(owner) }
        var isPlaying: Bool { isCurrent && audio.isPlaying }
        var isLoading: Bool { isCurrent && audio.isLoading }
        var currentTime: TimeInterval { isCurrent ? audio.currentTime : 0 }
        var duration: TimeInterval {
            if isCurrent && audio.duration > 0 { return audio.duration }
            return message.attachment?.duration ?? 0
        }
        var error: String? { audio.errorEventID == message.eventID ? audio.errorMessage : nil }

        func toggle() { audio.toggle(message, matrix: matrix, from: owner) }
        func play(from fraction: Double) { audio.play(message, matrix: matrix, from: owner, startFraction: fraction) }
        func seek(to fraction: Double) {
            if isCurrent {
                audio.seek(to: fraction)
            } else {
                audio.play(message, matrix: matrix, from: owner, startFraction: fraction)
            }
        }
        func step(by seconds: TimeInterval) {
            guard isCurrent, duration > 0 else { return }
            audio.seek(to: (currentTime + seconds) / duration)
        }
    }

    func slot(_ message: ChatMessage, matrix: MatrixService, in owner: AnyObject) -> Slot {
        Slot(audio: self, message: message, matrix: matrix, owner: owner)
    }

    func toggle(_ message: ChatMessage, matrix: MatrixService, from owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)
        if eventID == message.eventID, self.owner == ownerID, let player {
            if isPlaying {
                player.pause()
                isPlaying = false
            } else {
                onWillPlay?()
                if duration > 0, currentTime >= duration - 0.1 {
                    player.seek(to: .zero)
                    currentTime = 0
                }
                player.play()
                isPlaying = true
            }
            return
        }
        play(message, matrix: matrix, from: owner)
    }

    func play(
        _ message: ChatMessage, matrix: MatrixService, from owner: AnyObject, startFraction: Double? = nil
    ) {
        onWillPlay?()
        stop()
        let token = UUID()
        requestID = token
        let eventID = message.eventID
        let session = matrix.notificationSessionID
        self.eventID = eventID
        self.owner = ObjectIdentifier(owner)
        self.duration = message.attachment?.duration ?? 0
        self.isLoading = true
        self.errorEventID = nil
        self.errorMessage = nil

        loading = Task { [weak self] in
            do {
                let lease = try await matrix.prepareAttachmentPreview(message)
                guard let self, !Task.isCancelled, self.requestID == token, self.eventID == eventID else { return }
                let player = AVPlayer(url: lease.url)
                var resolvedDuration = self.duration
                if let asset = player.currentItem?.asset,
                    let loaded = try? await asset.load(.duration),
                    loaded.isNumeric, loaded.seconds > 0
                {
                    resolvedDuration = loaded.seconds
                }
                // Unconditionally re-verify ownership after every suspension point so a cancelled task never starts.
                guard !Task.isCancelled, self.requestID == token, self.eventID == eventID else { return }
                self.lease = lease
                self.player = player
                self.duration = resolvedDuration
                self.isLoading = false
                if let startFraction, resolvedDuration > 0 {
                    let clamped = min(max(startFraction, 0), 1)
                    let seconds = clamped * resolvedDuration
                    self.currentTime = seconds
                    let target = CMTime(seconds: seconds, preferredTimescale: 600)
                    await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                    guard !Task.isCancelled, self.requestID == token, self.eventID == eventID else { return }
                }
                self.installObservers(for: player, token: token, eventID: eventID, session: session, matrix: matrix)
                player.play()
                self.isPlaying = true
            } catch {
                guard let self, !Task.isCancelled, self.requestID == token, self.eventID == eventID else { return }
                self.stop()
                if !(error is CancellationError), matrix.notificationSessionID == session {
                    self.errorEventID = eventID
                    self.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }

    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let seconds = clamped * duration
        currentTime = seconds
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        requestID = UUID()
        loading?.cancel()
        loading = nil
        removeObservers()
        player?.pause()
        player = nil
        lease = nil
        eventID = nil
        owner = nil
        isPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
    }

    func stop(from owner: AnyObject) {
        if self.owner == ObjectIdentifier(owner) { stop() }
    }

    private func installObservers(
        for player: AVPlayer, token: UUID, eventID: String, session: UUID, matrix: MatrixService
    ) {
        removeObservers()
        let interval = CMTime(seconds: 0.15, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player, self.requestID == token, self.player === player, time.isNumeric else {
                    return
                }
                self.currentTime = max(0, time.seconds)
                if let itemDuration = player.currentItem?.duration, itemDuration.isNumeric, itemDuration.seconds > 0 {
                    self.duration = itemDuration.seconds
                }
            }
        }
        failureObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) {
            [weak self, weak player] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, let player, self.requestID == token, self.player === player else { return }
                self.stop()
                if matrix.notificationSessionID == session {
                    self.errorEventID = eventID
                    self.errorMessage = "This audio can’t be played here."
                }
            }
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, weak player] _ in
                MainActor.assumeIsolated {
                    guard let self, let player, self.requestID == token, self.player === player else { return }
                    self.isPlaying = false
                    self.currentTime = 0
                    player.seek(to: .zero)
                }
            }
        }
    }

    private func removeObservers() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        failureObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}
