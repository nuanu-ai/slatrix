import CryptoKit
import Darwin
import Foundation

struct AttachmentDraftAddress: Hashable, Codable, Sendable {
    let roomID: String
    var threadRootID: String? = nil
    var id: String { "\(roomID.utf8.count):\(roomID)\(threadRootID ?? "")" }
}

struct AttachmentDraftAccess: Sendable {
    let accountID: String
    let generation: UUID
    var warningMessage: String? = nil
}

enum AttachmentDraftPhase: String, Sendable { case ready, interrupted }

struct AttachmentDraftFile: Identifiable, Sendable {
    let id: String
    let filename: String
    let byteCount: Int
    let url: URL?
    let phase: AttachmentDraftPhase
    let errorMessage: String?
}

struct AttachmentDraftQueue: Sendable {
    let address: AttachmentDraftAddress
    let revision: UInt64
    let files: [AttachmentDraftFile]
}

enum AttachmentDraftError: LocalizedError, Equatable {
    case invalidData, unavailable, staleAccess, staleRevision, inUse, budget, invalidFile, changedFile
    var errorDescription: String? {
        switch self {
        case .invalidData:
            return
                "Couldn’t open saved attachments. Attach the files again."
        case .unavailable:
            return
                "Couldn’t save attachments. Check disk space and try again."
        case .staleAccess:
            return "You signed in again. Reopen the conversation."
        case .staleRevision: return "A newer draft was already saved."
        case .inUse:
            return "Slatrix is already open. Quit the other copy and try again."
        case .budget:
            return
                "Saved attachments are limited to 512 MiB per account, 250 MiB per conversation draft, and 100 MiB per file. Remove an attachment before adding more."
        case .invalidFile:
            return "Couldn’t attach a file. Choose it again."
        case .changedFile:
            return "A file changed while it was being attached. Choose it again."
        }
    }
}

/// Crypto and filesystem work is synchronous on this actor's background executor: one file at a time.
actor AttachmentDraftStore {
    static let shared = AttachmentDraftStore()
    static let maximumAccountBytes = 512 * 1_024 * 1_024
    private static let maximumManifestBytes = 4 * 1_024 * 1_024
    private let directory: URL
    private let budgetBytes: Int
    private let keyProvider: @Sendable (String) async throws -> Data
    private let fault: (@Sendable (FaultPoint) throws -> Void)?
    enum FaultPoint: Sendable, Equatable { case beforeManifestCommit, afterManifestRename }

    private enum StoredPhase: String, Codable { case ready, sending }
    private struct Entry: Codable, Equatable {
        var id: String
        var filename: String
        var byteCount: Int
        var digest: String
        var phase: StoredPhase = .ready
    }
    private struct Queue: Codable, Equatable {
        var address: AttachmentDraftAddress
        var revision: UInt64
        var files: [Entry]
    }
    private struct Manifest: Codable, Equatable {
        var version = 1
        var queues: [String: Queue] = [:]
    }
    private final class Lease {
        let directory: URL
        private let descriptor: Int32
        init(directory: URL) throws {
            self.directory = directory
            try AttachmentDraftStore.prepareDirectory(directory)
            let descriptor = Darwin.open(
                directory.appendingPathComponent(".lease").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw AttachmentDraftError.unavailable }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                info.st_mode & 0o777 == 0o600, info.st_nlink == 1
            else {
                Darwin.close(descriptor)
                throw AttachmentDraftError.invalidData
            }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                throw AttachmentDraftError.inUse
            }
            self.descriptor = descriptor
        }
        deinit { Darwin.close(descriptor) }
    }
    private struct Record {
        var generation: UUID
        var key: Data
        var manifest: Manifest
        var lease: Lease
        var urls: [String: URL] = [:]
        var completedURLs: [String: Set<URL>] = [:]
    }
    private var records: [String: Record] = [:]
    private var opening: [String: UUID] = [:]

    init(
        directory: URL? = nil, budgetBytes: Int = AttachmentDraftStore.maximumAccountBytes,
        keyProvider: @escaping @Sendable (String) async throws -> Data = { account in
            try await Task.detached(priority: .userInitiated) {
                try SecureSessionStore.localStateKey(accountID: account)
            }.value
        }, fault: (@Sendable (FaultPoint) throws -> Void)? = nil
    ) {
        self.directory =
            directory ?? AppPaths.applicationSupport.appendingPathComponent("AttachmentDrafts", isDirectory: true)
        self.budgetBytes = budgetBytes
        self.keyProvider = keyProvider
        self.fault = fault
    }

    func open(accountID: String) async throws -> AttachmentDraftAccess {
        guard SecureSessionStore.validAccountID(accountID) else { throw AttachmentDraftError.invalidData }
        let generation = UUID()
        opening[accountID] = generation
        let key = try await keyProvider(accountID)
        guard opening[accountID] == generation else { throw AttachmentDraftError.staleAccess }
        try Task.checkCancellation()
        guard key.count == 32 else { throw AttachmentDraftError.invalidData }
        try Self.prepareDirectory(directory)
        let previous = records[accountID]
        guard previous == nil || previous?.key == key else { throw AttachmentDraftError.invalidData }
        let lease = try previous?.lease ?? Lease(directory: accountDirectory(accountID))
        let manifestURL = lease.directory.appendingPathComponent("manifest.vault")
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            // Establish an empty manifest before any blob exists; a later missing manifest is never a reset.
            let contents = try FileManager.default.contentsOfDirectory(
                at: lease.directory, includingPropertiesForKeys: nil)
            guard contents.allSatisfy({ $0.lastPathComponent == ".lease" }) else {
                throw AttachmentDraftError.invalidData
            }
            let encrypted = try seal(
                JSONEncoder().encode(Manifest()), key: key, authentication: manifestAuthentication(accountID),
                magic: "ELADM01\n")
            try ensureBudget(extra: encrypted.count, directory: lease.directory)
            try writeAtomic(encrypted, to: manifestURL)
        }
        let manifest = try loadManifest(directory: lease.directory, key: key, accountID: accountID)
        try validate(manifest)
        if let previous { ComposerAttachmentImporter.discard(Array(previous.urls.values)) }
        records[accountID] = Record(generation: generation, key: key, manifest: manifest, lease: lease)
        let warning = reapOrphans(record: records[accountID]!, accountID: accountID)
        if Task.isCancelled {
            records[accountID] = nil
            throw CancellationError()
        }
        return AttachmentDraftAccess(accountID: accountID, generation: generation, warningMessage: warning)
    }

    /// Returned plaintext URLs are owned by this access; close() and discardStaged() clean them.
    func restore(access: AttachmentDraftAccess) throws -> [AttachmentDraftQueue] {
        var record = try current(access)
        try checkDiskManifest(record, accountID: access.accountID)
        ComposerAttachmentImporter.discard(Array(record.urls.values))
        record.urls = [:]
        records[access.accountID] = record
        var succeeded = false
        defer {
            if !succeeded {
                ComposerAttachmentImporter.discard(Array(record.urls.values))
                record.urls = [:]
                records[access.accountID] = record
            }
        }
        var restored: [AttachmentDraftQueue] = []
        for queue in record.manifest.queues.values.sorted(by: { $0.address.id < $1.address.id }) {
            var files: [AttachmentDraftFile] = []
            for entry in queue.files {
                try Task.checkCancellation()
                do {
                    let data = try readBlob(entry, record: record, accountID: access.accountID)
                    let url = try ComposerAttachmentImporter.stageRestoredData(data, filename: entry.filename)
                    record.urls[entry.id] = url
                    records[access.accountID] = record
                    files.append(file(entry, url: url))
                } catch is CancellationError {
                    ComposerAttachmentImporter.discard(Array(record.urls.values))
                    record.urls = [:]
                    records[access.accountID] = record
                    throw CancellationError()
                } catch {
                    files.append(
                        file(
                            entry, url: nil,
                            error:
                                "This saved attachment is unavailable. Try reopening drafts, choose the original file again, or remove it."
                        ))
                }
            }
            restored.append(AttachmentDraftQueue(address: queue.address, revision: queue.revision, files: files))
        }
        try Task.checkCancellation()
        succeeded = true
        return restored
    }

    func save(urls: [URL], address: AttachmentDraftAddress, access: AttachmentDraftAccess, revision: UInt64) throws
        -> AttachmentDraftQueue
    {
        var record = try current(access)
        try validate(address)
        try checkRevision(revision, address: address, record: record)
        try checkDiskManifest(record, accountID: access.accountID)
        guard urls.count <= ComposerAttachmentImporter.maximumFiles, Set(urls).count == urls.count else {
            throw AttachmentDraftError.budget
        }
        guard !urls.contains(where: { record.completedURLs[address.id, default: []].contains($0) }) else {
            throw AttachmentDraftError.staleRevision
        }
        let previous = record.manifest.queues[address.id]?.files ?? []
        let unavailable = previous.filter { record.urls[$0.id] == nil }
        guard urls.count + unavailable.count <= ComposerAttachmentImporter.maximumFiles else {
            throw AttachmentDraftError.budget
        }
        var queueBytes = unavailable.reduce(0) { $0 + $1.byteCount }
        for url in urls { queueBytes += try sourceSize(url) }
        guard queueBytes <= ComposerAttachmentImporter.maximumQueueBytes else { throw AttachmentDraftError.budget }
        var files: [Entry] = []
        var created: [Entry] = []
        do {
            for url in urls {
                try Task.checkCancellation()
                if let entry = previous.first(where: { record.urls[$0.id] == url }) {
                    guard try sourceDigest(url) == entry.digest else { throw AttachmentDraftError.changedFile }
                    files.append(entry)
                } else {
                    let data = try sourceData(url)
                    let name = url.lastPathComponent
                    guard Self.validFilename(name) else { throw AttachmentDraftError.invalidFile }
                    let entry = Entry(
                        id: UUID().uuidString, filename: name, byteCount: data.count, digest: Self.digest(data))
                    let encrypted = try seal(
                        data, key: record.key, authentication: blobAuthentication(access.accountID, entry.id),
                        magic: "ELADB01\n")
                    try ensureBudget(extra: encrypted.count, directory: record.lease.directory)
                    created.append(entry)
                    try writeAtomic(encrypted, to: blobURL(entry.id, directory: record.lease.directory))
                    files.append(entry)
                    record.urls[entry.id] = url
                }
            }
            // Unavailable restored entries remain until an explicit remove(fileID:) action.
            files += previous.filter { record.urls[$0.id] == nil }
            let queue = Queue(address: address, revision: revision, files: files)
            var manifest = record.manifest
            manifest.queues[address.id] = queue
            try validate(manifest)
            try Task.checkCancellation()
            try commit(manifest, record: &record, accountID: access.accountID)
            for entry in previous where !files.contains(where: { $0.id == entry.id }) {
                removeOwnedBlob(entry.id, directory: record.lease.directory)
                record.urls[entry.id] = nil
            }
            records[access.accountID] = record
            return view(queue, record: record)
        } catch {
            // A failed directory fsync may follow rename: inspect the actual manifest before cleanup.
            if let actual = try? loadManifest(
                directory: record.lease.directory, key: record.key, accountID: access.accountID)
            {
                for entry in created
                where !actual.queues.values.contains(where: { $0.files.contains(where: { $0.id == entry.id }) }) {
                    removeOwnedBlob(entry.id, directory: record.lease.directory)
                }
            }
            throw error
        }
    }

    func markSending(url: URL, address: AttachmentDraftAddress, access: AttachmentDraftAccess, revision: UInt64) throws
    {
        try Task.checkCancellation()
        var record = try current(access)
        try checkRevision(revision, address: address, record: record)
        guard var queue = record.manifest.queues[address.id],
            let index = queue.files.firstIndex(where: { record.urls[$0.id] == url })
        else { throw AttachmentDraftError.invalidFile }
        guard try sourceDigest(url) == queue.files[index].digest else { throw AttachmentDraftError.changedFile }
        queue.files[index].phase = .sending
        queue.revision = revision
        var manifest = record.manifest
        manifest.queues[address.id] = queue
        try Task.checkCancellation()
        try commit(manifest, record: &record, accountID: access.accountID)
    }

    func confirmSent(url: URL, address: AttachmentDraftAddress, access: AttachmentDraftAccess, revision: UInt64) throws
    {
        var record = try current(access)
        if record.completedURLs[address.id, default: []].contains(url) {
            // Retry the durable cleanup after an uncertain directory fsync, without another SDK send.
            try checkRevision(revision, address: address, record: record)
            guard var queue = record.manifest.queues[address.id] else { throw AttachmentDraftError.invalidFile }
            queue.revision = revision
            var manifest = record.manifest
            manifest.queues[address.id] = queue
            try commit(manifest, record: &record, accountID: access.accountID)
            let referenced = Set(record.manifest.queues.values.flatMap { $0.files.map(\.id) })
            for id in record.urls.filter({ $0.value == url && !referenced.contains($0.key) }).map(\.key) {
                removeOwnedBlob(id, directory: record.lease.directory)
                record.urls[id] = nil
            }
            if !record.urls.values.contains(url) { ComposerAttachmentImporter.discard([url]) }
            records[access.accountID] = record
            return
        }
        guard let entry = record.manifest.queues[address.id]?.files.first(where: { record.urls[$0.id] == url }),
            entry.phase == .sending
        else { throw AttachmentDraftError.invalidFile }
        do { try remove(fileID: entry.id, address: address, access: access, revision: revision) } catch {
            if var updated = records[access.accountID],
                updated.manifest.queues[address.id]?.files.contains(where: { $0.id == entry.id }) == false
            {
                updated.completedURLs[address.id, default: []].insert(url)
                records[access.accountID] = updated
            }
            throw error
        }
        if var updated = records[access.accountID] {
            updated.completedURLs[address.id, default: []].insert(url)
            records[access.accountID] = updated
        }
    }

    func remove(fileID: String, address: AttachmentDraftAddress, access: AttachmentDraftAccess, revision: UInt64) throws
    {
        var record = try current(access)
        try checkRevision(revision, address: address, record: record)
        guard var queue = record.manifest.queues[address.id], queue.files.contains(where: { $0.id == fileID }) else {
            throw AttachmentDraftError.invalidFile
        }
        queue.files.removeAll { $0.id == fileID }
        queue.revision = revision
        var manifest = record.manifest
        manifest.queues[address.id] = queue
        try commit(manifest, record: &record, accountID: access.accountID)
        removeOwnedBlob(fileID, directory: record.lease.directory)
        if let url = record.urls.removeValue(forKey: fileID), !record.urls.values.contains(url) {
            ComposerAttachmentImporter.discard([url])
        }
        records[access.accountID] = record
    }

    func discardStaged(access: AttachmentDraftAccess) {
        guard var record = records[access.accountID], record.generation == access.generation else { return }
        ComposerAttachmentImporter.discard(Array(record.urls.values))
        record.urls = [:]
        records[access.accountID] = record
    }

    func close(access: AttachmentDraftAccess) {
        guard let record = records[access.accountID], record.generation == access.generation else { return }
        ComposerAttachmentImporter.discard(Array(record.urls.values))
        records[access.accountID] = nil
        opening[access.accountID] = nil
    }

    private func current(_ access: AttachmentDraftAccess) throws -> Record {
        guard let record = records[access.accountID], record.generation == access.generation else {
            throw AttachmentDraftError.staleAccess
        }
        return record
    }
    private func checkRevision(_ revision: UInt64, address: AttachmentDraftAddress, record: Record) throws {
        guard revision > (record.manifest.queues[address.id]?.revision ?? 0) else {
            throw AttachmentDraftError.staleRevision
        }
    }
    private func validate(_ address: AttachmentDraftAddress) throws {
        guard ProtectedLocalState.validID(address.roomID), address.roomID.hasPrefix("!"),
            address.threadRootID.map({ ProtectedLocalState.validID($0) && $0.hasPrefix("$") }) ?? true
        else { throw AttachmentDraftError.invalidData }
    }
    private func validate(_ manifest: Manifest) throws {
        guard manifest.version == 1, manifest.queues.count <= 4_096 else { throw AttachmentDraftError.invalidData }
        var ids = Set<String>()
        var count = 0
        var totalBytes = 0
        for (key, queue) in manifest.queues {
            try validate(queue.address)
            guard key == queue.address.id, queue.revision > 0,
                queue.files.count <= ComposerAttachmentImporter.maximumFiles
            else { throw AttachmentDraftError.invalidData }
            var bytes = 0
            for entry in queue.files {
                guard UUID(uuidString: entry.id) != nil, ids.insert(entry.id).inserted,
                    Self.validFilename(entry.filename), entry.byteCount >= 0,
                    entry.byteCount <= ComposerAttachmentImporter.maximumFileBytes,
                    entry.digest.count == 64, entry.digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
                else { throw AttachmentDraftError.invalidData }
                bytes += entry.byteCount
                totalBytes += entry.byteCount
                count += 1
            }
            guard bytes <= ComposerAttachmentImporter.maximumQueueBytes else { throw AttachmentDraftError.budget }
        }
        guard count <= 4_096, totalBytes <= budgetBytes,
            try JSONEncoder().encode(manifest).count <= Self.maximumManifestBytes
        else { throw AttachmentDraftError.budget }
    }
    private func file(_ entry: Entry, url: URL?, error: String? = nil) -> AttachmentDraftFile {
        AttachmentDraftFile(
            id: entry.id, filename: entry.filename, byteCount: entry.byteCount, url: url,
            phase: entry.phase == .sending ? .interrupted : .ready, errorMessage: error)
    }
    private func view(_ queue: Queue, record: Record) -> AttachmentDraftQueue {
        AttachmentDraftQueue(
            address: queue.address, revision: queue.revision,
            files: queue.files.map {
                file(
                    $0, url: record.urls[$0.id],
                    error: record.urls[$0.id] == nil
                        ? "This saved attachment is unavailable. Reopen drafts or choose the original file again." : nil
                )
            })
    }
    private func accountDirectory(_ account: String) -> URL {
        directory.appendingPathComponent(Self.digest(Data(account.utf8)), isDirectory: true)
    }
    private func blobURL(_ id: String, directory: URL) -> URL { directory.appendingPathComponent(id + ".blob") }
    private func blobAuthentication(_ account: String, _ id: String) -> Data {
        Data("ai.nuanu.slatrix.attachment:v1:\(account):\(id)".utf8)
    }
    private func manifestAuthentication(_ account: String) -> Data {
        Data("ai.nuanu.slatrix.attachment-manifest:v1:\(account)".utf8)
    }
    private func removeOwnedBlob(_ id: String, directory: URL) {
        if UUID(uuidString: id) != nil { try? FileManager.default.removeItem(at: blobURL(id, directory: directory)) }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && name.utf8.count <= 1_024
            && name.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func readBlob(_ entry: Entry, record: Record, accountID: String) throws -> Data {
        guard
            let encrypted = try readFile(
                blobURL(entry.id, directory: record.lease.directory),
                maximum: ComposerAttachmentImporter.maximumFileBytes + 128)
        else { throw AttachmentDraftError.invalidFile }
        let data = try unseal(
            encrypted, key: record.key, authentication: blobAuthentication(accountID, entry.id), magic: "ELADB01\n")
        guard data.count == entry.byteCount, Self.digest(data) == entry.digest else {
            throw AttachmentDraftError.invalidData
        }
        return data
    }
    private func loadManifest(directory: URL, key: Data, accountID: String) throws -> Manifest {
        guard
            let data = try readFile(
                directory.appendingPathComponent("manifest.vault"), maximum: Self.maximumManifestBytes + 128)
        else { throw AttachmentDraftError.invalidData }
        let plaintext = try unseal(
            data, key: key, authentication: manifestAuthentication(accountID), magic: "ELADM01\n")
        guard plaintext.count <= Self.maximumManifestBytes,
            let object = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
            Set(object.keys) == ["version", "queues"],
            let result = try? JSONDecoder().decode(Manifest.self, from: plaintext)
        else { throw AttachmentDraftError.invalidData }
        try validate(result)
        return result
    }
    private func checkDiskManifest(_ record: Record, accountID: String) throws {
        guard
            try loadManifest(directory: record.lease.directory, key: record.key, accountID: accountID)
                == record.manifest
        else { throw AttachmentDraftError.invalidData }
    }
    private func commit(_ manifest: Manifest, record: inout Record, accountID: String) throws {
        try validate(manifest)
        try checkDiskManifest(record, accountID: accountID)
        let data = try seal(
            JSONEncoder().encode(manifest), key: record.key, authentication: manifestAuthentication(accountID),
            magic: "ELADM01\n")
        try ensureBudget(extra: data.count, directory: record.lease.directory)
        do {
            try fault?(.beforeManifestCommit)
            try writeAtomic(data, to: record.lease.directory.appendingPathComponent("manifest.vault")) {
                try self.fault?(.afterManifestRename)
            }
            record.manifest = manifest
            records[accountID] = record
        } catch {
            if let actual = try? loadManifest(directory: record.lease.directory, key: record.key, accountID: accountID),
                actual == manifest
            {
                record.manifest = manifest
                records[accountID] = record
            }
            throw AttachmentDraftError.unavailable
        }
    }
    private func seal(_ plaintext: Data, key: Data, authentication: Data, magic: String) throws -> Data {
        guard key.count == 32,
            let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: authentication)
                .combined
        else { throw AttachmentDraftError.invalidData }
        return Data(magic.utf8) + combined
    }
    private func unseal(_ data: Data, key: Data, authentication: Data, magic: String) throws -> Data {
        let prefix = Data(magic.utf8)
        guard key.count == 32, data.starts(with: prefix), data.count >= prefix.count + 28 else {
            throw AttachmentDraftError.invalidData
        }
        do {
            return try AES.GCM.open(
                AES.GCM.SealedBox(combined: data.dropFirst(prefix.count)), using: SymmetricKey(data: key),
                authenticating: authentication)
        } catch { throw AttachmentDraftError.invalidData }
    }
    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
            info.st_mode & 0o777 == 0o700
        else { throw AttachmentDraftError.unavailable }
    }
    private func readFile(_ url: URL, maximum: Int) throws -> Data? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw AttachmentDraftError.unavailable
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
            info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size >= 0, info.st_size <= maximum
        else { throw AttachmentDraftError.invalidData }
        var result = Data(count: Int(info.st_size))
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AttachmentDraftError.unavailable }
                offset += count
            }
        }
        return result
    }
    private func writeAtomic(_ data: Data, to url: URL, afterRename: () throws -> Void = {}) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent(
            ".write-" + url.lastPathComponent + "-" + UUID().uuidString)
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AttachmentDraftError.unavailable }
        defer {
            Darwin.close(descriptor)
            unlink(staging.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AttachmentDraftError.unavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, try readFile(staging, maximum: data.count) == data,
            rename(staging.path, url.path) == 0
        else { throw AttachmentDraftError.unavailable }
        try afterRename()
        let folder = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folder >= 0 else { throw AttachmentDraftError.unavailable }
        defer { Darwin.close(folder) }
        guard fsync(folder) == 0 else { throw AttachmentDraftError.unavailable }
    }
    private func ensureBudget(extra: Int, directory: URL) throws {
        var used = 0
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw AttachmentDraftError.unavailable }
            if info.st_mode & S_IFMT == S_IFREG {
                guard info.st_size >= 0, info.st_size <= budgetBytes else { throw AttachmentDraftError.budget }
                used += Int(info.st_size)
            }
            guard used <= budgetBytes else { throw AttachmentDraftError.budget }
        }
        guard extra <= budgetBytes - used else { throw AttachmentDraftError.budget }
    }
    private func reapOrphans(record: Record, accountID: String) -> String? {
        let referenced = Set(record.manifest.queues.values.flatMap { $0.files.map(\.id) })
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: record.lease.directory, includingPropertiesForKeys: nil)
        else {
            return
                "Couldn’t check some saved attachments. Reopen drafts to try again."
        }
        var preservedUnknown = false
        for url in files {
            let name = url.lastPathComponent
            if name == ".lease" || name == "manifest.vault" { continue }
            var blobID: String?
            var isManifestWrite = false
            if url.pathExtension == "blob", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                let id = url.deletingPathExtension().lastPathComponent
                if referenced.contains(id) { continue }
                blobID = id
            } else if name.hasPrefix(".write-manifest.vault-"),
                UUID(uuidString: String(name.dropFirst(".write-manifest.vault-".count))) != nil
            {
                isManifestWrite = true
            } else if name.hasPrefix(".write-"), name.count == 7 + 36 + 6 + 36 {
                let rest = String(name.dropFirst(7))
                let id = String(name.dropFirst(7).prefix(36))
                let suffix = String(rest.dropFirst(36))
                if UUID(uuidString: id) != nil, suffix.hasPrefix(".blob-"),
                    UUID(uuidString: String(suffix.dropFirst(6))) != nil
                {
                    blobID = id
                }
            }
            do {
                if let blobID {
                    guard let bytes = try readFile(url, maximum: ComposerAttachmentImporter.maximumFileBytes + 128)
                    else { continue }
                    _ = try unseal(
                        bytes, key: record.key, authentication: blobAuthentication(accountID, blobID),
                        magic: "ELADB01\n")
                } else if isManifestWrite {
                    guard let bytes = try readFile(url, maximum: Self.maximumManifestBytes + 128) else { continue }
                    let plaintext = try unseal(
                        bytes, key: record.key, authentication: manifestAuthentication(accountID), magic: "ELADM01\n")
                    guard let manifest = try? JSONDecoder().decode(Manifest.self, from: plaintext) else {
                        throw AttachmentDraftError.invalidData
                    }
                    try validate(manifest)
                } else {
                    preservedUnknown = true
                    continue
                }
                try FileManager.default.removeItem(at: url)
            } catch { preservedUnknown = true }
        }
        return preservedUnknown
            ? "Some old attachment files couldn’t be cleaned up and still use disk space."
            : nil
    }
    private func sourceData(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try readSource(url, collect: true).0 else { throw AttachmentDraftError.invalidFile }
        return data
    }
    private func sourceDigest(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try readSource(url, collect: false).1
    }
    private func sourceSize(_ url: URL) throws -> Int {
        guard url.isFileURL else { throw AttachmentDraftError.invalidFile }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AttachmentDraftError.invalidFile }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
            throw AttachmentDraftError.invalidFile
        }
        guard info.st_size <= ComposerAttachmentImporter.maximumFileBytes else { throw AttachmentDraftError.budget }
        return Int(info.st_size)
    }
    private func readSource(_ url: URL, collect: Bool) throws -> (Data?, String) {
        guard url.isFileURL else { throw AttachmentDraftError.invalidFile }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw AttachmentDraftError.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        var after = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else {
            throw AttachmentDraftError.invalidFile
        }
        guard before.st_size <= ComposerAttachmentImporter.maximumFileBytes else { throw AttachmentDraftError.budget }
        var data = collect ? Data() : nil
        var digest = SHA256()
        var total = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty else { break }
            total += chunk.count
            guard total <= ComposerAttachmentImporter.maximumFileBytes else { throw AttachmentDraftError.budget }
            digest.update(data: chunk)
            if collect { data?.append(chunk) }
        }
        guard fstat(descriptor, &after) == 0, total == before.st_size, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        else { throw AttachmentDraftError.changedFile }
        return (data, digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
