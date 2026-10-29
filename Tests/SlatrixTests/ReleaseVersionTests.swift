import Foundation
import Testing

/// Sparkle orders updates by the bundle version, so a release tag that maps to a bad version strands every user.
struct ReleaseVersionTests {
    private static let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/version-from-tag.sh")

    private func run(_ tag: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = Self.script
        process.arguments = [tag]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // capability: app.updates
    @Test("A release tag becomes the bundle version", arguments: [("v1.2.3", "1.2.3\n"), ("v0.10.0", "0.10.0\n")])
    func releaseTag(tag: String, version: String) throws {
        let result = try run(tag)
        #expect(result.status == 0)
        #expect(result.output == version)
    }

    @Test("A tag that is not vMAJOR.MINOR.PATCH stops the release", arguments: ["1.2.3", "v1.2", "v1.2.3-beta.1", ""])
    func malformedTag(tag: String) throws {
        let result = try run(tag)
        #expect(result.status != 0)
        #expect(result.output.isEmpty)
    }
}
