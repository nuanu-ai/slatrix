import Foundation

@testable import Slatrix

nonisolated(unsafe) private var scratchFolderKey: UInt8 = 0

extension MatrixService {
    /// A service whose credentials and SDK stores live in a folder of its own, so signing in or out never touches
    /// the development build's session. The folder goes when the service does.
    static func scratch() -> MatrixService {
        let folder = try! TemporaryDirectory()
        let service = MatrixService(
            credentials: SecureSessionStore(file: folder.path("credentials.json")),
            storeRoots: [folder.path("support"), folder.path("caches")])
        objc_setAssociatedObject(service, &scratchFolderKey, folder, .OBJC_ASSOCIATION_RETAIN)
        return service
    }
}

extension RootView {
    /// The window with its drafts vault and attachment drafts in the service's scratch folder, beside its credentials.
    @MainActor init(scratch matrix: MatrixService) {
        let folder = objc_getAssociatedObject(matrix, &scratchFolderKey) as! TemporaryDirectory
        let credentials = matrix.credentials
        let key: @Sendable (String) async throws -> Data = { try credentials.localStateKey(accountID: $0) }
        self.init(
            matrix: matrix,
            localStore: ProtectedLocalStateStore(
                directory: ProtectedLocalStateStore.directory(in: folder.url), keyProvider: key),
            attachmentDrafts: AttachmentDraftStore(
                directory: AttachmentDraftStore.directory(in: folder.url), keyProvider: key))
    }
}
