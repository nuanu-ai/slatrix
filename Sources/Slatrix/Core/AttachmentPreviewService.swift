import Foundation
import MatrixRustSDK

/// A downloaded attachment for Quick Look or saving. Valid while its message still shows the same file.
@MainActor
final class AttachmentPreviewLease {
    let url: URL
    /// Keeps the SDK's temporary file alive; nil for the sample workspace's files.
    private let handle: MediaFileHandle?
    private let validator: @MainActor () -> Bool
    var isCurrent: Bool { validator() }

    init(url: URL, handle: MediaFileHandle?, isCurrent: @escaping @MainActor () -> Bool) {
        self.url = url
        self.handle = handle
        validator = isCurrent
    }
}

/// Temporary attachment files, reused until the timeline that showed them closes.
@MainActor
final class MediaFileCache {
    private var files: [String: AttachmentPreviewLease] = [:]
    private var loads: [String: Task<AttachmentPreviewLease, Error>] = [:]

    func file(
        source: MediaSource, identity: String, attachment: MessageAttachment, client: Client,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> AttachmentPreviewLease {
        let key = identity
        if let file = files[key], file.isCurrent, FileManager.default.fileExists(atPath: file.url.path) { return file }
        if let load = loads[key] { return try await load.value }
        let load = Task { @MainActor in
            try Task.checkCancellation()
            let handle = try await client.getMediaFile(
                mediaSource: source, filename: SharedContentMapping.safeFilename(attachment.name),
                mimeType: attachment.mimeType ?? "application/octet-stream", useCache: false, tempDir: nil)
            let url = URL(fileURLWithPath: try handle.path())
            guard url.isFileURL else {
                throw MatrixServiceError.request("This attachment does not have a local preview file.")
            }
            return AttachmentPreviewLease(url: url, handle: handle, isCurrent: isCurrent)
        }
        loads[key] = load
        defer { if loads[key] == load { loads[key] = nil } }
        let file = try await load.value
        guard file.isCurrent else { throw CancellationError() }
        files[key] = file
        return file
    }

    func removeAll() {
        for item in loads.values { item.cancel() }
        loads = [:]
        files = [:]
    }
}
