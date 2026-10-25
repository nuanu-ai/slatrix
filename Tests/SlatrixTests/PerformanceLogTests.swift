import Foundation
import OSLog
import Testing

@testable import Slatrix

/// What the app writes to the unified log for `scripts/perf-report.sh`.
@MainActor
struct PerformanceLogTests {
    /// Polls this process's log off the main actor: one read takes long enough to stall tests running beside it.
    private nonisolated static func firstMessage(since date: Date, where match: @escaping (String) -> Bool) async
        -> String?
    {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        let predicate = NSPredicate(format: "subsystem == 'ai.nuanu.slatrix' AND category == 'performance'")
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            let entries = try? store.getEntries(at: store.position(date: date), matching: predicate)
            if let found = entries?.lazy.compactMap({ ($0 as? OSLogEntryLog)?.composedMessage }).first(where: match) {
                return found
            }
            await Task.yield()
        }
        return nil
    }

    private func milliseconds(_ message: String) -> Double {
        message.split(separator: " ").first { $0.hasPrefix("ms=") }.flatMap { Double($0.dropFirst(3)) } ?? 0
    }

    @Test("A main-thread stall is logged with its length and the work that ran in it")
    func logsHangs() async throws {
        Performance.watchMainThread()
        let since = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Performance.measure(.timelineProject) { usleep(150_000) } }
        }
        let hang = await Task.detached {
            await Self.firstMessage(since: since) { $0.hasPrefix("hang ") && $0.contains("timeline.project") }
        }.value
        #expect(milliseconds(try #require(hang)) >= 150)
    }
}
