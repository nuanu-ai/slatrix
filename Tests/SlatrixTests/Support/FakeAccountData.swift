import Foundation
import MatrixRustSDK

/// One account's Later on the server, as this device's SDK reads, hears and writes it.
final class LaterClient: Client, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [RawAccountDataListener] = []
    private var content: String?
    private var failing = false
    /// Every read of the server, and whether it failed.
    let reads = Recorder<Bool>()
    /// Every write tried, whether or not it reached the server.
    let attempts = Recorder<String>()
    /// The type every read, write and subscription named.
    let types = Recorder<String>()
    /// Holds a write's reply after it lands, until the test releases it.
    let replies = Gate()
    init(server: String? = nil) {
        content = server
        super.init(noHandle: .init())
    }
    required init(unsafeFromHandle handle: UInt64) { fatalError("fake only") }
    /// What the account holds: the last write to land, or the last list a sync brought.
    var server: String? { lock.withLock { content } }
    var failsWrites: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
    private var failingReads = false
    var failsReads: Bool {
        get { lock.withLock { failingReads } }
        set { lock.withLock { failingReads = newValue } }
    }
    /// The device's store before its first sync, as after signing in: nothing it can trust yet.
    override func accountData(eventType: String) async throws -> String? { nil }
    override func fetchAccountData(eventType: String) async throws -> String? {
        types.append(eventType)
        let fails = failsReads
        reads.append(fails)
        if fails { throw ClientError.Generic(msg: "fixture can't reach the server", details: nil) }
        return lock.withLock { content }
    }
    override func observeRawAccountDataEvent(eventType: String, listener: RawAccountDataListener) -> TaskHandle {
        types.append(eventType)
        lock.withLock { listeners.append(listener) }
        return FakeCancellableHandle(noHandle: .init())
    }
    override func setAccountData(eventType: String, content: String) async throws {
        types.append(eventType)
        // Decided before the attempt shows, so a test that sees a failed attempt knows it failed.
        let fails = failsWrites
        attempts.append(content)
        if fails { throw ClientError.Generic(msg: "fixture is offline", details: nil) }
        lock.withLock { self.content = content }
        await replies.wait()
    }
    /// Another device's write, which this device doesn't hear while it's offline.
    func land(_ content: String) { lock.withLock { self.content = content } }
    /// A sync bringing what another device wrote.
    func sync(_ content: String) {
        let current = lock.withLock {
            self.content = content
            return listeners
        }
        for listener in current { listener.onChange(content: content) }
    }
}
