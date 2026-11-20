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
