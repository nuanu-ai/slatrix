import Foundation
import Testing

@testable import Slatrix

/// Launch must not wait on the network: a restored session already knows its homeserver.
struct ClientLaunchTests {
    // `.invalid` never resolves, so any request during the build fails it.
    private let unreachable = "https://matrix.example.invalid"

    @Test("Restoring a session builds its client without asking the server anything")
    func restoreSkipsDiscovery() async throws {
        _ = try await MatrixService.clientBuilder(homeserver: unreachable, restoring: true).build()
    }

    @Test("Signing in still discovers the homeserver from what the person typed")
    func signInDiscovers() async {
        await #expect(throws: (any Error).self) {
            _ = try await MatrixService.clientBuilder(homeserver: unreachable, restoring: false).build()
        }
    }
}
