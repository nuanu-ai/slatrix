import Foundation
import Testing

@testable import Slatrix

private typealias Importer = ComposerAttachmentImporter

private let mebibyte = 1_024 * 1_024
private let onePixelPNG = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6qZsAAAAASUVORK5CYII=")!

struct ComposerAttachmentTests {
    @Test("An attached file is queued once as a private copy that later edits to the original do not change")
    func stagesPrivateCopy() async throws {
        let scratch = try TemporaryDirectory()
        let original = try scratch.file("sample.txt")
        let staged = try await Importer.stage(.files([original, original]), existing: [])
        defer { Importer.discard(staged) }
        let copy = try #require(staged.first)
        #expect(staged.count == 1)
        #expect(copy != original && copy.lastPathComponent == "sample.txt")
        #expect(try posixPermissions(copy) == 0o600)
        #expect(try posixPermissions(copy.deletingLastPathComponent()) == 0o700)
        try Data("Changed original".utf8).write(to: original)
        #expect(try Data(contentsOf: copy) == Data("Fixture content\n".utf8))
    }

    @Test("Discarding removes staged copies but never the user's original file")
    func discardKeepsOriginal() async throws {
        let scratch = try TemporaryDirectory()
        let original = try scratch.file("sample.txt")
        let staged = try await Importer.stage(.files([original]), existing: [])
        Importer.discard([original])
        #expect(FileManager.default.fileExists(atPath: original.path))
        Importer.discard(staged)
        #expect(staged.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    enum Rejected: CaseIterable { case folder, missing, remote, symbolicLink, oversized }

    @Test(
        "Folders, missing files, remote URLs, links and files over 100 MiB are not attached",
        arguments: Rejected.allCases)
    func rejectsUnsupportedFiles(kind: Rejected) async throws {
        let scratch = try TemporaryDirectory()
        let input: URL
        switch kind {
        case .folder: input = scratch.url
        case .missing: input = scratch.url.appendingPathComponent("missing.txt")
        case .remote: input = URL(string: "https://example.org/file.txt")!
        case .symbolicLink:
            input = scratch.url.appendingPathComponent("link.txt")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: try scratch.file("target.txt"))
        case .oversized: input = try scratch.sparse("oversized.bin", bytes: 100 * mebibyte + 1)
        }
        await #expect(throws: Importer.Failure.self) { try await Importer.stage(.files([input]), existing: []) }
    }

    @Test("A full queue takes no more files")
    func rejectsWhenQueueIsFull() async throws {
        let scratch = try TemporaryDirectory()
        let original = try scratch.file("sample.txt")
        let queued = try await Importer.stage(.files([original]), existing: [])
        defer { Importer.discard(queued) }
        let full = Array(repeating: queued[0], count: 20)
        await #expect(throws: Importer.Failure.self) { try await Importer.stage(.files([original]), existing: full) }
    }

    @Test("A queue totalling more than 250 MiB is refused")
    func rejectsLargeQueue() throws {
        let scratch = try TemporaryDirectory()
        let large = try scratch.sparse("large.bin", bytes: 90 * mebibyte)
        try Importer.validateQueue([large, large])
        #expect(throws: Importer.Failure.self) { try Importer.validateQueue([large, large, large]) }
    }

    @Test("A pasted PNG is queued as a .png file with its bytes intact")
    func stagesPastedImage() async throws {
        let staged = try await Importer.stage(.image(onePixelPNG, png: true), existing: [])
        defer { Importer.discard(staged) }
        #expect(staged.count == 1 && staged[0].pathExtension == "png")
        #expect(try Data(contentsOf: staged[0]) == onePixelPNG)
    }

    @Test(
        "Pasted data that is not an image of the claimed type is refused",
        arguments: [(Data("not an image".utf8), true), (onePixelPNG, false)])
    func rejectsBadPaste(data: Data, png: Bool) async {
        await #expect(throws: Importer.Failure.self) { try await Importer.stage(.image(data, png: png), existing: []) }
    }

    @Test("A cancelled import stages nothing")
    func cancelledImport() async throws {
        let scratch = try TemporaryDirectory()
        let original = try scratch.file("sample.txt")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Importer.stage(.files([original]), existing: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

struct ComposerAttachmentLeaseTests {
    private func makeFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    @Test("Orphan cleanup keeps a running session's files")
    func keepsLiveSession() throws {
        let scratch = try TemporaryDirectory()
        let base = scratch.url.appendingPathComponent("Leases", isDirectory: true)
        let live = try Importer.Session(in: base)
        let file = live.directory.appendingPathComponent("live.txt")
        try Data("live".utf8).write(to: file)
        withExtendedLifetime(live) {
            #expect(Importer.cleanupOrphans(in: base) == 0)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("Orphan cleanup removes only an abandoned session of ours, without following its links")
    func removesOnlyAbandonedSessions() throws {
        let scratch = try TemporaryDirectory()
        let base = scratch.url.appendingPathComponent("Leases", isDirectory: true)
        let live = try Importer.Session(in: base)
        var abandoned: Importer.Session? = try Importer.Session(in: base)
        let orphan = abandoned!.directory
        let original = try scratch.file("original.txt")
        try FileManager.default.createSymbolicLink(
            at: orphan.appendingPathComponent("original-link"), withDestinationURL: original)
        abandoned = nil

        let unknown = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let unrelated = base.appendingPathComponent("unrelated", isDirectory: true)
        let foreignMarker = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let linkedMarker = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for folder in [unknown, unrelated, foreignMarker, linkedMarker] { try makeFolder(folder) }
        // A marker copied from another session names that session's folder, not this one.
        _ = FileManager.default.createFile(
            atPath: foreignMarker.appendingPathComponent(".lease").path,
            contents: try Data(contentsOf: orphan.appendingPathComponent(".lease")),
            attributes: [.posixPermissions: 0o600])
        try FileManager.default.createSymbolicLink(
            at: linkedMarker.appendingPathComponent(".lease"),
            withDestinationURL: live.directory.appendingPathComponent(".lease"))

        withExtendedLifetime(live) {
            #expect(Importer.cleanupOrphans(in: base) == 1)
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(FileManager.default.fileExists(atPath: original.path))
            for kept in [live.directory, unknown, unrelated, foreignMarker, linkedMarker] {
                #expect(FileManager.default.fileExists(atPath: kept.path), "\(kept.lastPathComponent) was removed")
            }
            #expect(Importer.cleanupOrphans(in: base) == 0)
        }
    }

    @Test("Discarding cannot delete another session's attachment")
    func discardStaysInOwnSession() throws {
        let scratch = try TemporaryDirectory()
        let other = try Importer.Session(in: scratch.url.appendingPathComponent("Leases", isDirectory: true))
        let folder = other.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try makeFolder(folder)
        let file = folder.appendingPathComponent("other.txt")
        try Data("other".utf8).write(to: file)
        withExtendedLifetime(other) {
            Importer.discard([file])
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
