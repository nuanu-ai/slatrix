import Foundation
import Security

struct StoredSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let userId: String
    let deviceId: String
    let homeserverUrl: String
    let oidcData: String?
    let storeID: String
    let storeKey: Data

    init(
        accessToken: String, refreshToken: String? = nil, userId: String, deviceId: String, homeserverUrl: String,
        oidcData: String? = nil, storeID: String, storeKey: Data
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.deviceId = deviceId
        self.homeserverUrl = homeserverUrl
        self.oidcData = oidcData
        self.storeID = storeID
        self.storeKey = storeKey
    }

    func validate() throws {
        let fields = [accessToken, userId, deviceId, homeserverUrl, storeID]
        guard
            fields.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 131_072 && $0.rangeOfCharacter(from: .controlCharacters) == nil
            }),
            userId.hasPrefix("@"), userId.contains(":"),
            let url = URLComponents(string: homeserverUrl),
            let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.scheme == "https"
                || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
            UUID(uuidString: storeID) != nil, storeKey.count == 32
        else {
            throw SecureSessionStore.StoreError.invalidSession
        }
    }
}

struct CredentialEnvelope: Codable, Equatable {
    var version = 1
    var session: StoredSession?
    var vaultKeys: [String: Data] = [:]

    func validate() throws {
        guard version == 1, vaultKeys.count <= 128 else { throw SecureSessionStore.StoreError.invalidSession }
        try session?.validate()
        for (account, key) in vaultKeys {
            guard SecureSessionStore.validAccountID(account), key.count == 32 else {
                throw SecureSessionStore.StoreError.invalidSession
            }
        }
    }
}

enum SecureSessionStore {
    private static let lock = NSLock()
    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidSession

        var errorDescription: String? {
            switch self {
            case .keychain(let status):
                return
                    "Couldn’t read your session from Keychain (\(status)). Unlock Keychain and try again."
            case .invalidSession:
                return "Your saved session is damaged. Sign in again."
            }
        }
    }

    static func generateStoreKey() throws -> Data {
        var data = Data(count: 32)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return data
    }

    static func validAccountID(_ account: String) -> Bool {
        MatrixID.isValid(account, sigil: "@") && account.contains(":")
    }

    static func decodeEnvelope(_ data: Data) throws -> CredentialEnvelope {
        guard let envelope = try? JSONDecoder().decode(CredentialEnvelope.self, from: data) else {
            throw StoreError.invalidSession
        }
        try envelope.validate()
        return envelope
    }

    static func encodeEnvelope(_ envelope: CredentialEnvelope) throws -> Data {
        try envelope.validate()
        return try JSONEncoder().encode(envelope)
    }

    private static func readEnvelope() throws -> CredentialEnvelope {
        try readData().map(decodeEnvelope) ?? CredentialEnvelope()
    }

    private static func writeEnvelope(_ envelope: CredentialEnvelope) throws {
        try writeData(encodeEnvelope(envelope))
    }

    static func load() throws -> StoredSession? {
        lock.lock()
        defer { lock.unlock() }
        return try readEnvelope().session
    }

    static func save(_ session: StoredSession) throws {
        try session.validate()
        lock.lock()
        defer { lock.unlock() }
        var envelope = try readEnvelope()
        envelope.session = session
        try writeEnvelope(envelope)
    }

    static func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try readData() else { return }
        var envelope = try decodeEnvelope(data)
        envelope.session = nil
        // Keep the local-state keys so drafts saved by this account stay readable after a future sign-in.
        try writeEnvelope(envelope)
    }

    static func localStateKey(accountID: String) throws -> Data {
        guard validAccountID(accountID) else { throw StoreError.invalidSession }
        lock.lock()
        defer { lock.unlock() }
        var envelope = try readEnvelope()
        if let key = envelope.vaultKeys[accountID] { return key }
        guard envelope.session?.userId == accountID else { throw StoreError.invalidSession }
        let key = try generateStoreKey()
        envelope.vaultKeys[accountID] = key
        try writeEnvelope(envelope)
        return key
    }

    // Debug builds are not stably signed, so each rebuild would land in a new Keychain partition and prompt again.
    #if DEBUG
    private static var fileURL: URL { AppPaths.applicationSupport.appendingPathComponent("credentials.json") }

    private static func readData() throws -> Data? {
        do { return try Data(contentsOf: fileURL) } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    private static func writeData(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = directory.appendingPathComponent(".credentials-" + UUID().uuidString)
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { unlink(staging.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(staging.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    #else
    private static let keychainItem: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "ai.nuanu.slatrix",
        kSecAttrAccount as String: "matrix-session",
    ]

    private static func readData() throws -> Data? {
        var query = keychainItem
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data else { throw StoreError.invalidSession }
        return data
    }

    private static func writeData(_ data: Data) throws {
        var status = SecItemUpdate(keychainItem as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = keychainItem
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrLabel as String] = "Slatrix Matrix session"
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }
    #endif
}
