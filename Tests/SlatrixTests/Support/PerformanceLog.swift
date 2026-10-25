import Foundation
import OSLog

/// The first performance log message since `date` that matches, polled for up to 20 s. Call it off the main actor:
/// one read of the log takes long enough to stall tests running beside it.
func firstPerformanceMessage(since date: Date, where match: @escaping (String) -> Bool) async -> String? {
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
