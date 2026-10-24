import Foundation

@MainActor final class AttachmentPreviewController: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    private var lease: AttachmentPreviewLease?
    private var sessionID: UUID?
    private var request = UUID()

    func setSession(_ value: UUID) {
        guard sessionID != value else { return }
        close()
        sessionID = value
    }

    func show(sessionID: UUID, load: @MainActor () async throws -> AttachmentPreviewLease) async throws {
        guard self.sessionID == sessionID else { throw CancellationError() }
        guard !isLoading else {
            throw MatrixServiceError.request(
                "Another attachment is being prepared. Wait for it to finish or cancel the preview.")
        }
        close()
        let token = UUID()
        request = token
        isLoading = true
        defer { if request == token { isLoading = false } }
        do {
            let prepared = try await load()
            guard request == token, self.sessionID == sessionID, !Task.isCancelled, prepared.isCurrent else {
                throw CancellationError()
            }
            lease = prepared
            url = prepared.url
        } catch {
            guard request == token, self.sessionID == sessionID else { throw CancellationError() }
            throw error
        }
    }

    func presentationChanged(_ value: URL?) {
        if value == nil { close() }
    }
    /// Closes Quick Look once its message is deleted, edited to another file, or leaves the open timeline.
    func invalidateIfNeeded() {
        if let lease, !lease.isCurrent { close() }
    }
    func close() {
        request = UUID()
        url = nil
        lease = nil
        isLoading = false
    }
}
