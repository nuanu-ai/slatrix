import Foundation

enum AppPaths {
    // Development builds keep their own data so they never touch the daily-driver app's session or drafts.
    #if DEBUG
    static let folderName = "Slatrix Dev"
    #else
    static let folderName = "Slatrix"
    #endif

    static var applicationSupport: URL { userDirectory(.applicationSupportDirectory) }
    static var caches: URL { userDirectory(.cachesDirectory) }
    static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent(
            "Logs/\(folderName)", isDirectory: true)
    }
    static var temporary: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func userDirectory(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent(
            folderName, isDirectory: true)
    }
}
