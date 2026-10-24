import Foundation
import Testing

@testable import Slatrix

private let vaultKey = Data(repeating: 0x71, count: 32)
private let account = "@vault-fixture:example.org"
private let otherAccount = "@other-fixture:example.org"
private let secret = "fixture draft with private content — never plaintext on disk"
private let reference = SavedMessageReference(
    roomID: "!fixture:example.org", eventID: "$fixture", savedAt: Date(timeIntervalSince1970: 1234))
private let original = ProtectedLocalState(
    drafts: [reference.roomID: secret], threadDrafts: [reference.id: "thread fixture"], saved: [reference])

private func withDraft(_ text: String) -> ProtectedLocalState {
    var state = original
    state.drafts[reference.roomID] = text
    return state
}

struct ThreadDraftAddressTests {
    @Test("A thread draft key round-trips, including non-ASCII IDs")
    func roundTrip() {
        let address = ThreadDraftAddress(roomID: "!é:example.org", rootID: "$🌲")
        #expect(ThreadDraftAddress(id: address.id) == address)
    }

    @Test("Room and root boundaries cannot be confused")
    func unambiguous() {
        #expect(
            ThreadDraftAddress(roomID: "!a", rootID: "$b$c").id != ThreadDraftAddress(roomID: "!a$b", rootID: "$c").id)
    }

    @Test(
        "Malformed thread draft keys are rejected",
        arguments: ["", "0:!x$y", "-1:!x$y", "100000:!x$y", "2:!é$x", "03:!ab$x", "3:!abx"])
    func malformed(id: String) {
        #expect(ThreadDraftAddress(id: id) == nil)
    }

    @Test("Long but bounded IDs are accepted; a thread draft without a room is not")
    func validation() throws {
        let long = ThreadDraftAddress(
            roomID: "!" + String(repeating: "a", count: 2_047), rootID: "$" + String(repeating: "b", count: 2_047))
        try ProtectedLocalState(threadDrafts: [long.id: "bounded"]).validate()
        #expect(throws: ProtectedLocalStateError.self) {
            try ProtectedLocalState(threadDrafts: ["$unscoped": "invalid"]).validate()
        }
    }
}

struct CredentialEnvelopeTests {
    private let envelope = CredentialEnvelope(
        session: StoredSession(
            accessToken: "synthetic-token", userId: account, deviceId: "FIXTURE",
            homeserverUrl: "https://example.org", storeID: UUID().uuidString, storeKey: vaultKey),
        vaultKeys: [account: vaultKey])

    @Test("Credentials round-trip through the stored envelope")
    func roundTrip() throws {
        #expect(try SecureSessionStore.decodeEnvelope(SecureSessionStore.encodeEnvelope(envelope)) == envelope)
    }

    @Test(
        "A bare session, an unknown version, a short vault key or garbage is refused",
        arguments: ["bare session", "version 2", "short key", "garbage"])
    func rejectsMalformed(kind: String) throws {
        var malformed = envelope
        let data: Data
        switch kind {
        case "bare session": data = try JSONEncoder().encode(envelope.session)
        case "version 2":
            malformed.version = 2
            data = try JSONEncoder().encode(malformed)
        case "short key":
            malformed.vaultKeys[account] = Data(repeating: 0, count: 31)
            data = try JSONEncoder().encode(malformed)
        default: data = Data("corrupt".utf8)
        }
        #expect(throws: (any Error).self) { try SecureSessionStore.decodeEnvelope(data) }
    }
}

struct ProtectedLocalStateCodecTests {
    @Test("Sealed state opens with its key and account and never contains the plaintext")
    func sealsPrivately() throws {
        let sealed = try ProtectedLocalStateCodec.seal(original, key: vaultKey, accountID: account)
        #expect(try ProtectedLocalStateCodec.unseal(sealed, key: vaultKey, accountID: account) == original)
        #expect(sealed.range(of: Data(secret.utf8)) == nil)
        #expect(try ProtectedLocalStateCodec.seal(original, key: vaultKey, accountID: account) != sealed)
    }

    @Test(
        "A wrong key, another account, a flipped byte or an unknown format is refused",
        arguments: ["wrong key", "other account", "tampered", "unknown format"])
    func rejectsTampering(kind: String) throws {
        var sealed = try ProtectedLocalStateCodec.seal(original, key: vaultKey, accountID: account)
        var unsealKey = vaultKey
        var unsealAccount = account
        switch kind {
        case "wrong key": unsealKey = Data(repeating: 0, count: 32)
        case "other account": unsealAccount = otherAccount
        case "tampered": sealed[sealed.count - 1] ^= 1
        default: sealed[5] ^= 1
        }
        #expect(throws: (any Error).self) {
            try ProtectedLocalStateCodec.unseal(sealed, key: unsealKey, accountID: unsealAccount)
        }
    }

    @Test("An oversized draft is refused")
    func rejectsOversizedDraft() {
        #expect(throws: (any Error).self) {
            try ProtectedLocalStateCodec.seal(
                ProtectedLocalState(drafts: [reference.roomID: String(repeating: "a", count: 131_073)]), key: vaultKey,
                accountID: account)
        }
    }
}

/// Holds the first key request until the test releases it.
private final class FirstKeyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var first: CheckedContinuation<Data, Never>?
    private var calls = 0
    var hasFirst: Bool { lock.withLock { first != nil } }
    func key() async -> Data {
        await withCheckedContinuation { continuation in
            let hold = lock.withLock {
                calls += 1
                if calls == 1 { first = continuation }
                return calls == 1
            }
            if !hold { continuation.resume(returning: vaultKey) }
        }
    }
    func release() { lock.withLock { first }?.resume(returning: vaultKey) }
}

struct ProtectedLocalStateStoreTests {
    private let root: TemporaryDirectory
    private let store: ProtectedLocalStateStore
    init() throws {
        root = try TemporaryDirectory()
        store = ProtectedLocalStateStore(directory: root.url, keyProvider: { _ in vaultKey })
    }

    @Test("A new account starts empty and saves to a private file not named after the account")
    func savesPrivately() async throws {
        let access = try await store.open(accountID: account)
        #expect(access.state == ProtectedLocalState())
        try await store.save(original, access: access, revision: 1)
        let url = await store.fileURL(account)
        #expect(!url.path.contains(account))
        #expect(try posixPermissions(url) == 0o600)
    }

    @Test("A linked or world-readable vault file is refused")
    func rejectsUnsafeFile() async throws {
        let access = try await store.open(accountID: account)
        try await store.save(original, access: access, revision: 1)
        let url = await store.fileURL(account)
        let link = root.path("symlink.vault")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(throws: (any Error).self) { try ProtectedLocalStateCodec.read(link, key: vaultKey, accountID: account) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try ProtectedLocalStateCodec.read(url, key: vaultKey, accountID: account) }
    }

    @Test("An older save that finishes late does not replace a newer one")
    func newestSaveWins() async throws {
        let access = try await store.open(accountID: account)
        try await store.save(withDraft("newest"), access: access, revision: 2)
        try await store.save(original, access: access, revision: 1)
        #expect(try await store.open(accountID: account).state == withDraft("newest"))
    }

    @Test("Saving with an access from before the account was reopened is refused")
    func staleAccess() async throws {
        let access = try await store.open(accountID: account)
        _ = try await store.open(accountID: account)
        await #expect(throws: ProtectedLocalStateError.staleAccess) {
            try await store.save(original, access: access, revision: 1)
        }
    }

    @Test("Each account has its own file")
    func accountsSeparate() async throws {
        let access = try await store.open(accountID: account)
        try await store.save(original, access: access, revision: 1)
        #expect(try await store.open(accountID: otherAccount).state == ProtectedLocalState())
        #expect(await store.fileURL(otherAccount) != store.fileURL(account))
    }

    @Test("A corrupted vault is never overwritten, and the newest unsaved state is written once it is repaired")
    func corruptionPreservedAndPendingRecovered() async throws {
        let access = try await store.open(accountID: account)
        try await store.save(original, access: access, revision: 1)
        let url = await store.fileURL(account)
        let valid = try Data(contentsOf: url)
        try Data("corrupt protected file".utf8).write(to: url)
        await #expect(throws: ProtectedLocalStateError.invalidData) {
            try await store.save(withDraft("pending"), access: access, revision: 3)
        }
        try await store.save(original, access: access, revision: 2)
        await #expect(throws: ProtectedLocalStateError.invalidData) { try await store.open(accountID: account) }
        #expect(try Data(contentsOf: url) == Data("corrupt protected file".utf8))
        try valid.write(to: url)
        #expect(try await store.open(accountID: account).state == withDraft("pending"))
    }

    @Test("Opening an account whose vault is garbage fails instead of starting empty")
    func garbageVault() async throws {
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        let url = await store.fileURL(otherAccount)
        _ = FileManager.default.createFile(
            atPath: url.path, contents: Data("bad vault".utf8), attributes: [.posixPermissions: 0o600])
        await #expect(throws: ProtectedLocalStateError.invalidData) { try await store.open(accountID: otherAccount) }
    }

    @Test("When an account is opened twice, the earlier open is cancelled and the later one can save")
    func laterOpenWins() async throws {
        let gate = FirstKeyGate()
        let store = ProtectedLocalStateStore(directory: root.path("ordered"), keyProvider: { _ in await gate.key() })
        let first = Task { try await store.open(accountID: account) }
        #expect(await eventually { gate.hasFirst })
        let second = try await store.open(accountID: account)
        gate.release()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await store.save(original, access: second, revision: 1)
    }
}
