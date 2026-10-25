import Foundation
import OSLog
import Testing

@testable import Slatrix

/// What the app writes to the unified log for `scripts/perf-report.sh`.
@MainActor
struct PerformanceLogTests {
    private func messages(in store: OSLogStore, since date: Date) throws -> [String] {
        try store.getEntries(
            at: store.position(date: date),
            matching: NSPredicate(format: "subsystem == 'ai.nuanu.slatrix' AND category == 'performance'")
        ).compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
    }

    private func milliseconds(_ message: String) -> Double {
        message.split(separator: " ").first { $0.hasPrefix("ms=") }.flatMap { Double($0.dropFirst(3)) } ?? 0
    }

    @Test("A main-thread stall is logged with its length and the work that ran in it")
    func logsHangs() async throws {
        Performance.watchMainThread()
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let since = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { Performance.measure(.timelineProject) { usleep(150_000) } }
        }
        var hang: String?
        _ = await eventually(timeout: .seconds(20)) {
            hang = try? messages(in: store, since: since).first {
                $0.hasPrefix("hang ") && $0.contains("timeline.project")
            }
            return hang != nil
        }
        #expect(milliseconds(try #require(hang)) >= 150)
    }
}
