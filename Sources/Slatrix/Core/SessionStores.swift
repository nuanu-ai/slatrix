import Foundation

/// The SDK's encrypted store, cache and search index for one sign-in, named by its store ID.
enum SessionStores {
    struct Folders {
        let data: URL
        let cache: URL
        let searchIndex: URL
    }
    static var roots: [URL] { [AppPaths.applicationSupport, AppPaths.caches] }

    static func create(_ storeID: String, roots: [URL] = roots) throws -> Folders {
        let folders = Folders(
            data: folder(storeID, in: roots[0]), cache: folder(storeID, in: roots[1]),
            searchIndex: folder(storeID, in: roots[0]).appendingPathComponent("search-index", isDirectory: true))
        for url in [folders.data, folders.cache, folders.searchIndex] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return folders
    }

    // Best effort: whatever survives is swept at the next launch.
    static func remove(_ storeID: String, roots: [URL] = roots) {
        for root in roots { try? FileManager.default.removeItem(at: folder(storeID, in: root)) }
    }

    /// Deletes stores left by failed sign-ins and earlier accounts. Only store-ID folders are touched.
    static func removeAll(except storeID: String?, roots: [URL] = roots) {
        for root in roots {
            let parent = root.appendingPathComponent("Sessions", isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            for name in names where UUID(uuidString: name) != nil && name != storeID {
                try? FileManager.default.removeItem(at: parent.appendingPathComponent(name, isDirectory: true))
            }
        }
    }

    private static func folder(_ storeID: String, in root: URL) -> URL {
        root.appendingPathComponent("Sessions/\(storeID)", isDirectory: true)
    }
}
