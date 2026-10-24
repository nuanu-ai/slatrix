import Foundation

/// A private scratch folder per test, removed when the test releases it.
final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "SlatrixTests-" + UUID().uuidString, isDirectory: true)
    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    func path(_ name: String) -> URL { url.appendingPathComponent(name) }

    func file(_ name: String, _ contents: Data = Data("Fixture content\n".utf8)) throws -> URL {
        let file = path(name)
        try contents.write(to: file)
        return file
    }

    /// A file that reports `bytes` in size without using the disk space.
    func sparse(_ name: String, bytes: Int) throws -> URL {
        let file = path(name)
        _ = FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
        return file
    }
}

func posixPermissions(_ url: URL) throws -> Int? {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
}
