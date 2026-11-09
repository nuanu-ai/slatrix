import Foundation
import OSLog

/// The first performance log message since `date` that matches, polled for up to 20 s. A read blocks on logd for
/// seconds, so the reads run on a thread of their own: on the cooperative pool they would hold one of its few threads
/// (three on CI), which every other test needs to get past its next `await`.
func firstPerformanceMessage(since date: Date, where match: @escaping @Sendable (String) -> Bool) async -> String? {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: readPerformanceLog(since: date, where: match)) }
    }
}

private func readPerformanceLog(since date: Date, where match: (String) -> Bool) -> String? {
    let predicate = NSPredicate(format: "subsystem == 'ai.nuanu.slatrix' AND category == 'performance'")
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
        // A store covers a fixed range; later writes need a fresh snapshot.
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
        let entries = try? store.getEntries(at: store.position(date: date), matching: predicate)
        // The store starts near `date`, not at it, so an earlier test's entries can come first.
        let since = entries?.lazy.compactMap { $0 as? OSLogEntryLog }.filter { $0.date >= date }
        if let found = since?.map(\.composedMessage).first(where: match) {
            return found
        }
    }
    return nil
}
