import Foundation
import Testing

@testable import Slatrix

/// What the app writes to the unified log for `scripts/perf-report.sh`.
@MainActor
struct PerformanceLogTests {
    private func milliseconds(_ message: String) -> Double {
        message.split(separator: " ").first { $0.hasPrefix("ms=") }.flatMap { Double($0.dropFirst(3)) } ?? 0
    }

    @Test("A main-thread stall is logged with its length and the work that ran in it")
    func logsHangs() async throws {
        Performance.watchMainThread()
        let since = Date()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                Performance.measure(.timelineProject) { () -> Void in _ = usleep(150_000) }
            }
        }
        let hang = await firstPerformanceMessage(since: since) {
            $0.hasPrefix("hang ") && $0.contains("timeline.project")
        }
        #expect(milliseconds(try #require(hang)) >= 150)
    }
}
