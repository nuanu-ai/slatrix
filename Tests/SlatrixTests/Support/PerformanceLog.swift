import Foundation
import OSLog
import os

/// A place in the performance log. What the app logs after it comes after it in the log, though its time there can
/// read some milliseconds earlier than `Date()` did when it was logged: the log keeps time its own way.
struct PerformanceMark: Sendable {
    fileprivate let message = "event=test.mark id=\(UUID().uuidString)"
    fileprivate let date = Date()
}

func performanceMark() -> PerformanceMark {
    let mark = PerformanceMark()
    Logger(subsystem: "ai.nuanu.slatrix", category: "performance").log("\(mark.message, privacy: .public)")
    return mark
}

/// The first performance log message after `mark` that matches, polled for up to 20 s. A read blocks on logd for
/// seconds, so the reads run on a thread of their own: on the cooperative pool they would hold one of its few threads
/// (three on CI), which every other test needs to get past its next `await`.
func firstPerformanceMessage(after mark: PerformanceMark, where match: @escaping @Sendable (String) -> Bool) async
    -> String?
{
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: readPerformanceLog(after: mark, where: match)) }
    }
}

private func readPerformanceLog(after mark: PerformanceMark, where match: (String) -> Bool) -> String? {
    let predicate = NSPredicate(format: "subsystem == 'ai.nuanu.slatrix' AND category == 'performance'")
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        // A store covers a fixed range; later writes need a fresh snapshot.
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        // From a second before the mark, which its own time can't be later than, to the mark itself.
        let entries = try? store.getEntries(
            at: store.position(date: mark.date.addingTimeInterval(-1)), matching: predicate)
        let after = entries?.lazy.compactMap { ($0 as? OSLogEntryLog)?.composedMessage }
            .drop { $0 != mark.message }.dropFirst()
        if let found = after?.first(where: match) { return found }
    }
    return nil
}

/// Every performance log message from `date` on, with its time, once the log has caught up with the call.
func performanceMessages(since date: Date) async -> [(date: Date, message: String)] {
    let sentinel = "event=test.sentinel id=\(UUID().uuidString)"
    Logger(subsystem: "ai.nuanu.slatrix", category: "performance").log("\(sentinel, privacy: .public)")
    return await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            let predicate = NSPredicate(format: "subsystem == 'ai.nuanu.slatrix' AND category == 'performance'")
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
                    let entries = try? store.getEntries(at: store.position(date: date), matching: predicate)
                else { break }
                let found = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.date >= date }
                    .map { (date: $0.date, message: $0.composedMessage) }
                if found.contains(where: { $0.message == sentinel }) {
                    return continuation.resume(returning: found.filter { $0.message != sentinel })
                }
            }
            continuation.resume(returning: [])
        }
    }
}
