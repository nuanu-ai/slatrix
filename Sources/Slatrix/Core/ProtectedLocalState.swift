import CryptoKit
import Darwin
import Foundation

struct SavedMessageReference: Codable, Hashable, Identifiable {
    var roomID: String
    var eventID: String
    var savedAt: Date
    var id: String { "\(roomID.utf8.count):\(roomID)\(eventID)" }
    init(roomID: String, eventID: String, savedAt: Date = Date()) {
        self.roomID = roomID
        self.eventID = eventID
        self.savedAt = savedAt
    }
}

struct ProtectedLocalState: Codable, Equatable {
    var drafts: [String: String] = [:]
    var threadDrafts: [String: String] = [:]
    var saved: [SavedMessageReference] = []
    /// Optional, so a vault written before it existed still opens.
    var recentSearches: [String]?
    /// When each message left Later, so a removal made offline still reaches the account; optional, as above.
    var savedRemovals: [SavedMessageReference]?

    func validate() throws {
        guard drafts.count <= 4_096, threadDrafts.count <= 4_096, saved.count <= 10_000,
            (savedRemovals ?? []).count <= 10_000,
            (recentSearches ?? []).count <= RecentSearches.limit,
            (recentSearches ?? []).allSatisfy({ $0.utf8.count <= 1_024 })
        else { throw ProtectedLocalStateError.invalidData }
        for (id, text) in drafts {
            guard Self.validID(id), text.utf8.count <= 131_072 else { throw ProtectedLocalStateError.invalidData }
        }
        for (id, text) in threadDrafts {
            guard ThreadDraftAddress(id: id) != nil, text.utf8.count <= 131_072 else {
                throw ProtectedLocalStateError.invalidData
            }
        }
        let textBytes =
            drafts.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            + threadDrafts.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard textBytes <= ProtectedLocalStateCodec.maximumPlaintextBytes else {
            throw ProtectedLocalStateError.invalidData
        }
        for list in [saved, savedRemovals ?? []] {
            var seen = Set<String>()
            for item in list {
                guard Self.validID(item.roomID), item.roomID.hasPrefix("!"),
                    Self.validID(item.eventID), item.eventID.hasPrefix("$"),
                    item.savedAt.timeIntervalSince1970.isFinite, seen.insert(item.id).inserted
                else { throw ProtectedLocalStateError.invalidData }
            }
        }
        guard try JSONEncoder().encode(self).count <= ProtectedLocalStateCodec.maximumPlaintextBytes - 128 else {
            throw ProtectedLocalStateError.invalidData
        }
    }

    static func validID(_ value: String) -> Bool {
        MatrixID.isValid(value, sigil: "")
    }
}

struct ProtectedLocalStateAccess {
    let accountID: String
    let generation: UUID
    let state: ProtectedLocalState
}

enum ProtectedLocalStateError: LocalizedError {
    case invalidData, unavailable, staleAccess, invalidRevision
    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Couldn’t read your drafts and saved messages."
        case .unavailable:
            return "Couldn’t save your drafts and saved messages."
        case .staleAccess: return "You signed in again. Try again."
        case .invalidRevision:
            return "Couldn’t save your drafts. Try again."
        }
    }
}

/// All writes finish and verify before returning. Await a final captured save to flush on switch or quit.
actor ProtectedLocalStateStore {
    static let shared = ProtectedLocalStateStore()
    private let directory: URL
    private let keyProvider: @Sendable (String) async throws -> Data
    private struct Record {
        var generation: UUID
        var key: Data
        var state: ProtectedLocalState
        var revision: UInt64 = 0
        var durable = true
    }
    private var records: [String: Record] = [:]
    private var opening: [String: UUID] = [:]

    init(
        directory: URL? = nil,
        keyProvider: @escaping @Sendable (String) async throws -> Data = { account in
            try await Task.detached(priority: .userInitiated) {
                try SecureSessionStore.localStateKey(accountID: account)
            }.value
        }
    ) {
        self.directory =
            directory ?? AppPaths.applicationSupport.appendingPathComponent("ProtectedLocalState", isDirectory: true)
        self.keyProvider = keyProvider
    }

    func open(accountID: String) async throws -> ProtectedLocalStateAccess {
        guard SecureSessionStore.validAccountID(accountID) else { throw ProtectedLocalStateError.invalidData }
        let token = UUID()
        opening[accountID] = token
        let key = try await keyProvider(accountID)
        guard opening[accountID] == token else { throw CancellationError() }
        try Task.checkCancellation()
        guard key.count == 32 else { throw ProtectedLocalStateError.invalidData }
        try ProtectedLocalStateCodec.prepareDirectory(directory)
        let url = fileURL(accountID)
        // A failed write remains owned by this account until it can be committed or an error is surfaced.
        if var pending = records[accountID], !pending.durable {
            guard pending.key == key else { throw ProtectedLocalStateError.invalidData }
            _ = try ProtectedLocalStateCodec.read(url, key: key, accountID: accountID)
            try ProtectedLocalStateCodec.write(pending.state, to: url, key: key, accountID: accountID)
            pending.durable = true
            records[accountID] = pending
        }
        let state = try ProtectedLocalStateCodec.read(url, key: key, accountID: accountID) ?? ProtectedLocalState()
        records[accountID] = Record(generation: token, key: key, state: state)
        return ProtectedLocalStateAccess(accountID: accountID, generation: token, state: state)
    }

    func save(_ state: ProtectedLocalState, access: ProtectedLocalStateAccess, revision: UInt64) throws {
        guard var record = records[access.accountID], record.generation == access.generation else {
            throw ProtectedLocalStateError.staleAccess
        }
        guard revision > 0 else { throw ProtectedLocalStateError.invalidRevision }
        guard revision >= record.revision else { return }
        if revision == record.revision {
            guard state == record.state else { throw ProtectedLocalStateError.invalidRevision }
            if record.durable { return }
        }
        try state.validate()
        record.state = state
        record.revision = revision
        record.durable = false
        records[access.accountID] = record
        // Refuse to overwrite externally corrupted state after the account was opened.
        _ = try ProtectedLocalStateCodec.read(fileURL(access.accountID), key: record.key, accountID: access.accountID)
        try ProtectedLocalStateCodec.write(
            state, to: fileURL(access.accountID), key: record.key, accountID: access.accountID)
        record.durable = true
        records[access.accountID] = record
    }

    func fileURL(_ accountID: String) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".vault", isDirectory: false)
    }
}

/// A versioned, authenticated binary file. Account identity is authenticated but never written in its path.
enum ProtectedLocalStateCodec {
    static let maximumPlaintextBytes = 4 * 1_024 * 1_024
    private static let magic = Data("ELVLT01\n".utf8)
    private static let maximumFileBytes = maximumPlaintextBytes + 128
    private struct Payload: Codable {
        /// 2 stores drafts as Matrix HTML; 1 stored them as Markdown. Older builds refuse 2 rather than misread it.
        var version = 2
        var state: ProtectedLocalState
    }

    static func seal(_ state: ProtectedLocalState, key: Data, accountID: String) throws -> Data {
        try state.validate()
        guard key.count == 32, SecureSessionStore.validAccountID(accountID) else {
            throw ProtectedLocalStateError.invalidData
        }
        let plaintext = try JSONEncoder().encode(Payload(state: state))
        guard plaintext.count <= maximumPlaintextBytes,
            let combined = try AES.GCM.seal(
                plaintext, using: SymmetricKey(data: key), authenticating: authentication(accountID)
            ).combined
        else { throw ProtectedLocalStateError.invalidData }
        return magic + combined
    }

    static func unseal(_ data: Data, key: Data, accountID: String) throws -> ProtectedLocalState {
        guard key.count == 32, SecureSessionStore.validAccountID(accountID), data.count <= maximumFileBytes,
            data.starts(with: magic), data.count > magic.count + 28
        else { throw ProtectedLocalStateError.invalidData }
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(magic.count))
            let plaintext = try AES.GCM.open(
                box, using: SymmetricKey(data: key), authenticating: authentication(accountID))
            guard plaintext.count <= maximumPlaintextBytes,
                let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
                Set(object.keys) == ["version", "state"]
            else { throw ProtectedLocalStateError.invalidData }
            var payload = try JSONDecoder().decode(Payload.self, from: plaintext)
            guard [1, 2].contains(payload.version) else { throw ProtectedLocalStateError.invalidData }
            try payload.state.validate()
            if payload.version == 1 {
                // A draft that would outgrow the limit as HTML stays as written rather than lock the whole vault.
                let migrate = { (text: String) in
                    let html = ComposerFormat.draft(plain: text)
                    return html.utf8.count <= 131_072 ? html : text
                }
                payload.state.drafts = payload.state.drafts.mapValues(migrate)
                payload.state.threadDrafts = payload.state.threadDrafts.mapValues(migrate)
            }
            return payload.state
        } catch { throw ProtectedLocalStateError.invalidData }
    }

    static func prepareDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
            chmod(directory.path, 0o700) == 0
        else { throw ProtectedLocalStateError.unavailable }
    }

    static func read(_ url: URL, key: Data, accountID: String) throws -> ProtectedLocalState? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ProtectedLocalStateError.unavailable
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
            info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maximumFileBytes
        else { throw ProtectedLocalStateError.invalidData }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProtectedLocalStateError.unavailable }
                offset += count
            }
        }
        return try unseal(data, key: key, accountID: accountID)
    }

    static func write(_ state: ProtectedLocalState, to url: URL, key: Data, accountID: String) throws {
        let data = try seal(state, key: key, accountID: accountID)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let descriptor = Darwin.open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProtectedLocalStateError.unavailable }
        defer {
            Darwin.close(descriptor)
            unlink(staging.path)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ProtectedLocalStateError.unavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, try read(staging, key: key, accountID: accountID) == state,
            rename(staging.path, url.path) == 0
        else { throw ProtectedLocalStateError.unavailable }
        let directory = Darwin.open(
            url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ProtectedLocalStateError.unavailable }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0, try read(url, key: key, accountID: accountID) == state else {
            throw ProtectedLocalStateError.unavailable
        }
    }

    private static func authentication(_ accountID: String) -> Data {
        Data("ai.nuanu.slatrix.local-state:v1:\(accountID)".utf8)
    }
}
