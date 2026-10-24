import CryptoKit
import Darwin
import Foundation
import Testing

@testable import Slatrix

/// Fails the next store write at the armed point.
private final class DiskFault: @unchecked Sendable {
    struct Injected: Error {}
    private let lock = NSLock()
    private var next: AttachmentDraftStore.FaultPoint?
    func arm(_ point: AttachmentDraftStore.FaultPoint) { lock.withLock { next = point } }
    func call(_ point: AttachmentDraftStore.FaultPoint) throws {
        try lock.withLock {
            guard next == point else { return }
            next = nil
            throw Injected()
        }
    }
}

/// Holds each key request until the test answers it.
private final class KeyRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<Data, Never>?] = []
    var count: Int { lock.withLock { pending.count } }
    func key() async -> Data {
        await withCheckedContinuation { continuation in lock.withLock { pending.append(continuation) } }
    }
    func answer(_ index: Int) {
        let continuation = lock.withLock {
            defer { pending[index] = nil }
            return pending[index]
        }
        continuation?.resume(returning: AttachmentDraftStoreTests.key)
    }
}

@MainActor
private func expectError(
    _ expected: AttachmentDraftError, sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("expected \(expected)", sourceLocation: sourceLocation)
    } catch {
        #expect(error as? AttachmentDraftError == expected, sourceLocation: sourceLocation)
    }
}

@MainActor
struct AttachmentDraftStoreTests {
    nonisolated static let key = Data(repeating: 0x51, count: 32)
    private let account = "@alice:example.org"
    private let other = "@bob:example.org"
    private let address = AttachmentDraftAddress(roomID: "!room:example.org")
    private let plaintext = Data("PRIVATE-ATTACHMENT-FIXTURE-7D45\n".utf8)
    private let root: TemporaryDirectory
    private let original: URL
    private let second: URL

    init() throws {
        root = try TemporaryDirectory()
        original = try root.file("Private fixture name.txt", plaintext)
        second = try root.file("second.txt", Data("Second file".utf8))
    }

    private func store(
        _ name: String = "vault", budget: Int = AttachmentDraftStore.maximumAccountBytes, fault: DiskFault? = nil,
        key: Data = key
    ) -> AttachmentDraftStore {
        AttachmentDraftStore(
            directory: root.path(name), budgetBytes: budget, keyProvider: { _ in key },
            fault: { point in try fault?.call(point) })
    }
    /// The vault keeps each account in a folder named by the SHA-256 of its user ID.
    private func folder(_ name: String = "vault", _ user: String? = nil) -> URL {
        let hash = SHA256.hash(data: Data((user ?? account).utf8)).map { String(format: "%02x", $0) }.joined()
        return root.path(name).appendingPathComponent(hash)
    }
    private func blobs(_ directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "blob" }.sorted { $0.path < $1.path }
    }
    private func manifest(_ name: String = "vault", _ user: String? = nil) -> URL {
        folder(name, user).appendingPathComponent("manifest.vault")
    }

    @Test("A saved draft keeps neither file bytes nor file names readable on disk")
    func encryptedAtRest() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        let saved = try await store.save(urls: [original], address: address, access: access, revision: 1)
        #expect(saved.files.map(\.phase) == [.ready])
        let blob = try #require(try blobs(folder()).first)
        #expect(try Data(contentsOf: blob).range(of: plaintext) == nil)
        #expect(try Data(contentsOf: manifest()).range(of: Data("Private fixture name".utf8)) == nil)
        #expect(try posixPermissions(blob) == 0o600)
    }

    @Test("Saving an unchanged file again keeps its ID and ciphertext")
    func unchangedFileReused() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        let first = try await store.save(urls: [original], address: address, access: access, revision: 1)
        let blob = try #require(try blobs(folder()).first)
        let ciphertext = try Data(contentsOf: blob)
        let again = try await store.save(urls: [original], address: address, access: access, revision: 2)
        #expect(again.files[0].id == first.files[0].id)
        #expect(try Data(contentsOf: blob) == ciphertext)
    }

    @Test("An older revision cannot overwrite a newer saved queue")
    func staleRevision() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [original], address: address, access: access, revision: 2)
        await expectError(.staleRevision) {
            _ = try await store.save(urls: [], address: address, access: access, revision: 1)
        }
    }

    @Test(
        "A file that was sending when the app quit comes back as interrupted, from its saved bytes, in a private copy")
    func interruptedSendRestored() async throws {
        let first = store()
        let access = try await first.open(accountID: account)
        _ = try await first.save(urls: [original], address: address, access: access, revision: 1)
        try await first.markSending(url: original, address: address, access: access, revision: 2)
        await first.close(access: access)
        try Data("Original changed after saving".utf8).write(to: original)

        let reopened = store()
        let reopenedAccess = try await reopened.open(accountID: account)
        let queue = try #require(try await reopened.restore(access: reopenedAccess).first)
        let file = try #require(queue.files.first)
        let copy = try #require(file.url)
        #expect(file.phase == .interrupted && queue.revision == 2)
        #expect(copy != original)
        #expect(try Data(contentsOf: copy) == plaintext)
        #expect(try posixPermissions(copy) == 0o600)
        await expectError(.staleAccess) {
            _ = try await reopened.save(urls: [], address: address, access: access, revision: 3)
        }
    }

    @Test("A confirmed send removes the file for good; a late snapshot cannot bring it back")
    func confirmedSendRemovesFile() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [original], address: address, access: access, revision: 1)
        let blob = try #require(try blobs(folder()).first)
        try await store.markSending(url: original, address: address, access: access, revision: 2)
        try await store.confirmSent(url: original, address: address, access: access, revision: 3)
        let queue = try #require(try await store.restore(access: access).first)
        #expect(queue.files.isEmpty && queue.revision == 3)
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        await expectError(.staleRevision) {
            _ = try await store.save(urls: [original], address: address, access: access, revision: 2)
        }
    }

    @Test("Closing removes the private copies it handed out but never the original file")
    func closeRemovesCopies() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [original], address: address, access: access, revision: 1)
        await store.close(access: access)
        let reopened = try await store.open(accountID: account)
        let copy = try #require(try await store.restore(access: reopened).first?.files.first?.url)
        await store.close(access: reopened)
        #expect(!FileManager.default.fileExists(atPath: copy.path))
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test("One account's access cannot read another account's drafts")
    func accountsIsolated() async throws {
        let store = store()
        let alice = try await store.open(accountID: account)
        _ = try await store.open(accountID: other)
        let forged = AttachmentDraftAccess(accountID: other, generation: alice.generation)
        await expectError(.staleAccess) { _ = try await store.restore(access: forged) }
    }

    @Test("A second app instance cannot open an account's drafts while the first holds them")
    func leaseProtectsAccount() async throws {
        let first = store()
        let competitor = store()
        let access = try await first.open(accountID: account)
        await expectError(.inUse) { _ = try await competitor.open(accountID: account) }
        await first.close(access: access)
        let afterClose = try await competitor.open(accountID: account)
        await competitor.close(access: afterClose)
    }

    @Test("A manifest copied from another account is refused and left in place, even under the same key")
    func foreignManifestRefused() async throws {
        let store = store()
        let alice = try await store.open(accountID: account)
        let bob = try await store.open(accountID: other)
        _ = try await store.save(urls: [second], address: address, access: alice, revision: 1)
        await store.close(access: bob)
        await store.close(access: alice)
        let foreign = try Data(contentsOf: manifest())
        try foreign.write(to: manifest("vault", other))
        await expectError(.invalidData) { _ = try await store.open(accountID: other) }
        #expect(try Data(contentsOf: manifest("vault", other)) == foreign)
    }

    @Test("Damaged or missing saved files stay listed as unavailable until removed")
    func damagedFilesStayListed() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [original, second], address: address, access: access, revision: 1)
        await store.close(access: access)
        let saved = try blobs(folder())
        try Data("damaged".utf8).write(to: saved[0])
        try FileManager.default.removeItem(at: saved[1])

        let reopened = try await store.open(accountID: account)
        let files = try #require(try await store.restore(access: reopened).first?.files)
        #expect(files.count == 2 && files.allSatisfy { $0.url == nil && $0.errorMessage != nil })
        let kept = try await store.save(urls: [], address: address, access: reopened, revision: 2)
        #expect(kept.files.count == 2 && FileManager.default.fileExists(atPath: saved[0].path))
        try await store.remove(fileID: kept.files[0].id, address: address, access: reopened, revision: 3)
        try await store.remove(fileID: kept.files[1].id, address: address, access: reopened, revision: 4)
        #expect(try await store.restore(access: reopened).first?.files.isEmpty == true)
    }

    @Test("A manifest in an unknown format is refused and never overwritten")
    func unknownManifestPreserved() async throws {
        let store = store()
        await store.close(access: try await store.open(accountID: account))
        try Data("unknown-version".utf8).write(to: manifest())
        await expectError(.invalidData) { _ = try await store.open(accountID: account) }
        #expect(try Data(contentsOf: manifest()) == Data("unknown-version".utf8))
    }

    @Test("Going over the account budget keeps the previously saved queue")
    func budgetKeepsOldQueue() async throws {
        let store = store(budget: 4_096)
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [second], address: address, access: access, revision: 1)
        let larger = try root.file("larger.bin", Data(repeating: 7, count: 8_192))
        await expectError(.budget) {
            _ = try await store.save(urls: [larger], address: address, access: access, revision: 2)
        }
        #expect(try await store.restore(access: access).first?.files.map(\.filename) == ["second.txt"])
    }

    @Test("A queue holds at most 20 files")
    func fileCountBounded() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        await expectError(.budget) {
            _ = try await store.save(
                urls: Array(repeating: second, count: 21), address: address, access: access, revision: 1)
        }
    }

    @Test("Files over 100 MiB, or a queue over 250 MiB, are refused before anything is encrypted")
    func sizeLimits() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        let huge = try root.sparse("huge.bin", bytes: 100 * 1_024 * 1_024 + 1)
        await expectError(.budget) {
            _ = try await store.save(urls: [huge], address: address, access: access, revision: 1)
        }
        let large = try (1...3).map { try root.sparse("large-\($0).bin", bytes: 90 * 1_024 * 1_024) }
        await expectError(.budget) {
            _ = try await store.save(urls: large, address: address, access: access, revision: 1)
        }
        #expect(try blobs(folder()).isEmpty)
    }

    @Test("A cancelled save throws instead of saving")
    func cancelledSave() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        let save = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.save(urls: [second], address: address, access: access, revision: 1)
        }
        await #expect(throws: CancellationError.self) { try await save.value }
    }

    @Test("A disk failure before the manifest commits removes only the new ciphertext")
    func failureBeforeCommit() async throws {
        let fault = DiskFault()
        let store = store(fault: fault)
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [original], address: address, access: access, revision: 1)
        let before = try blobs(folder())
        fault.arm(.beforeManifestCommit)
        await expectError(.unavailable) {
            _ = try await store.save(urls: [original, second], address: address, access: access, revision: 2)
        }
        #expect(try blobs(folder()) == before)
    }

    @Test("A disk failure after the manifest is renamed keeps every file it references")
    func failureAfterRename() async throws {
        let fault = DiskFault()
        let store = store(fault: fault)
        let access = try await store.open(accountID: account)
        fault.arm(.afterManifestRename)
        await expectError(.unavailable) {
            _ = try await store.save(urls: [original, second], address: address, access: access, revision: 1)
        }
        let files = try #require(try await store.restore(access: access).first?.files)
        #expect(files.count == 2 && files.allSatisfy { $0.url != nil })
    }

    @Test("Retrying a confirmation whose cleanup failed finishes it once, without another send")
    func confirmationRetryIsIdempotent() async throws {
        let fault = DiskFault()
        let store = store(fault: fault)
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [original, second], address: address, access: access, revision: 1)
        try await store.markSending(url: original, address: address, access: access, revision: 2)
        fault.arm(.afterManifestRename)
        await expectError(.unavailable) {
            try await store.confirmSent(url: original, address: address, access: access, revision: 3)
        }
        try await store.confirmSent(url: original, address: address, access: access, revision: 4)
        try await store.confirmSent(url: original, address: address, access: access, revision: 5)
        let queue = try #require(try await store.restore(access: access).first)
        #expect(queue.files.map(\.filename) == ["second.txt"] && queue.revision == 5)
    }

    @Test("Opening collects ciphertext left by a crash and keeps unknown files with a warning")
    func reapsCrashLeftovers() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [second], address: address, access: access, revision: 1)
        let blob = try #require(try blobs(folder()).first)
        let bytes = try Data(contentsOf: blob)
        _ = try await store.save(urls: [], address: address, access: access, revision: 2)
        await store.close(access: access)
        _ = FileManager.default.createFile(atPath: blob.path, contents: bytes, attributes: [.posixPermissions: 0o600])
        let unknown = folder().appendingPathComponent("unknown.data")
        try Data("keep me".utf8).write(to: unknown)

        let reopened = try await store.open(accountID: account)
        #expect(!FileManager.default.fileExists(atPath: blob.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path) && reopened.warningMessage != nil)
    }

    @Test("A file changed since it was saved cannot silently replace its saved snapshot")
    func changedFileRefused() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        let mutable = try root.file("mutable.txt", Data("first".utf8))
        _ = try await store.save(urls: [mutable], address: address, access: access, revision: 1)
        try Data("changed".utf8).write(to: mutable)
        await expectError(.changedFile) {
            _ = try await store.save(urls: [mutable], address: address, access: access, revision: 2)
        }
    }

    @Test("Reopening the store invalidates the previous access")
    func reopenInvalidatesOldAccess() async throws {
        let store = store()
        let old = try await store.open(accountID: account)
        let saved = try await store.save(urls: [second], address: address, access: old, revision: 1)
        _ = try await store.open(accountID: account)
        await expectError(.staleAccess) {
            try await store.remove(fileID: saved.files[0].id, address: address, access: old, revision: 2)
        }
    }

    @Test("A room and its thread keep separate queues, and restored copies can all be discarded")
    func roomAndThreadQueues() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        let thread = AttachmentDraftAddress(roomID: address.roomID, threadRootID: "$thread")
        _ = try await store.save(urls: [original], address: address, access: access, revision: 1)
        _ = try await store.save(urls: [second], address: thread, access: access, revision: 1)
        await store.close(access: access)
        let reopened = try await store.open(accountID: account)
        let queues = try await store.restore(access: reopened)
        #expect(Set(queues.map(\.address)) == [address, thread])
        let copies = queues.flatMap { $0.files.compactMap(\.url) }
        #expect(copies.count == 2)
        await store.discardStaged(access: reopened)
        #expect(copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test("A key that arrives for an older open cannot replace a newer one")
    func lateKeyLoses() async throws {
        let requests = KeyRequests()
        let store = AttachmentDraftStore(directory: root.path("pending"), keyProvider: { _ in await requests.key() })
        let older = Task { try await store.open(accountID: account) }
        #expect(await eventually { requests.count == 1 })
        let newer = Task { try await store.open(accountID: account) }
        #expect(await eventually { requests.count == 2 })
        requests.answer(0)
        await expectError(.staleAccess) { _ = try await older.value }
        requests.answer(1)
        await store.close(access: try await newer.value)
    }

    @Test("A deleted manifest for an account with drafts is refused, not treated as a fresh start")
    func missingManifestRefused() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [second], address: address, access: access, revision: 1)
        await store.close(access: access)
        let blob = try #require(try blobs(folder()).first)
        try FileManager.default.removeItem(at: manifest())
        await expectError(.invalidData) { _ = try await store.open(accountID: account) }
        #expect(FileManager.default.fileExists(atPath: blob.path))
    }

    @Test("Deleting the manifest of an open, empty account does not reset it")
    func missingActiveManifestRefused() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        try FileManager.default.removeItem(at: manifest())
        await expectError(.invalidData) {
            _ = try await store.save(urls: [second], address: address, access: access, revision: 1)
        }
    }

    @Test("A vault readable by others is refused and its permissions are left alone")
    func unsafePermissionsRefused() async throws {
        let store = store()
        await store.close(access: try await store.open(accountID: account))
        #expect(chmod(manifest().path, 0o644) == 0)
        await expectError(.invalidData) { _ = try await store.open(accountID: account) }
        #expect(try posixPermissions(manifest()) == 0o644)
    }

    @Test("The wrong key cannot open saved drafts")
    func wrongKeyRefused() async throws {
        let store = store()
        let access = try await store.open(accountID: account)
        _ = try await store.save(urls: [second], address: address, access: access, revision: 1)
        await store.close(access: access)
        await expectError(.invalidData) {
            _ = try await self.store(key: Data(repeating: 9, count: 32)).open(accountID: account)
        }
    }
}
