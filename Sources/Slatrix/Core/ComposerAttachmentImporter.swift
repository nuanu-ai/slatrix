import AppKit
import Darwin
import Foundation
import ImageIO

enum ComposerAttachmentInput: Sendable {
    case files([URL])
    case image(Data, png: Bool)
    /// Files another app writes only when asked, as Photos, Mail and browsers offer them in a drag.
    case promises(FilePromises)

    /// What a paste or a drop attaches: its files, else its image's data; nil when it holds neither.
    init?(pasteboard: NSPasteboard) {
        let files =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            self = .files(files)
        } else if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type) {
            self = .image(data, png: type == .png)
        } else if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver], !promises.isEmpty
        {
            self = .promises(FilePromises(receivers: promises))
        } else {
            return nil
        }
    }
}

/// AppKit's receivers aren't Sendable; only the main actor touches them.
struct FilePromises: @unchecked Sendable {
    let receivers: [NSFilePromiseReceiver]
}

enum ComposerAttachmentImporter {
    static let maximumFileBytes = 100 * 1_024 * 1_024
    static let maximumQueueBytes = 250 * 1_024 * 1_024
    static let maximumImageBytes = 25 * 1_024 * 1_024
    static let maximumFiles = 20
    private static var directory: URL {
        AppPaths.temporary.appendingPathComponent("QueuedAttachments", isDirectory: true)
    }
    private static let session = Result { try Session(in: directory) }

    final class Session {
        let directory: URL
        private let descriptor: Int32

        init(in base: URL) throws {
            try ensurePrivateDirectory(base)
            let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let lease = folder.appendingPathComponent(".lease")
            let descriptor = open(lease.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
            var succeeded = false
            defer {
                if !succeeded {
                    if descriptor >= 0 { close(descriptor) }
                    try? FileManager.default.removeItem(at: folder)
                }
            }
            guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw Failure(message: "Couldn’t attach the file. Try again.")
            }
            // Acquire the lease before publishing its valid marker, so cleanup never removes a session being created.
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            try handle.write(contentsOf: marker(for: folder))
            self.directory = folder
            self.descriptor = descriptor
            succeeded = true
        }

        deinit { close(descriptor) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `promiseDeadline` is how long another app may take to write promised files.
    static func stage(_ input: ComposerAttachmentInput, existing: [URL], promiseDeadline: Duration = .seconds(30))
        async throws -> [URL]
    {
        try Task.checkCancellation()
        if case .promises(let promises) = input {
            let folder = try newFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            return try await stage(
                .files(receive(promises, into: folder, deadline: promiseDeadline)), existing: existing)
        }
        let worker = Task.detached(priority: .userInitiated) { try prepare(input, existing: existing) }
        let staged = try await withTaskCancellationHandler(
            operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled else {
            discard(staged)
            throw CancellationError()
        }
        return staged
    }

    /// Restored plaintext has the same lease and cleanup rules as a newly queued file.
    static func stageRestoredData(_ data: Data, filename: String) throws -> URL {
        try Task.checkCancellation()
        guard data.count <= maximumFileBytes, !filename.isEmpty, filename != ".", filename != "..",
            !filename.contains("/"),
            filename.utf8.count <= 1_024, filename.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw Failure(
                message: "A saved attachment is damaged.")
        }
        let folder = try newFolder()
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let url = folder.appendingPathComponent(filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else {
            throw Failure(
                message: "Couldn’t restore a saved attachment. Check disk space and try again.")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try Task.checkCancellation()
        succeeded = true
        return url
    }

    static func validateQueue(_ urls: [URL]) throws {
        guard urls.count <= maximumFiles else { throw Failure(message: "Attach up to 20 files at a time.") }
        var bytes = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let descriptor = try openFile(url)
            defer { close(descriptor) }
            let info = try metadata(descriptor)
            guard info.st_size <= maximumFileBytes else {
                throw Failure(message: "Each attachment must be 100 MiB or smaller.")
            }
            bytes += Int(info.st_size)
            guard bytes <= maximumQueueBytes else { throw Failure(message: "Attachments must total 250 MiB or less.") }
        }
    }

    // Only remove this process's UUID attachment directories, never originals or another live session.
    static func discard(_ urls: [URL]) {
        for folder in Set(urls.map { $0.deletingLastPathComponent() }) where isStagingFolder(folder) {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// A queued image as the tray shows it, at most `pixels` on its longer side. Only a staged copy is read, so the
    /// tray never touches the original or the network.
    static func thumbnail(of url: URL, pixels: Int) -> CGImage? {
        guard url.isFileURL, isStagingFolder(url.deletingLastPathComponent()),
            let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
    }

    private static func isStagingFolder(_ folder: URL) -> Bool {
        guard let active = try? session.get() else { return false }
        return folder.deletingLastPathComponent().standardizedFileURL == active.directory.standardizedFileURL
            && UUID(uuidString: folder.lastPathComponent) != nil && ownedDirectory(folder)
    }

    @discardableResult static func cleanupOrphans() -> Int { cleanupOrphans(in: directory) }

    private static func marker(for folder: URL) -> Data {
        Data("SlatrixQueuedAttachments-v1\n\(folder.lastPathComponent)\n".utf8)
    }

    private static func ownedDirectory(_ folder: URL) -> Bool {
        var info = stat()
        return lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o777 == 0o700
    }

    private static func ensurePrivateDirectory(_ folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard ownedDirectory(folder) else {
            throw Failure(message: "Couldn’t attach the file. Try again.")
        }
    }

    private static func validMarker(_ descriptor: Int32, in folder: URL) -> Bool {
        let expected = marker(for: folder)
        var info = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_mode & 0o777 == 0o600,
            info.st_nlink == 1, info.st_size == expected.count,
            lstat(folder.appendingPathComponent(".lease").path, &pathInfo) == 0,
            pathInfo.st_ino == info.st_ino, pathInfo.st_dev == info.st_dev
        else { return false }
        var bytes = [UInt8](repeating: 0, count: expected.count)
        let count = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, expected.count, 0) }
        return count == expected.count && Data(bytes) == expected
    }

    static func cleanupOrphans(in base: URL) -> Int {
        guard ownedDirectory(base),
            let candidates = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        else { return 0 }
        var removed = 0
        for folder in candidates where UUID(uuidString: folder.lastPathComponent) != nil && ownedDirectory(folder) {
            let descriptor = open(
                folder.appendingPathComponent(".lease").path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0, ownedDirectory(folder), validMarker(descriptor, in: folder)
            else { continue }
            do {
                try FileManager.default.removeItem(at: folder)
                removed += 1
            } catch {}
        }
        return removed
    }

    private static func prepare(_ input: ComposerAttachmentInput, existing: [URL]) throws -> [URL] {
        try Task.checkCancellation()
        try validateQueue(existing)
        let files: [URL]
        switch input {
        case .files(let urls):
            var seen = Set<URL>()
            files = urls.filter { seen.insert($0).inserted }
        case .image, .promises: files = []
        }
        let count: Int
        if case .image = input { count = 1 } else { count = files.count }
        guard count > 0 else { throw Failure(message: "No readable files were found to attach.") }
        guard existing.count + count <= maximumFiles else { throw Failure(message: "Attach up to 20 files at a time.") }
        var folders: [URL] = []
        var result: [URL] = []
        var succeeded = false
        defer { if !succeeded { for folder in folders { try? FileManager.default.removeItem(at: folder) } } }
        func destination(_ name: String) throws -> URL {
            let folder = try newFolder()
            folders.append(folder)
            return folder.appendingPathComponent(name)
        }
        switch input {
        case .files, .promises:
            for source in files {
                try Task.checkCancellation()
                let output = try destination(source.lastPathComponent)
                try copy(source, to: output)
                result.append(output)
                try validateQueue(existing + result)
            }
        case .image(let data, let png):
            guard data.count <= maximumImageBytes else {
                throw Failure(message: "Pasted images must be 25 MiB or smaller.")
            }
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
                (CGImageSourceGetType(source) as String?) == (png ? "public.png" : "public.tiff"),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
                let width = properties[kCGImagePropertyPixelWidth] as? Int,
                let height = properties[kCGImagePropertyPixelHeight] as? Int,
                width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 64_000_000
            else {
                throw Failure(message: "Couldn’t attach this image. Use a PNG or TIFF up to 64 megapixels.")
            }
            let output = try destination(png ? "Pasted image.png" : "Pasted image.tiff")
            guard
                FileManager.default.createFile(
                    atPath: output.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { throw Failure(message: "Couldn’t paste the image. Attach it as a file instead.") }
            result.append(output)
            try validateQueue(existing + result)
        }
        try Task.checkCancellation()
        succeeded = true
        return result
    }

    /// A new private folder in this session's staging area.
    private static func newFolder() throws -> URL {
        let folder = try session.get().directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Asks the apps behind `promises` to write their files into `folder`, and returns them once all are written.
    /// Only a file written straight into `folder` counts, so a promise can't point at any other file. Missing the
    /// deadline, or being cancelled, drops the whole drop.
    @MainActor private static func receive(_ promises: FilePromises, into folder: URL, deadline: Duration)
        async throws -> [URL]
    {
        let wait = PromiseWait(remaining: promises.receivers.reduce(0) { $0 + $1.fileTypes.count })
        guard wait.remaining > 0 else { return [] }
        let expected = folder.resolvingSymlinksInPath()
        let timer = Task { @MainActor in
            try await Task.sleep(for: deadline)
            wait.finish(.failure(Failure(message: "A dropped file never arrived. Drop it again.")))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.continuation = continuation
                for promise in promises.receivers {
                    promise.receivePromisedFiles(atDestination: folder, operationQueue: .main) { url, error in
                        MainActor.assumeIsolated {
                            let inside = url.deletingLastPathComponent().resolvingSymlinksInPath() == expected
                            wait.arrived(error == nil && inside ? url : nil)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in wait.finish(.failure(CancellationError())) }
        }
    }

    /// Promised files as they arrive, and the one place waiting for them ends.
    @MainActor private final class PromiseWait {
        var continuation: CheckedContinuation<[URL], Error>?
        private(set) var remaining: Int
        private var files: [URL] = []
        private var failed = false

        init(remaining: Int) { self.remaining = remaining }

        /// One promised file written, or nil when it failed or landed outside our folder.
        func arrived(_ file: URL?) {
            guard remaining > 0 else { return }
            if let file { files.append(file) } else { failed = true }
            remaining -= 1
            guard remaining == 0 else { return }
            finish(failed ? .failure(Failure(message: "Couldn’t read a file. Attach it again.")) : .success(files))
        }

        func finish(_ result: Result<[URL], Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private static func openFile(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw Failure(message: "Only local files can be attached.") }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw Failure(message: "Couldn’t read a file. Attach it again.")
        }
        return descriptor
    }

    private static func metadata(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw Failure(message: "Only files can be attached, not folders.")
        }
        return info
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let descriptor = try openFile(source)
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        let before = try metadata(descriptor)
        guard before.st_size <= maximumFileBytes else {
            throw Failure(message: "Each attachment must be 100 MiB or smaller.")
        }
        guard
            FileManager.default.createFile(
                atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw Failure(message: "Couldn’t attach the file. Try again.") }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var bytes = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else { break }
            bytes += chunk.count
            guard bytes <= maximumFileBytes else {
                throw Failure(message: "Each attachment must be 100 MiB or smaller.")
            }
            try output.write(contentsOf: chunk)
        }
        let after = try metadata(descriptor)
        guard bytes == before.st_size, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else {
            throw Failure(message: "A file changed while being prepared. Attach it again.")
        }
    }
}
