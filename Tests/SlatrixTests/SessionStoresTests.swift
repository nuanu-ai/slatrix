import Foundation
import Testing

@testable import Slatrix

struct SessionStoresTests {
    private let temp: TemporaryDirectory
    init() throws { temp = try TemporaryDirectory() }

    private func makeRoots() throws -> [URL] {
        let roots = [temp.path("support"), temp.path("caches")]
        for root in roots { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        return roots
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    @Test("Creating a store makes private data, cache and search-index folders")
    func createsPrivateFolders() throws {
        let roots = try makeRoots()
        let store = try SessionStores.create(UUID().uuidString, roots: roots)
        for folder in [store.data, store.cache, store.searchIndex] {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o700)
        }
    }

    @Test("Removing a store deletes its data and cache folders")
    func removesOneStore() throws {
        let roots = try makeRoots()
        let id = UUID().uuidString
        let store = try SessionStores.create(id, roots: roots)
        SessionStores.remove(id, roots: roots)
        #expect(!exists(store.data) && !exists(store.cache))
    }

    @Test("The launch sweep keeps the signed-in store and anything it did not create")
    func sweepKeepsCurrentStore() throws {
        let roots = try makeRoots()
        let current = UUID().uuidString
        let orphan = UUID().uuidString
        let kept = try SessionStores.create(current, roots: roots)
        let leaked = try SessionStores.create(orphan, roots: roots)
        let foreign = roots[0].appendingPathComponent("Sessions/notes")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        SessionStores.removeAll(except: current, roots: roots)
        #expect(exists(kept.data) && exists(kept.cache) && exists(foreign))
        #expect(!exists(leaked.data) && !exists(leaked.cache))
        SessionStores.removeAll(except: nil, roots: roots)
        #expect(!exists(kept.data) && exists(foreign))
    }
}
