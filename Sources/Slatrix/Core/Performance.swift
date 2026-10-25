import Foundation
import os

/// How long the flows people feel take, written to the unified log for `scripts/perf-report.sh`. Only names from
/// `Name` and counts are logged, never a room, person or message.
@MainActor enum Performance {
    /// Logged dotted: `roomOpen` is `room.open`.
    enum Name {
        /// Process start to the sidebar showing rooms, and to the first conversation rows on screen.
        case launchRooms, launchConversation
        /// A room picked to its first rows on screen, and to the first items of its live timeline.
        case roomOpen, roomTimeline
        case threadOpen, workspaceSwitch, searchOpen, preferencesOpen
        /// Main-thread work: projecting a timeline update, applying rows to the table, measuring a batch of rows, and
        /// one room-list pass (which also awaits the SDK).
        case timelineProject, timelineApply, rowsMeasure, roomlistRefresh
        /// A loading indicator or placeholder on screen, by place. Every such name ends in `Loading`.
        case appLoading, sidebarLoading, conversationLoading, timelineLoading, historyLoading, threadLoading
        case threadsLoading, searchLoading, pinsLoading, peopleLoading, profileLoading, replyLoading, linkLoading
        case previewLoading, sheetLoading, attachmentsLoading
        /// A visible timeline row moved while the reader was not at the newest message.
        case timelineJump

        var label: String { String(describing: self).replacing(#/[A-Z]/#) { "." + $0.output.lowercased() } }
    }

    struct Interval {
        fileprivate let id: Int
        let name: Name
        fileprivate let start: ContinuousClock.Instant
        fileprivate let state: OSSignpostIntervalState
    }

    private static let logger = Logger(subsystem: "ai.nuanu.slatrix", category: "performance")
    private static let signposter = OSSignposter(logger: logger)
    private static let hangThreshold = Duration.milliseconds(100)
    private static var open: [Int: Interval] = [:]
    private static var lastID = 0
    /// Flows that start in one place and end in another, by name.
    private static var pending: [Name: Interval] = [:]
    /// Names that began or ended during the current main run-loop pass.
    private static var touched = Set<Name>()
    private static var passStart: ContinuousClock.Instant?
    private static var watching = false

    static func begin(_ name: Name, at start: ContinuousClock.Instant = .now) -> Interval {
        lastID += 1
        let state = signposter.beginInterval(
            "interval", id: signposter.makeSignpostID(), "\(name.label, privacy: .public)")
        let interval = Interval(id: lastID, name: name, start: start, state: state)
        open[interval.id] = interval
        touched.insert(name)
        return interval
    }

    static func end(_ interval: Interval, _ values: KeyValuePairs<String, Int> = [:]) {
        guard open.removeValue(forKey: interval.id) != nil else { return }
        signposter.endInterval("interval", interval.state)
        touched.insert(interval.name)
        let ms = milliseconds(.now - interval.start)
        // Shorter than a 60 Hz frame, a loading state never reached the screen.
        if interval.name.label.hasSuffix(".loading") && ms < 16 { return }
        logger.log(
            "interval=\(interval.name.label, privacy: .public) ms=\(ms, format: .fixed(precision: 1), privacy: .public)\(text(values), privacy: .public)"
        )
    }

    @discardableResult static func measure<T>(
        _ name: Name, _ values: KeyValuePairs<String, Int> = [:], _ work: () throws -> T
    ) rethrows
        -> T
    {
        let interval = begin(name)
        defer { end(interval, values) }
        return try work()
    }

    /// Starts a flow that `finish` ends elsewhere; starting it again restarts it.
    static func start(_ name: Name, at start: ContinuousClock.Instant = .now) {
        cancel(name)
        pending[name] = begin(name, at: start)
    }

    static func finish(_ name: Name, _ values: KeyValuePairs<String, Int> = [:]) {
        if let interval = pending.removeValue(forKey: name) { end(interval, values) }
    }

    /// Finishes the flow once what the current pass laid out has been committed to the screen.
    static func finishOnScreen(_ name: Name, _ values: KeyValuePairs<String, Int> = [:]) {
        guard pending[name] != nil else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { finish(name, values) } }
    }

    /// Drops a flow that will not finish the way it was measured, such as launch into the sign-in screen.
    static func cancel(_ name: Name) {
        guard let interval = pending.removeValue(forKey: name) else { return }
        open[interval.id] = nil
        signposter.endInterval("interval", interval.state)
    }

    static func event(_ name: Name, _ values: KeyValuePairs<String, Int> = [:]) {
        logger.log("event=\(name.label, privacy: .public)\(text(values), privacy: .public)")
    }

    /// Times launch from process start, so it includes everything before `main`.
    static func startLaunch() {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let started = sysctl(&mib, 4, &info, &size, nil, 0) == 0 ? info.kp_proc.p_un.__p_starttime : nil
        let age = started.map { Date().timeIntervalSince1970 - Double($0.tv_sec) - Double($0.tv_usec) / 1e6 } ?? 0
        let start = ContinuousClock.now - .seconds(max(0, age))
        Performance.start(.launchRooms, at: start)
        Performance.start(.launchConversation, at: start)
    }

    /// Logs every main run-loop pass that keeps the thread busy for 100 ms or more, with the intervals it ran. The
    /// observer runs only on run-loop transitions, so an idle app, asleep in the run loop, pays nothing.
    static func watchMainThread() {
        guard !watching else { return }
        watching = true
        let activities: CFRunLoopActivity = [.afterWaiting, .beforeTimers, .beforeWaiting]
        // Ordered last, so a pass includes the layout and drawing that other observers commit before sleeping.
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                passBoundary(sleeping: activity == .beforeWaiting, waking: activity == .afterWaiting)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func passBoundary(sleeping: Bool, waking: Bool) {
        let now = ContinuousClock.now
        if !waking, let passStart, now - passStart >= hangThreshold {
            // Flows left open for long, like a room that never got messages, did not cause this pass.
            let recent = open.values.filter { now - $0.start < .seconds(30) }.map(\.name)
            let during = Set(recent).union(touched).map(\.label).sorted().joined(separator: ",")
            logger.log(
                "hang ms=\(milliseconds(now - passStart), format: .fixed(precision: 0), privacy: .public) during=\(during.isEmpty ? "-" : during, privacy: .public)"
            )
        }
        touched.removeAll(keepingCapacity: true)
        passStart = sleeping ? nil : now
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func text(_ values: KeyValuePairs<String, Int>) -> String {
        values.map { " \($0.key)=\($0.value)" }.joined()
    }
}
