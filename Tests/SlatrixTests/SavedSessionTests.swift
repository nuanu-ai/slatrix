import Foundation
import Testing

@testable import Slatrix

/// The saved session and vault keys, each test's in a file of its own.
@MainActor
struct SavedSessionTests {
    private let folder: TemporaryDirectory
    private let credentials: SecureSessionStore
    private let session = StoredSession(
        accessToken: "synthetic-token", userId: "@owner:example.org", deviceId: "FIXTURE",
        homeserverUrl: "https://example.org", storeID: UUID().uuidString, storeKey: Data(repeating: 0x31, count: 32))

    init() throws {
        folder = try TemporaryDirectory()
        credentials = SecureSessionStore(file: folder.path("credentials.json"))
    }

    private var storeRoots: [URL] { [folder.path("support"), folder.path("caches")] }

    @Test("Leaving the sample workspace runs none of sign-out, whatever a failed start left installed")
    func leavingPreview() async throws {
        try credentials.save(session)
        let deviceKeys = try SessionStores.create(session.storeID, roots: storeRoots).data
            .appendingPathComponent("device-keys")
        try Data("device keys".utf8).write(to: deviceKeys)
        let client = FakeClient()
        let matrix = MatrixService(credentials: credentials, storeRoots: storeRoots)
        matrix.configureRoomOpenForChecks(
            client: client, roomList: FakeRoomListService(), user: ChatUser(id: session.userId, name: "Owner"),
            storeID: session.storeID)
        matrix.enterPreview()
        try await matrix.logout()
        #expect(!client.loggedOut)
        #expect(try credentials.load() == session)
        #expect(try Data(contentsOf: deviceKeys) == Data("device keys".utf8))
        #expect(matrix.status == .signedOut && matrix.user == nil && !matrix.isPreview)
    }

    @Test("Restoring over an empty saved record sweeps the service's own SDK store folders and no others")
    func restoreKeepsOtherRoots() async throws {
        let orphan = try SessionStores.create(UUID().uuidString, roots: storeRoots)
        let planted = try SessionStores.create(
            UUID().uuidString, roots: [folder.path("other-support"), folder.path("other-caches")])
        let matrix = MatrixService(credentials: credentials, storeRoots: storeRoots)
        await matrix.restore()
        #expect(matrix.status == .signedOut)
        #expect(!FileManager.default.fileExists(atPath: orphan.data.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.cache.path))
        #expect(FileManager.default.fileExists(atPath: planted.data.path))
    }

    struct Damaged: CustomTestStringConvertible, Sendable {
        var name: String
        var record: String
        var kept: [String: Data]
        var testDescription: String { name }

        static let key = Data(repeating: 0x42, count: 32)
        static let all = [
            Damaged(name: "Cut short", record: #"{"version":1,"vaultKeys":{"@keep:exa"#, kept: [:]),
            Damaged(
                name: "A bad session and bad keys beside a good one",
                record: """
                    {"version":1,"session":{"userId":"nobody"},"vaultKeys":{"@keep:example.org":"\(key.base64EncodedString())",\
                    "@short:example.org":"QkJC","not an account":"\(key.base64EncodedString())"}}
                    """,
                kept: ["@keep:example.org": key]),
        ]
    }

    private func savedKeys() throws -> [String: Data] {
        try SecureSessionStore.decodeEnvelope(Data(contentsOf: folder.path("credentials.json"))).vaultKeys
    }

    @Test("Signing in over a damaged saved record keeps every vault key that still reads", arguments: Damaged.all)
    func signInOverDamaged(_ damaged: Damaged) throws {
        _ = try folder.file("credentials.json", Data(damaged.record.utf8))
        try credentials.save(session)
        #expect(try credentials.load() == session)
        #expect(try savedKeys() == damaged.kept)
    }

    @Test(
        "Finishing sign-out over a damaged saved record keeps every vault key that still reads",
        arguments: Damaged.all)
    func finishSignOutOverDamaged(_ damaged: Damaged) throws {
        _ = try folder.file("credentials.json", Data(damaged.record.utf8))
        try credentials.delete()
        #expect(try credentials.load() == nil)
        #expect(try savedKeys() == damaged.kept)
    }

    @Test("A saved record from a newer build is never rewritten", arguments: ["2", "2.0", "9223372036854775808"])
    func newerRecordKept(version: String) throws {
        let record = Data(#"{"version":\#(version),"vaultKeys":{"@keep:example.org":"QkJC"}}"#.utf8)
        let file = try folder.file("credentials.json", record)
        #expect(throws: (any Error).self) { try credentials.load() }
        #expect(try Data(contentsOf: file) == record)
        #expect(throws: (any Error).self) { try credentials.save(session) }
        #expect(try Data(contentsOf: file) == record)
        #expect(throws: (any Error).self) { try credentials.delete() }
        #expect(try Data(contentsOf: file) == record)
        #expect(throws: (any Error).self) { try credentials.localStateKey(accountID: session.userId) }
        #expect(try Data(contentsOf: file) == record)
    }

    @Test(
        "A record whose version isn't a whole number above this build's is damage, so signing in and out repair it",
        arguments: ["false", "0", #""2""#])
    func otherVersionRepaired(version: String) throws {
        let key = Damaged.key.base64EncodedString()
        let record = Data(#"{"version":\#(version),"vaultKeys":{"@keep:example.org":"\#(key)"}}"#.utf8)
        _ = try folder.file("credentials.json", record)
        #expect(throws: (any Error).self) { try credentials.load() }
        try credentials.save(session)
        #expect(try credentials.load() == session)
        #expect(try savedKeys() == ["@keep:example.org": Damaged.key])
        _ = try folder.file("credentials.json", record)
        try credentials.delete()
        #expect(try savedKeys() == ["@keep:example.org": Damaged.key])
    }

    private let room = "!design:example.org"
    private var vault: URL {
        ProtectedLocalStateStore.fileURL(session.userId, in: ProtectedLocalStateStore.directory(in: folder.url))
    }
    private var attachmentFolder: URL {
        AttachmentDraftStore.accountDirectory(session.userId, in: AttachmentDraftStore.directory(in: folder.url))
    }

    private var manifest: URL { attachmentFolder.appendingPathComponent("manifest.vault") }

    /// Every copy of `url` set aside beside it.
    private func asideCopies(of url: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        return names.filter { $0.hasPrefix(url.lastPathComponent + ".set-aside-") }
            .map { url.deletingLastPathComponent().appendingPathComponent($0) }
    }
    private func asideVaults() throws -> Set<Data> { try Set(asideCopies(of: vault).map { try Data(contentsOf: $0) }) }
    private func asideManifests() throws -> Set<Data> {
        try Set(
            asideCopies(of: attachmentFolder).map { try Data(contentsOf: $0.appendingPathComponent("manifest.vault")) })
    }

    /// The drafts vault and attachment drafts as a fresh launch opens them, keyed by this test's record.
    private func stores() -> (ProtectedLocalStateStore, AttachmentDraftStore) {
        let key: @Sendable (String) async throws -> Data = { [credentials] in
            try credentials.localStateKey(accountID: $0)
        }
        return (
            ProtectedLocalStateStore(directory: ProtectedLocalStateStore.directory(in: folder.url), keyProvider: key),
            AttachmentDraftStore(directory: AttachmentDraftStore.directory(in: folder.url), keyProvider: key)
        )
    }

    /// Saves a draft and an attachment draft, and returns the sealed vault and attachment manifest.
    private func saveDrafts(_ text: String) async throws -> (Data, Data) {
        let (drafts, attachments) = stores()
        let access = try await drafts.open(accountID: session.userId)
        try await drafts.save(ProtectedLocalState(drafts: [room: text]), access: access, revision: 1)
        let files = try await attachments.open(accountID: session.userId)
        _ = try await attachments.save(
            urls: [folder.file(text + ".txt")], address: AttachmentDraftAddress(roomID: room), access: files,
            revision: 1)
        await attachments.close(access: files)
        return try (Data(contentsOf: vault), Data(contentsOf: manifest))
    }

    /// The record loses the account's key, as when Keychain loses it, and the account signs in again.
    private func loseKey() throws {
        try FileManager.default.removeItem(at: folder.path("credentials.json"))
        try credentials.save(session)
    }

    @Test("A key made anew sets aside what the lost one sealed, so drafts and attachment drafts open empty")
    func lostKeySetsAside() async throws {
        try credentials.save(session)
        let (sealed, sealedManifest) = try await saveDrafts("Before")
        try loseKey()

        let (drafts, attachments) = stores()
        let access = try await drafts.open(accountID: session.userId)
        #expect(access.state == ProtectedLocalState())
        let files = try await attachments.open(accountID: session.userId)
        #expect(try await attachments.restore(access: files).isEmpty)
        #expect(try asideVaults() == [sealed])
        #expect(try asideManifests() == [sealedManifest])

        try await drafts.save(ProtectedLocalState(drafts: [room: "After"]), access: access, revision: 1)
        #expect(try await stores().0.open(accountID: session.userId).state.drafts == [room: "After"])
    }

    @Test("Losing a key twice keeps both set-aside copies, each as it was")
    func setAsideTwiceKeepsBoth() async throws {
        try credentials.save(session)
        let first = try await saveDrafts("First")
        try loseKey()
        let second = try await saveDrafts("Second")
        try loseKey()

        _ = try await stores().0.open(accountID: session.userId)
        #expect(try asideVaults() == [first.0, second.0])
        #expect(try asideManifests() == [first.1, second.1])
    }

    @Test("Something already at a set-aside name neither stops recovery nor changes")
    func takenNameLeftAlone() async throws {
        try credentials.save(session)
        _ = try await saveDrafts("Before")
        let folderThere = vault.appendingPathExtension("set-aside")
        try FileManager.default.createDirectory(at: folderThere, withIntermediateDirectories: false)
        try Data("folder".utf8).write(to: folderThere.appendingPathComponent("inside"))
        let fileThere = URL(fileURLWithPath: attachmentFolder.path + ".set-aside")
        try Data("file".utf8).write(to: fileThere)
        try loseKey()

        let (drafts, attachments) = stores()
        #expect(try await drafts.open(accountID: session.userId).state == ProtectedLocalState())
        _ = try await attachments.open(accountID: session.userId)
        #expect(try Data(contentsOf: folderThere.appendingPathComponent("inside")) == Data("folder".utf8))
        #expect(try Data(contentsOf: fileThere) == Data("file".utf8))
    }

    @Test("Recovery refuses a drafts folder reached through a link, and every file stays where it was")
    func linkedFolderRefused() async throws {
        try credentials.save(session)
        let (sealed, sealedManifest) = try await saveDrafts("Before")
        let elsewhere = folder.path("elsewhere")
        try FileManager.default.moveItem(at: vault.deletingLastPathComponent(), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: vault.deletingLastPathComponent(), withDestinationURL: elsewhere)
        let earlier = try folder.file("elsewhere/" + vault.lastPathComponent + ".set-aside", Data("earlier".utf8))
        try loseKey()

        await #expect(throws: (any Error).self) { try await stores().0.open(accountID: session.userId) }
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent(vault.lastPathComponent)) == sealed)
        #expect(try Data(contentsOf: earlier) == Data("earlier".utf8))
        #expect(try Data(contentsOf: manifest) == sealedManifest)
    }

    @Test("While attachment drafts are open elsewhere, recovery moves nothing")
    func busyAttachmentsMoveNothing() async throws {
        try credentials.save(session)
        let (sealed, sealedManifest) = try await saveDrafts("Before")
        let holder = stores().1
        let held = try await holder.open(accountID: session.userId)
        try loseKey()

        await #expect(throws: (any Error).self) { try await stores().0.open(accountID: session.userId) }
        #expect(try Data(contentsOf: vault) == sealed)
        #expect(try Data(contentsOf: manifest) == sealedManifest)
        await holder.close(access: held)
    }

    @Test("A first sign-in on a clean Mac has nothing to set aside")
    func firstSignInSetsNothingAside() async throws {
        try credentials.save(session)
        let (drafts, attachments) = stores()
        _ = try await drafts.open(accountID: session.userId)
        _ = try await attachments.open(accountID: session.userId)
        let paths = try FileManager.default.subpathsOfDirectory(atPath: folder.url.path)
        #expect(!paths.contains { $0.contains(".set-aside") })
    }

    @Test("A vault that won't open under the key it still has fails as before, and nothing is set aside")
    func damagedVaultWithItsKeyKept() async throws {
        try credentials.save(session)
        var sealed = try await saveDrafts("Before").0
        sealed[sealed.count - 1] ^= 1
        try sealed.write(to: vault)
        await #expect(throws: (any Error).self) { try await stores().0.open(accountID: session.userId) }
        #expect(try Data(contentsOf: vault) == sealed)
        #expect(try asideCopies(of: vault).isEmpty)
    }
}
