import AVFoundation
import Foundation

/// The one video a window plays in its timeline, as Slack desktop plays one at a time: starting another stops it. Its
/// file downloads whole first, as the viewer's does, since an encrypted video can't stream.
@Observable @MainActor final class InlineVideo {
    /// The message playing, or about to once its file is down.
    private(set) var eventID: String?
    /// Its player, once the file is ready; the only one the window has.
    private(set) var player: AVPlayer?
    @ObservationIgnored private var owner: ObjectIdentifier?
    @ObservationIgnored private var lease: AttachmentPreviewLease?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Plays `message` in the timeline `owner` shows, stopping whatever played before.
    func play(_ message: ChatMessage, matrix: MatrixService, from owner: AnyObject) {
        stop()
        let eventID = message.eventID
        let session = matrix.notificationSessionID
        self.eventID = eventID
        self.owner = ObjectIdentifier(owner)
        loading = Task { [weak self] in
            do {
                let lease = try await matrix.prepareAttachmentPreview(message)
                guard let self, !Task.isCancelled, self.eventID == eventID else { return }
                self.lease = lease
                let player = AVPlayer(url: lease.url)
                self.player = player
                player.play()
            } catch {
                guard let self, !Task.isCancelled, self.eventID == eventID else { return }
                self.stop()
                if !(error is CancellationError), matrix.notificationSessionID == session {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }

    func stop() {
        loading?.cancel()
        loading = nil
        player?.pause()
        player = nil
        lease = nil
        eventID = nil
        owner = nil
    }

    /// Stops it if it plays in the timeline `owner` shows, as that timeline closes.
    func stop(from owner: AnyObject) {
        if self.owner == ObjectIdentifier(owner) { stop() }
    }
}
