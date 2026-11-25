import AppKit
import SwiftUI

/// One row of a conversation or thread timeline: everything its cell shows, so an unchanged entry never redraws.
struct TimelineEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Fills a short conversation from the top, so its messages sit on the composer like Slack's.
        case spacer
        /// Room for a spinner while history beyond this end exists.
        case loading(Bool, immediate: Bool = false)
        case welcome(TimelineWelcome)
        case day(String)
        case unread
        case replies(Int)
        case message(TimelineMessageEntry)
        case end
    }
    let id: String
    var kind: Kind
}

struct TimelineWelcome: Hashable {
    var name: String
    var topic: String
    var isDirect: Bool
    var isPrivate: Bool
    var isEncrypted: Bool
}

struct TimelineMessageEntry: Hashable {
    var message: ChatMessage
    var grouped: Bool
    var followsAttachment: Bool = false
    var time: String
    var saved: Bool
    var pinned: Bool
    var highlighted: Bool
    var sendFailure: MessageSendFailure?
    var sendWaitStatus: SendWaitStatus? = nil
    var sendBusy: Bool
    /// The readers a group's first row shows by its time; nil where it shows no ticks.
    var seenBy: [String]? = nil
    /// The reader collapsed this message's image or video.
    var mediaCollapsed = false
}

/// Isolated pin-permission state read only by the active hover toolbar and menus, never by resting rows.
@Observable @MainActor final class PinPermissionState {
    var allowed = false
}

/// What every row of one timeline shares: the session and the actions rows call back into.
@MainActor final class TimelineRowContext {
    var matrix = MatrixService?.none
    var isThread = false
    var threadRootID: String?
    /// Live pin permission, read lazily when a row's menu opens or the hover toolbar updates, never by resting rows.
    let pinPermission = PinPermissionState()
    var canPin: Bool {
        get { pinPermission.allowed }
        set { if pinPermission.allowed != newValue { pinPermission.allowed = newValue } }
    }
    /// Session-level action eligibility, read by resting rows without observing messages or action context.
    var canAct = false
    var metrics = Metrics()
    var appearance: AppearanceStore?
    var openURL = OpenURLAction { _ in .systemAction }
    var onThread: (ChatMessage) -> Void = { _ in }
    var onOpenReplies: (ChatMessage) -> Void = { _ in }
    var onReply: (ChatMessage) -> Void = { _ in }
    var onEdit: (MessageActionTarget) -> Void = { _ in }
    var onSave: (ChatMessage) -> Void = { _ in }
    var onDelete: (MessageActionTarget) -> Void = { _ in }
    var onShowReply: ((String) -> Void)?
    var onOpenProfile: ((String, ChatUser?) -> Void)?
    var onTogglePin: ((ChatMessage) -> Void)?
    var onForward: ((MessageActionTarget) -> Void)?
    var onEditCaption: ((MessageActionTarget) -> Void)?
    var onOpenMedia: (ChatMessage) -> Void = { _ in }
    /// The window's one inline video player.
    var inlineVideo: InlineVideo?
    var onReact: (MessageActionTarget, String) -> Void = { _, _ in }
    var onRetrySend: (ChatMessage) -> Void = { _ in }
    var onCancelSend: (ChatMessage) -> Void = { _ in }
    var onCopyLink: (MessagePermalinkTarget) -> Void = { _ in }
    /// Whether a link to this event is being copied.
    var isCopyingLink: (String) -> Bool = { _ in false }
    /// Opens the emoji picker for a reaction.
    var onPickEmoji: (EmojiPick) -> Void = { _ in }
    /// A displayed row whose height no longer matches its measurement, after state of its own changed.
    var onHeight: (String, CGFloat) -> Void = { _, _ in }
    /// Where a hovered row's reaction sits in its cell: the row, the reaction and its frame.
    var onReactionFrame: (String, String, CGRect) -> Void = { _, _, _ in }
}

/// Lets the SwiftUI shell move the list without owning it.
@MainActor final class TimelineScroller {
    fileprivate var bottom: (() -> Void)?
    fileprivate var anchor: (() -> String?)?
    func scrollToBottom() { bottom?() }
    /// While the newest message is on screen, the oldest message the screen depends on: the one above the first on
    /// screen, whose sender and time decide how that one is grouped.
    var screenAnchorEventID: String? { anchor?() }
}

/// The timeline list: an AppKit table of SwiftUI rows with measured, cached heights. Every change to the rows, their
/// heights or the viewport is applied and the scroll position corrected in the same layout pass, before anything is
/// drawn, so content never jumps. `TimelineScrollPolicy` decides where the viewport goes.
struct TimelineTable: NSViewRepresentable {
    var entries: [TimelineEntry]
    var context: TimelineRowContext
    var live: Bool
    var bottomAligned: Bool
    /// False while a cold thread holds only its root awaiting replies, so `open()` waits before locking position.
    var canOpen = true
    var focusedEventID: String?
    /// New with each jump, so jumping to the message already focused scrolls back to it.
    var jumpID: UUID?
    /// New with each message or file you send here.
    var sends = 0
    var startsAtUnread: Bool
    /// Where to remember the reading position across visits.
    var memoryKey: TimelineMemory.Key?
    /// The timeline the rows come from, when the table shows one only.
    var timelineID: UUID? = nil
    /// Counts the older pages that landed, whoever asked for them: as each lands, the table looks for the next.
    var pagesLanded = 0
    var canLoadOlder: Bool
    var canLoadNewer: Bool
    var scroller: TimelineScroller
    var onLoadOlder: () -> Void
    var onLoadNewer: () -> Void
    /// The jump this table landed on, once it centres its message.
    var onLand: (UUID) -> Void = { _ in }
    /// Whether the newest message is on screen, whether to offer "Jump to recent", whether messages sit above the
    /// top edge (nil until the table shows its rows), and what the read checks need of what it shows.
    var onScroll: (Bool, Bool, Bool?, PaneReport) -> Void
    /// What the read checks take the report for; when it changes, the table reports again.
    var readKey: AnyHashable? = nil
    /// The header's and the composer's heights: rows scroll under both, and the reader sees only what is between.
    var insets = EdgeInsets()
    /// Synchronous bar-height channel from `TimelineUnderBars`, measured before the table places or opens.
    var barInsets: TimelineBarInsets? = nil

    func makeCoordinator() -> TimelineTableCoordinator { TimelineTableCoordinator() }

    func makeNSView(context: Context) -> TimelineScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: TimelineScrollView, context: Context) {
        context.coordinator.update(self, covered: context.environment.isCovered)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: TimelineScrollView, coordinator: TimelineTableCoordinator) {
        coordinator.remember()
        coordinator.holdHeights()
        coordinator.stopLoading()
        coordinator.recycleCells()
    }
}

@MainActor final class TimelineTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private typealias Policy = TimelineScrollPolicy
    private static let cellID = NSUserInterfaceItemIdentifier("timeline-row")
    private struct Settings: Hashable {
        var zoom: CGFloat
        var density: MessageDensity
        var showAvatars: Bool
    }
    /// How far ahead of the reader rows are measured, in screens, and how long one pass between frames may take.
    private static let ahead: CGFloat = 2
    private static let prefetchSlice = Duration.milliseconds(4)
    private static let spareCells = 20
    private static let recycledCells = 40
    private static var recycled: [TimelineCell] = []

    private var configuration: TimelineTable?
    private var rows: [TimelineEntry] = []
    private var applied: [TimelineEntry]?
    private var index: [String: Int] = [:]
    private let scrollView = TimelineScrollView()
    private let table = TimelineTableView()
    /// Cells built and measured ahead of the reader, by row ID, and cells to build the next ones in.
    private var prepared: [String: TimelineCell] = [:]
    private var spares: [TimelineCell] = []
    private var width: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var settings: Settings?
    private var spacerHeight: CGFloat = 0
    private var insets = NSEdgeInsets()
    private var opened = false
    private var covered = false
    private var pendingFocus: String?
    private var hoveredID: String?
    private let toolbar = TimelineToolbarView(rootView: nil)
    private var toolbarEntry: TimelineEntry?
    private let tooltip = TooltipPresenter()
    /// The hovered row's reactions, by key, in its cell's coordinates.
    private var reactionFrames: [String: CGRect] = [:]
    private var pointer: NSPoint?
    /// Heights of this table's rows the table has been given, by row ID; the rest are estimates.
    private var known: [String: CGFloat] = [:]
    private var prefetching = false
    private var scrollingUp = true
    private var lastTop: CGFloat = 0
    private var applying = false
    /// The reader's finger is on the trackpad, or its momentum and bounce are still running.
    private var liveScrolling = false
    /// Whether the reader moved the view since the table last put it somewhere.
    private var scrolledByReader = false
    private var atOlderMessage = false
    private var reported: (Bool, Bool, Bool?, PaneReport)?
    /// Where the reader was before the scroll view laid out its clip, which a new size has already moved.
    private var tiling: Policy.Position?
    /// While the table waits for its first rows.
    private var loading: Performance.Interval?

    func makeView() -> TimelineScrollView {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollEnded), name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView)
        scrollView.willTile = { [weak self] in self?.tiling = self?.opened == true ? self?.position() : nil }
        scrollView.onTile = { [weak self] in self?.viewportResized() }
        scrollView.onPointer = { [weak self] point in self?.pointerMoved(point) }
        return scrollView
    }

    func update(_ configuration: TimelineTable, covered: Bool = false) {
        let previous = self.configuration
        // The view this table leaves with may already describe the next timeline, which a table of its own shows.
        guard previous == nil || previous?.timelineID == configuration.timelineID else { return }
        self.configuration = configuration
        if self.covered != covered {
            self.covered = covered
            scrollView.isCovered = covered
            if covered { pointerMoved(nil) }
        }
        if previous == nil, !opened {
            loading = Performance.begin(configuration.context.isThread ? .threadLoading : .timelineLoading)
            // A table shows one timeline; the view it leaves with may already describe the next.
            atOlderMessage = !configuration.live && !restoresReadingPosition
        }
        configuration.context.onHeight = { [weak self] id, height in self?.reported(height, for: id) }
        configuration.context.onReactionFrame = { [weak self] id, key, frame in
            guard let self, id == hoveredID else { return }
            reactionFrames[key] = frame
            // Reported from inside the row's layout, perhaps under a pointer that has stopped moving.
            DispatchQueue.main.async { [weak self] in self?.placeTooltip() }
        }
        configuration.scroller.bottom = { [weak self] in self?.scrollToBottom(animated: true) }
        configuration.scroller.anchor = { [weak self] in self?.screenAnchor() }
        // A jump that landed and went changes nothing; a new one goes again.
        if previous?.focusedEventID != configuration.focusedEventID
            || configuration.jumpID != nil && previous?.jumpID != configuration.jumpID
        {
            pendingFocus = configuration.focusedEventID
        }
        if let barInsets = configuration.barInsets {
            barInsets.onChange = { [weak self] new in self?.inset(new) }
            if barInsets.measured { inset(barInsets.current) }
        } else {
            inset(configuration.insets)
        }
        // As in Slack, what you send brings a live conversation to it, however soon the server confirms it.
        if opened, configuration.live, let previous, previous.sends != configuration.sends {
            preservingPosition(keeping: .bottom) {}
        }
        apply(configuration.entries)
        if opened, let previous, previous.pagesLanded != configuration.pagesLanded { checkHistory() }
        if let previous, previous.readKey != configuration.readKey { reported = nil }
        // A jump within rows already shown changes none of them.
        if opened, pendingFocus != nil || reported == nil { afterScroll() }
    }

    // MARK: Rows

    private func apply(_ entries: [TimelineEntry]) {
        guard width > 0, let configuration, configuration.barInsets?.measured != false else { return }
        let settings = Settings(
            zoom: configuration.context.metrics.zoom,
            density: configuration.context.appearance?.density ?? .comfortable,
            showAvatars: configuration.context.appearance?.showAvatars ?? true)
        let settingsChanged = settings != self.settings
        self.settings = settings
        // The timeline hands back the same array while nothing in it changed, which makes this check instant.
        let needsOpen = !opened && configuration.canOpen
        guard entries != applied || settingsChanged || needsOpen else { return }
        applied = entries
        let next =
            [TimelineEntry(id: "spacer", kind: .spacer)] + entries + [TimelineEntry(id: "end", kind: .end)]
        guard next != rows || settingsChanged || needsOpen else { return }
        let interval = Performance.begin(.timelineApply)
        defer { Performance.end(interval, ["rows": next.count]) }
        // Until rows with content open the table, there is nothing on screen to keep in place.
        guard opened else {
            rows = next
            reindex()
            restoreHeights()
            table.reloadData()
            open()
            return
        }
        let difference = next.map(\.id).difference(from: rows.map(\.id))
        let me = configuration.context.matrix?.user?.id
        // As in Slack, what you send brings a live conversation to it, wherever you were reading.
        let sent =
            configuration.live
            && difference.insertions.contains {
                guard case .insert(let offset, _, _) = $0, case .message(let entry) = next[offset].kind else {
                    return false
                }
                return entry.message.senderID == me && entry.message.sendState != "sent"
            }
        let keeping: Policy.Position? =
            if sent {
                .bottom
            } else if configuration.context.isThread && viewport.top <= 1 && difference.removals.isEmpty
                && difference.insertions.count == 1,
                case .insert(let offset, _, _) = difference.insertions.first, next[offset].id == "older"
            {
                .top
            } else {
                nil
            }
        preservingPosition(keeping: keeping) {
            if !difference.isEmpty {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.beginUpdates()
                for case .remove(let offset, _, _) in difference.removals.reversed() {
                    rows.remove(at: offset)
                    table.removeRows(at: [offset], withAnimation: [])
                }
                for case .insert(let offset, _, _) in difference.insertions {
                    // A new timeline numbers its rows afresh: a height kept under this ID was another message's.
                    known[next[offset].id] = nil
                    rows.insert(next[offset], at: offset)
                    table.insertRows(at: [offset], withAnimation: [])
                }
                table.endUpdates()
                NSAnimationContext.endGrouping()
                reindex()
                // The table guesses the height of a row inserted off screen from the rows around it until something
                // asks for the row's frame, and puts the real one in at a later layout, past this wrapper.
                for case .insert(let offset, _, _) in difference.insertions { _ = table.rect(ofRow: offset) }
                // That moves the rows below without moving the views it already shows for them.
                alignRowViews()
            }
            var changed = IndexSet()
            if settingsChanged {
                known = [:]
                toolbarEntry = nil
            }
            for row in rows.indices where rows[row] != next[row] || settingsChanged {
                rows[row] = next[row]
                known[rows[row].id] = nil
                changed.insert(row)
            }
            if !changed.isEmpty {
                noteHeights(changed)
                for row in changed { refresh(row) }
            }
        }
        if !opened { open() }
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
    }

    private func refresh(_ row: Int) {
        guard row < rows.count, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell
        else { return }
        show(rows[row], in: cell)
    }

    /// Updates the cell's row in place unless it already shows exactly this.
    private func show(_ entry: TimelineEntry, in cell: TimelineCell) {
        let hovered = entry.id == hoveredID
        let row = TimelineRow(entry: entry, hovered: hovered, context: configuration?.context ?? TimelineRowContext())
        guard row != cell.row else { return }
        let commands: ((Bool) -> [MessageMenuCommand])? =
            if case .message(let row) = entry.kind, let context = configuration?.context {
                { accessibility in
                    let target = context.actionTarget(for: row.message)
                    return accessibility
                        ? context.accessibilityCommands(for: row, target: target)
                        : context.actions(for: row, target: target).menu()
                }
            } else { nil }
        cell.show(row, commands: commands)
    }

    private func dequeue() -> TimelineCell {
        table.makeView(withIdentifier: Self.cellID, owner: nil) as? TimelineCell ?? spares.popLast()
            ?? Self.recycled.popLast() ?? TimelineCell(identifier: Self.cellID)
    }

    /// The next timeline, usually another room, shows its rows in these cells: updating a row's views in place costs
    /// a fraction of building them.
    func recycleCells() {
        var cells = Array(prepared.values) + spares
        table.enumerateAvailableRowViews { rowView, _ in
            if let cell = rowView.view(atColumn: 0) as? TimelineCell { cells.append(cell) }
        }
        prepared = [:]
        spares = []
        for cell in cells {
            cell.clear()
            cell.removeFromSuperview()
            if Self.recycled.count < Self.recycledCells { Self.recycled.append(cell) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let entry = rows[row]
        switch entry.kind {
        case .spacer: return max(1, spacerHeight)
        case .end:
            guard let context = configuration?.context else { return 8 }
            return context.isThread ? context.metrics.sp8 : context.metrics.conversationEnd
        default: break
        }
        if let height = known[entry.id] { return height }
        return estimate(entry)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = prepared.removeValue(forKey: rows[row].id) ?? dequeue()
        show(rows[row], in: cell)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Heights

    /// The width a row lays out at: both conversations and threads span their pane cleanly.
    private var rowWidth: CGFloat { width }

    /// Builds and measures the row ahead of display. Returns whether its measured height changed.
    @discardableResult private func prepare(_ row: Int) -> Bool {
        let entry = rows[row]
        let shown = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell
        let cell = shown ?? prepared[entry.id] ?? dequeue()
        if shown == nil { prepared[entry.id] = cell }
        show(entry, in: cell)
        let previous = known[entry.id]
        // Measure the cell that will be shown; another timeline or a reused cell can have different local state.
        let height = max(1, ceil(cell.height(width: width)))
        known[entry.id] = height
        if shown == nil { cell.frame = NSRect(x: 0, y: 0, width: width, height: height) }
        return previous != height
    }

    /// Rows the reader left behind give their cells back for the next ones.
    private func releasePrepared(outside near: NSRange) {
        for (id, cell) in prepared where index[id].map({ !NSLocationInRange($0, near) }) ?? true {
            prepared[id] = nil
            cell.clear()
            if spares.count < Self.spareCells { spares.append(cell) }
        }
    }

    /// Rough, cheap and never shown: a row is measured before it is drawn.
    private func estimate(_ entry: TimelineEntry) -> CGFloat {
        Self.estimateHeight(
            for: entry, rowWidth: rowWidth, metrics: configuration?.context.metrics ?? Metrics(),
            compact: configuration?.context.appearance?.density == .compact,
            isThread: configuration?.context.isThread == true)
    }

    static func estimateHeight(
        for entry: TimelineEntry, rowWidth: CGFloat, metrics m: Metrics, compact: Bool, isThread: Bool
    ) -> CGFloat {
        switch entry.kind {
        case .spacer, .end, .loading: return m.sp40
        case .welcome: return m(220)
        case .day, .replies: return m(36)
        case .unread: return m(40)
        case .message(let row):
            let line = m.lineHeight(.reading)
            let inset = m.conversationInset(thread: isThread)
            let chrome: CGFloat = compact ? m(52) + m.sp8 : m.avatar + m.sp12
            let textWidth = max(m(120), rowWidth - 2 * inset - chrome)
            let perLine = max(20, textWidth / (m.size(.reading) * 0.5))
            // Characters counted as UTF-8 lead bytes: a whole room is estimated at once, and grapheme breaking costs
            // more than this guess is worth. In compact mode the sender name flows inline on the first line.
            var lines: CGFloat = 0
            var characters: CGFloat = compact && !row.grouped ? CGFloat(row.message.senderName.count + 2) : 0
            for byte in row.message.body.utf8 {
                if byte == 10 {
                    lines += max(1, ceil(characters / perLine))
                    characters = 0
                } else if byte & 0xC0 != 0x80 {
                    characters += 1
                }
            }
            lines += max(1, ceil(characters / perLine))
            let overhead: CGFloat =
                if compact {
                    MessageRow.topInset(
                        m, grouped: row.grouped, compact: true, followsAttachment: row.followsAttachment) + m.sp2
                } else {
                    row.grouped ? (row.followsAttachment ? m(14) : m.sp4) : m(29)
                }
            var height = overhead + lines * line
            if !row.message.isRedacted {
                if !row.message.reactions.isEmpty { height += m(30) }
                if row.message.attachment != nil { height += m(300) }
                if row.message.replyPreview != nil { height += m(48) }
                if (row.message.replyCount ?? 0) > 0 { height += m(28) }
            }
            return height
        }
    }

    /// Measures the estimated rows on screen, keeping `position` (or the first measured row on screen) where it is.
    /// Rows near the screen are measured ahead, between frames.
    private func settle(keeping position: Policy.Position?) {
        defer { prefetchSoon() }
        while true {
            let shown = table.rows(in: scrollView.contentView.bounds)
            let pending = IndexSet(
                (Range(shown) ?? 0..<0).filter {
                    rows[$0].kind != .spacer && rows[$0].kind != .end && known[rows[$0].id] == nil
                })
            guard !pending.isEmpty else { return }
            let anchor = position ?? self.position(excluding: pending)
            Performance.measure(.rowsMeasure, ["rows": pending.count]) { for row in pending { prepare(row) } }
            noteHeights(pending)
            updateSpacer()
            scroll(to: anchor)
        }
    }

    private func prefetchSoon() {
        guard !prefetching else { return }
        prefetching = true
        // Once the frame in progress is on screen: Core Animation commits it as the run loop is about to wait, and the
        // timer wakes it again at once.
        let drawn = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, .max) {
            [weak self] _, _ in
            RunLoop.main.add(
                Timer(timeInterval: 0, repeats: false) { _ in MainActor.assumeIsolated { self?.prefetch() } },
                forMode: .common)
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), drawn, .commonModes)
    }

    /// Prepares the cells of rows within `Self.ahead` screens of the viewport, nearest first, for a few milliseconds
    /// a pass, so scrolling finds them built and measured and no frame waits on many at once.
    private func prefetch() {
        prefetching = false
        guard opened, viewportHeight > 0, !leaving else { return }
        let bounds = scrollView.contentView.bounds
        // Ahead of the reader, and a little behind in case they turn back.
        let ahead = viewportHeight * Self.ahead
        let behind = viewportHeight / 2
        let near = table.rows(
            in: NSRect(
                x: 0, y: bounds.minY - (scrollingUp ? ahead : behind), width: bounds.width,
                height: bounds.height + ahead + behind))
        releasePrepared(outside: near)
        let shown = table.rows(in: bounds)
        let pending = (Range(near) ?? 0..<0).filter {
            // A loading row logs how long it is on screen; it is cheap to build when it gets there.
            switch rows[$0].kind {
            case .spacer, .end, .loading: return false
            default: break
            }
            return prepared[rows[$0].id]?.entry != rows[$0]
                && table.view(atColumn: 0, row: $0, makeIfNecessary: false) == nil
        }.sorted { abs($0 - shown.location) < abs($1 - shown.location) }
        guard !pending.isEmpty else { return }
        let deadline = ContinuousClock.now + Self.prefetchSlice
        var done = 0
        var measured = IndexSet()
        let interval = Performance.begin(.rowsMeasure)
        for row in pending where done == 0 || ContinuousClock.now < deadline {
            if prepare(row) { measured.insert(row) }
            done += 1
        }
        Performance.end(interval, ["rows": done])
        if measured.isEmpty { prefetchSoon() } else { preservingPosition { noteHeights(measured) } }
    }

    /// A row's own state (a revealed spoiler, an error under an attachment) changed its height.
    private func reported(_ reported: CGFloat, for id: String) {
        guard let measured = known[id], abs(ceil(reported) - measured) > 0.5 else { return }
        // Not inside the SwiftUI update that reported it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let row = index[id], known[id] == measured,
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell,
                cell.entry?.id == id
            else { return }
            // The report only says to look: a reused cell, already sized for this row, first reports the height of
            // the row it showed last.
            let height = max(1, ceil(cell.height(width: width)))
            guard height != measured else { return }
            known[id] = height
            preservingPosition { self.noteHeights([row]) }
        }
    }

    /// Every row is re-estimated at a new width; the settle that follows measures the ones near the viewport.
    private func remeasure() {
        known = [:]
        guard !rows.isEmpty else { return }
        preservingPosition(keeping: tiling) { noteHeights(IndexSet(integersIn: 0..<rows.count)) }
    }

    /// Without an explicit zero duration the table animates row heights, drawing rows where they no longer are.
    private func noteHeights(_ rows: IndexSet) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: rows)
        NSAnimationContext.endGrouping()
    }

    /// Puts the rows on screen where the table's geometry says they are; left where a guessed height put them, they
    /// overlap the rows the table adds next to them, or leave a gap.
    private func alignRowViews() {
        table.enumerateAvailableRowViews { rowView, row in
            let rect = table.rect(ofRow: row)
            if rowView.frame != rect { rowView.frame = rect }
        }
    }

    // MARK: Position

    private var viewport: Policy.Viewport {
        Policy.Viewport(
            clip: scrollView.contentView.bounds, covered: (insets.top, insets.bottom),
            contentHeight: rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY)
    }

    /// The viewport in the table's coordinates.
    private var visible: NSRect {
        let viewport = viewport
        return NSRect(x: 0, y: viewport.top, width: scrollView.contentView.bounds.width, height: viewport.height)
    }

    private var report: PaneReport {
        let visible = visible
        let inView = Range(table.rows(in: visible))?.reversed().lazy.compactMap { row -> String? in
            let rect = self.table.rect(ofRow: row)
            guard
                ReadStatePolicy.isSeen(
                    top: rect.minY, bottom: rect.maxY, screenTop: visible.minY, screenBottom: visible.maxY)
            else { return nil }
            return self.rows[row].messageEventID
        }.first
        return PaneReport(newestInView: inView, laidOut: rows.last { $0.messageEventID != nil }?.messageEventID)
    }

    private func frame(_ id: String) -> Policy.RowFrame? {
        guard let row = index[id] else { return nil }
        let rect = table.rect(ofRow: row)
        return Policy.RowFrame(id: id, top: rect.minY, height: rect.height)
    }

    /// The rows on screen that hold the view still: the first message, which unlike a day divider never moves among
    /// its neighbours, or the first row when no message is there; then the messages after it to stand in for it, as
    /// only a message's ID never passes to another row. Rows about to be measured hold it only when nothing else is on
    /// screen.
    private func visibleRows(excluding excluded: IndexSet) -> [Int] {
        guard let range = Range(table.rows(in: visible)) else { return [] }
        let shown = range.filter { rows[$0].kind != .spacer && rows[$0].kind != .end }
        // After a jump into rows never measured, the first of them holds its place while they are.
        let measured = shown.filter { !excluded.contains($0) }
        let candidates = measured.isEmpty ? shown : measured
        let messages = candidates.filter { if case .message = rows[$0].kind { true } else { false } }
        guard let first = messages.first ?? candidates.first else { return [] }
        let held = [first] + messages.drop { $0 <= first }
        // A thread's older replies land under its root and line: the first reply on screen holds still, not the root.
        let boundary: Int? =
            if let older = index["older"] {
                older
            } else if let context = configuration?.context, context.isThread {
                index["replies"]
                    ?? context.threadRootID.flatMap { rootID in
                        rows.firstIndex { $0.messageEventID == rootID }
                    }
            } else { nil }
        guard let boundary, held.contains(where: { $0 > boundary && rows[$0].messageEventID != nil }) else {
            return held
        }
        return held.filter { $0 > boundary }
    }

    private func screenAnchor() -> String? {
        guard viewport.isAtBottom, let row = visibleRows(excluding: []).first else { return nil }
        return rows[..<row].last { $0.messageEventID != nil }?.messageEventID ?? rows[row].messageEventID
    }

    private func position(excluding excluded: IndexSet = [], standIns: Bool = true) -> Policy.Position {
        Policy.position(
            of: viewport, live: configuration?.live ?? true,
            visibleRows: visibleRows(excluding: excluded).prefix(standIns ? .max : 1).compactMap { frame(rows[$0].id) })
    }

    /// Applies a change to rows or heights and puts the viewport back where the policy says, before display: where
    /// it is now, or `kept` when the viewport has already moved.
    private func preservingPosition(keeping kept: Policy.Position? = nil, _ change: () -> Void) {
        let position = opened ? kept ?? position() : nil
        applying = true
        change()
        updateSpacer()
        if let position { scroll(to: position) }
        settle(keeping: position)
        applying = false
        noteJump(from: position)
        afterScroll()
    }

    /// The policy holds the reader's row, or the newest message they follow, still through every change; this counts
    /// each time it did not.
    private func noteJump(from position: Policy.Position?) {
        guard let position, let moved = Policy.jump(from: position, to: viewport, frame: frame) else { return }
        Performance.event(
            .timelineJump,
            [
                "px": Int(moved.rounded()), "bottom": position == .bottom ? 1 : 0,
                "live": configuration?.live == false ? 0 : 1,
            ])
    }

    /// A thread pane holding only its root opens at the top so a tall root is never cut off.
    private var startsAtTop: Bool {
        guard configuration?.context.isThread == true else { return false }
        let rootID = configuration?.context.threadRootID
        return !rows.contains {
            if case .message(let row) = $0.kind { return row.message.eventID != rootID }
            return false
        }
    }

    private func open() {
        guard let configuration else { return }
        let hasContent = rows.contains {
            switch $0.kind {
            case .message, .welcome: true
            default: false
            }
        }
        applying = true
        updateSpacer()
        defer {
            applying = false
            afterScroll()
        }
        let openAtTop = startsAtTop
        let fallback: Policy.Position = openAtTop ? .top : .bottom
        guard hasContent && configuration.canOpen else {
            scroll(to: fallback)
            return settle(keeping: fallback)
        }
        opened = true
        let focused = pendingFocus.flatMap { focus in rows.first { $0.messageEventID == focus }?.id }
        if focused != nil { landed() }
        let remembered = configuration.live || restoresReadingPosition ? rememberedPosition : nil
        let opening = Policy.opening(
            focusedRowID: restoresReadingPosition ? nil : focused, unreadRowID: index["unread"] == nil ? nil : "unread",
            startsAtUnread: configuration.startsAtUnread, remembered: remembered, startsAtTop: openAtTop,
            contains: { index[$0] != nil })
        let held = known.count
        scroll(to: opening)
        settle(keeping: opening)
        stopLoading()
        // Check the settled result after deferred AppKit layout as well as the opening pass.
        let start =
            switch opening {
            case .bottom: 0
            case .centered: 3
            case _ where opening == remembered: 1
            case .top: 4
            default: 2
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.logFit(opening: start) }
        if !configuration.context.isThread {
            // Rows that come with heights from an earlier visit are not measured again.
            Performance.finishOnScreen(.roomOpen, ["rows": rows.count, "measured": known.count - held])
            Performance.finishOnScreen(.launchConversation, ["rows": rows.count])
        }
    }

    private func logFit(opening: Int) {
        guard scrollView.window != nil else { return }
        let shown = Range(table.rows(in: scrollView.contentView.bounds)) ?? 0..<0
        let differences = shown.compactMap { row -> CGFloat? in
            guard case .message = rows[row].kind,
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell
            else { return nil }
            let difference = ceil(cell.height(width: width)) - cell.frame.height
            return abs(difference) >= 1 ? difference : nil
        }
        let largest = differences.max { abs($0) < abs($1) } ?? 0
        let newest = rows.lastIndex { if case .message = $0.kind { true } else { false } }
        let below = newest.map { viewport.contentHeight - table.rect(ofRow: $0).maxY } ?? 0
        // A short top-aligned thread intentionally leaves empty space below its replies.
        let past =
            configuration?.bottomAligned == false && viewport.contentHeight <= viewport.height
            ? 0 : Int(viewport.overshoot.rounded())
        Performance.event(
            .timelineFit,
            [
                "misfit": differences.count, "px": Int(largest), "bottom": Int(viewport.distanceFromBottom.rounded()),
                "opening": opening, "live": configuration?.live == false ? 0 : 1, "below": Int(below.rounded()),
                "past": past, "inset": Int(insets.bottom.rounded()),
            ])
    }

    /// Rows that fill the screen (or any bottom-aligned conversation) never leave space under the newest message.
    /// AppKit can leave the table taller than its rows and the view at the table's end, past the newest message.
    private func closeGap() {
        guard opened, !applying, !liveScrolling else { return }
        let bottomAligned = configuration?.bottomAligned == true
        table.tile()
        let viewport = viewport
        guard bottomAligned || viewport.contentHeight > viewport.height, viewport.overshoot >= 1 else { return }
        Performance.event(
            .timelineGap,
            [
                "px": Int(viewport.overshoot.rounded()), "inset": Int(insets.bottom.rounded()),
                "frame": Int((table.frame.height - viewport.contentHeight).rounded()),
            ])
        let wasApplying = applying
        applying = true
        if bottomAligned { updateSpacer() }
        scroll(to: .bottom)
        applying = wasApplying
    }

    func stopLoading() {
        if let loading { Performance.end(loading) }
        loading = nil
    }

    private func scroll(to position: Policy.Position) {
        // A row the reader has mostly scrolled past is off screen to the settle that follows, so an estimate of its
        // height would move everything after it.
        if case .anchored(let id, _, _) = position, known[id] == nil, let row = index[id] {
            prepare(row)
            noteHeights([row])
        }
        table.tile()
        let viewport = viewport
        guard
            let top = Policy.top(
                for: position, contentHeight: viewport.contentHeight, viewportHeight: viewport.height, frame: frame)
        else { return }
        let clip = scrollView.contentView
        let origin = top - insets.top
        guard abs(clip.bounds.minY - origin) > 0.01 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: origin))
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollToBottom(animated: Bool) {
        let viewport = viewport
        let top = max(0, viewport.contentHeight - viewport.height) - insets.top
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.15 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: top))
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    /// Conversations start at their composer: a spacer above short content keeps the newest message at the bottom.
    private func updateSpacer() {
        guard !rows.isEmpty, configuration?.bottomAligned == true else { return }
        table.tile()
        let content = table.rect(ofRow: rows.count - 1).maxY - table.rect(ofRow: 0).height
        // Whole points, so every row below it stays on the pixel grid.
        let height = max(0, (viewportHeight - content).rounded(.down))
        guard abs(height - spacerHeight) > 0.25 else { return }
        spacerHeight = height
        noteHeights([0])
    }

    /// The header or the composer changed height: rows scroll under the new one, the reader's place kept.
    private func inset(_ new: EdgeInsets) {
        let changed = new.top != insets.top || new.bottom != insets.bottom
        if changed {
            let kept = opened ? position() : nil
            insets = NSEdgeInsets(top: new.top, left: 0, bottom: new.bottom, right: 0)
            // Before the scroll view tiles for them, so that tile finds the viewport already this size.
            if width > 0 { viewportHeight = visible.height }
            applying = true
            scrollView.contentInsets = insets
            scrollView.scrollerInsets = insets
            applying = false
            guard width > 0 else { return }
            if opened {
                preservingPosition(keeping: kept) {}
            } else if let configuration {
                apply(configuration.entries)
            }
        } else if !opened, width > 0, let configuration {
            apply(configuration.entries)
        }
    }

    private func viewportResized() {
        let size = visible.size
        guard size.width > 0, size != NSSize(width: width, height: viewportHeight) else { return }
        let previousRowWidth = rowWidth
        let first = width == 0
        width = size.width
        viewportHeight = size.height
        table.tableColumns.first?.width = width
        if first, let configuration { return apply(configuration.entries) }
        if rowWidth != previousRowWidth {
            remeasure()
        } else {
            preservingPosition(keeping: tiling) {}
        }
    }

    @objc private func liveScrollStarted() { liveScrolling = true }

    @objc private func liveScrollEnded() {
        liveScrolling = false
        afterScroll()
    }

    @objc private func boundsChanged() {
        guard !applying, visible.size == NSSize(width: width, height: viewportHeight) else { return }
        // The reader moved: a linked message that has not loaded yet no longer takes over the view.
        pendingFocus = nil
        scrolledByReader = true
        let top = scrollView.contentView.bounds.minY
        if top != lastTop { scrollingUp = top < lastTop }
        lastTop = top
        let reading = opened ? position() : nil
        applying = true
        settle(keeping: nil)
        applying = false
        noteJump(from: reading)
        afterScroll()
    }

    /// Reports the viewport's state, keeps the hover with the pointer and loads history ahead of the reader.
    private func afterScroll() {
        guard let configuration else { return }
        closeGap()
        if let pendingFocus, let row = rows.first(where: { $0.messageEventID == pendingFocus }) {
            landed()
            scrolledByReader = false
            applying = true
            scroll(to: .centered(rowID: row.id))
            settle(keeping: .centered(rowID: row.id))
            applying = false
            if !configuration.context.isThread { Performance.finishOnScreen(.roomOpen, ["rows": rows.count]) }
        }
        updateHover()
        let viewport = viewport
        let state = (
            viewport.isAtBottom,
            opened
                && Policy.showsJumpToLatest(viewport, live: configuration.live, scrolledByReader: scrolledByReader),
            opened ? viewport.top > 0.5 : nil,
            report
        )
        if reported.map({ $0 != state }) ?? true {
            reported = state
            // SwiftUI state; never changed from inside its own update or layout.
            DispatchQueue.main.async { configuration.onScroll(state.0, state.1, state.2, state.3) }
        }
        checkHistory()
    }

    /// The focus is on screen; a jump that put it there landed, once.
    private func landed() {
        pendingFocus = nil
        guard let configuration, let jump = configuration.jumpID else { return }
        // SwiftUI state; never changed from inside its own update or layout.
        DispatchQueue.main.async { [weak self] in
            guard self?.scrollView.window != nil else { return }
            configuration.onLand(jump)
        }
    }

    /// Also before the table opens: history of only hidden events leaves nothing to open at until a page shows some.
    private func checkHistory() {
        guard let configuration else { return }
        let viewport = viewport
        // A thread's root and line sit over its older replies; only the replies under them count toward the distance.
        let above: CGFloat =
            if let older = index["older"] {
                table.rect(ofRow: older).minY - table.rect(ofRow: 1).minY
            } else if configuration.context.isThread,
                let boundary = index["replies"]
                    ?? configuration.context.threadRootID.flatMap({ rootID in
                        rows.firstIndex { $0.messageEventID == rootID }
                    })
            {
                table.rect(ofRow: boundary).maxY - table.rect(ofRow: 1).minY
            } else { 0 }
        if configuration.canLoadOlder && Policy.needsOlder(viewport, above: above) {
            DispatchQueue.main.async { configuration.onLoadOlder() }
        } else if configuration.canLoadNewer && Policy.needsNewer(viewport) {
            DispatchQueue.main.async { configuration.onLoadNewer() }
        }
    }

    func remember() {
        guard let key = configuration?.memoryKey else { return }
        // Coming back from a timeline opened at an older message lands at the newest one.
        guard !atOlderMessage else {
            TimelineMemory.positions[key] = nil
            return
        }
        guard opened else { return }
        if case .anchored(let id, let offset, _) = position(standIns: false), let row = index[id],
            let eventID = rows[row].messageEventID
        {
            TimelineMemory.positions[key] = TimelineMemory.Anchor(eventID: eventID, offset: offset)
        } else if startsAtTop, viewport.top >= 1, let row = visibleRows(excluding: []).first,
            let eventID = rows[row].messageEventID, let rowFrame = frame(rows[row].id)
        {
            // A standalone root defaults to top when unremembered, so persist a scrolled-to-bottom offset.
            TimelineMemory.positions[key] = TimelineMemory.Anchor(
                eventID: eventID, offset: rowFrame.top - viewport.top)
        } else {
            TimelineMemory.positions[key] = nil
        }
    }

    /// The pane is moving on to another timeline, or has, so this table has nothing left to scroll to.
    private var leaving: Bool {
        guard let configuration else { return true }
        let current =
            configuration.context.isThread
            ? configuration.context.matrix?.threadSelection
            : configuration.context.matrix?.shownTimelineID
        return scrollView.window == nil || configuration.timelineID != nil && configuration.timelineID != current
    }

    /// Keeps what this table measured for the next table on the same timeline.
    func holdHeights() {
        // A session signed out has nothing to come back to.
        guard let configuration, let key = configuration.memoryKey, width > 0,
            key.sessionID == configuration.context.matrix?.notificationSessionID
        else { return }
        var heights: [String: (fingerprint: Int, height: CGFloat)] = [:]
        for (id, height) in known { if let row = index[id] { heights[id] = (fingerprint(rows[row]), height) } }
        TimelineMemory.heights.removeAll { $0.key == key }
        TimelineMemory.heights.append((key, heights))
        // The open conversations, their threads and the recent timelines kept live.
        if TimelineMemory.heights.count > 20 { TimelineMemory.heights.removeFirst() }
    }

    /// Rows this timeline showed last, unchanged and at the same width, keep the heights they were measured at.
    private func restoreHeights() {
        guard let key = configuration?.memoryKey, let held = TimelineMemory.heights.first(where: { $0.key == key })
        else { return }
        for row in rows {
            if let kept = held.rows[row.id], kept.fingerprint == fingerprint(row) { known[row.id] = kept.height }
        }
    }

    /// What a row's height depends on: the row, and the row column width, settings and pane.
    private func fingerprint(_ row: TimelineEntry) -> Int {
        var hasher = Hasher()
        hasher.combine(row)
        hasher.combine(rowWidth)
        hasher.combine(settings)
        hasher.combine(configuration?.context.isThread)
        return hasher.finalize()
    }

    private var restoresReadingPosition: Bool {
        guard let configuration, !configuration.startsAtUnread, configuration.jumpID == nil,
            let key = configuration.memoryKey, let anchor = TimelineMemory.positions[key]
        else { return false }
        return configuration.focusedEventID == anchor.eventID
    }

    private var rememberedPosition: Policy.Position? {
        guard let key = configuration?.memoryKey, let anchor = TimelineMemory.positions[key],
            let row = rows.first(where: { $0.messageEventID == anchor.eventID })
        else { return nil }
        return .anchored(rowID: row.id, offset: anchor.offset)
    }

    // MARK: Hover

    private func pointerMoved(_ point: NSPoint?) {
        // Under a modal or drawer, or over the header's/composer's glass, the pointer does not hover rows.
        let point = covered ? nil : point.flatMap { visible.contains(table.convert($0, from: nil)) ? $0 : nil }
        pointer = point
        defer { placeTooltip() }
        // The toolbar hangs over the row above its own; the pointer on it still means its row.
        if let point, !toolbar.isHidden, toolbar.frame.contains(scrollView.convert(point, from: nil)) { return }
        var row = point.map { table.row(at: table.convert($0, from: nil)) } ?? -1
        // Slack's dividers let the pointer through: over one, it hovers the message the divider introduces.
        while rows.indices.contains(row), rows[row].isDivider { row += 1 }
        let id: String? =
            if rows.indices.contains(row), case .message = rows[row].kind { rows[row].id } else { nil }
        guard id != hoveredID else { return }
        let previous = hoveredID.flatMap { index[$0] }
        hoveredID = id
        reactionFrames = [:]
        if let previous { refresh(previous) }
        if let id, let row = index[id] { refresh(row) }
        placeToolbar()
    }

    /// Follows the pointer as rows move under it, and the hovered row as it changes.
    private func updateHover() {
        guard let window = scrollView.window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let inside = scrollView.bounds.contains(scrollView.convert(point, from: nil))
        pointerMoved(inside ? point : nil)
        placeToolbar()
    }

    /// The one hover toolbar, hung on the hovered row's top right edge as Slack hangs it, never down over the row's
    /// first line, and kept inside the viewport.
    private func placeToolbar() {
        guard let id = hoveredID, let row = index[id], case .message(let entry) = rows[row].kind,
            !entry.message.isRedacted, let context = configuration?.context
        else {
            toolbar.isHidden = true
            return
        }
        if toolbarEntry != rows[row] {
            toolbarEntry = rows[row]
            toolbar.rootView = HoveredMessageToolbar(entry: entry, context: context)
            toolbar.frame.size = toolbar.fittingSize
        }
        if toolbar.superview == nil { scrollView.addSubview(toolbar) }
        let m = context.metrics
        let size = toolbar.frame.size
        let rect = table.rect(ofRow: row)
        let top = scrollView.convert(NSPoint(x: rect.midX + rowWidth / 2, y: rect.minY), from: table)
        // In the scroll view's flipped coordinates, from the viewport's top down, between the header and composer.
        let clip = scrollView.contentView.frame
        let visible = NSRect(
            x: clip.minX, y: clip.minY + insets.top, width: clip.width,
            height: clip.height - insets.top - insets.bottom)
        let compact = context.appearance?.density == .compact
        let inset = min(
            size.height / 2,
            MessageRow.topInset(m, grouped: entry.grouped, compact: compact, followsAttachment: entry.followsAttachment)
        )
        let y = min(max(top.y + inset - size.height, visible.minY + m.sp4), visible.maxY - size.height)
        toolbar.frame.origin = NSPoint(x: top.x - m.conversationInset(thread: context.isThread) - size.width, y: y)
        toolbar.isHidden = false
    }

    /// Slack's tooltip over the reaction under the pointer, naming who reacted.
    private func placeTooltip() {
        guard !reactionFrames.isEmpty, let pointer, let window = scrollView.window, let id = hoveredID,
            let row = index[id], case .message(let entry) = rows[row].kind,
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell,
            case (let key, let frame)? = reactionFrames.lazy.map({ ($0, cell.content.convert($1, to: nil)) })
                .first(where: { $1.contains(pointer) }),
            let reaction = entry.message.reactions.first(where: { $0.key == key }),
            let context = configuration?.context, let appearance = context.appearance
        else { return tooltip.hide() }
        let members = context.matrix?.members ?? []
        let text = reaction.tooltip(me: context.matrix?.user?.id) { id in members.first { $0.id == id }?.name }
        let m = context.metrics
        tooltip.show(text, above: frame, in: window, metrics: m) {
            Tooltip(text: text) { Text(key).font(m.font(.largeTitle)) }
                .environment(\.metrics, m).environmentObject(appearance)
        }
    }
}

extension TimelineEntry {
    fileprivate var messageEventID: String? {
        if case .message(let entry) = kind { entry.message.eventID } else { nil }
    }

    fileprivate var isDivider: Bool {
        switch kind {
        case .day, .unread, .replies: true
        case .spacer, .loading, .welcome, .message, .end: false
        }
    }
}

final class TimelineScrollView: NSScrollView {
    var willTile: (() -> Void)?
    var onTile: (() -> Void)?
    var onPointer: ((NSPoint?) -> Void)?
    /// True while a modal, drawer, or covering pane sits above this timeline.
    var isCovered = false {
        didSet {
            guard isCovered != oldValue else { return }
            if isCovered { onPointer?(nil) }
            syncCoveredTextViews(in: self)
            window?.invalidateCursorRects(for: self)
        }
    }
    /// One area for the view's life: `.inVisibleRect` follows every resize, and replacing it would send the hovered
    /// message an exit and an enter at each step of a live resize or a pane drag, blinking its highlight.
    private lazy var tracking = NSTrackingArea(
        rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)

    private func syncCoveredTextViews(in view: NSView) {
        for subview in view.subviews {
            if let textView = subview as? MessageTextView {
                textView.syncCoveredCursor()
            } else {
                syncCoveredTextViews(in: subview)
            }
        }
    }

    override func tile() {
        willTile?()
        super.tile()
        onTile?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(tracking) { addTrackingArea(tracking) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard !isCovered else { return }
        onPointer?(event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        guard !isCovered else { return }
        onPointer?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Rows and the toolbar pass their controls' exits up the responder chain; only this view's own means the
        // pointer left.
        if event.trackingArea?.owner === self { onPointer?(nil) }
    }

    // Takes the hover, and any tooltip over the window, along when the timeline goes.
    override func viewWillMove(toWindow window: NSWindow?) {
        super.viewWillMove(toWindow: window)
        if window == nil { onPointer?(nil) }
    }
}

final class TimelineToolbarView: NSHostingView<HoveredMessageToolbar?> {
    // Clicks between its buttons stay with the toolbar; the window moves by its background.
    override var mouseDownCanMoveWindow: Bool { false }
}

final class TimelineTableView: NSTableView {
    // Rows are messages, not selectable records; text inside them stays selectable.
    override var acceptsFirstResponder: Bool { false }
}

/// A row's cell. It answers for the row's context menu and VoiceOver actions, as SwiftUI's own modifiers would, without
/// every row at rest carrying them.
final class TimelineCell: NSView {
    private let host = NSHostingController(rootView: TimelineRow?.none)
    /// The row's SwiftUI content, in whose coordinates it reports where its parts are.
    var content: NSView { host.view }
    /// What the cell shows, so showing the same row again is free.
    var row: TimelineRow? { host.rootView }
    var entry: TimelineEntry? { host.rootView?.entry }
    /// A message's menu, or with `true` its VoiceOver actions; nil for other rows.
    private var commands: ((Bool) -> [MessageMenuCommand])?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        // A row never sits under the toolbar, and following the safe area would update every row on every scroll.
        host.safeAreaRegions = []
        host.view.frame = bounds
        host.view.autoresizingMask = [.width, .height]
        // Every text view in the app hears every frame change posted; rows move on every scroll step.
        postsFrameChangedNotifications = false
        host.view.postsFrameChangedNotifications = false
        addSubview(host.view)
    }

    required init?(coder: NSCoder) { nil }

    func show(_ row: TimelineRow, commands: ((Bool) -> [MessageMenuCommand])?) {
        host.rootView = row
        self.commands = commands
    }

    /// Drops the hosted row so idle spare and recycled cells neither retain old contexts nor stay subscribed.
    func clear() {
        host.rootView = nil
        commands = nil
    }

    /// The row's height at `width`, from the same views it is drawn with.
    func height(width: CGFloat) -> CGFloat { host.sizeThatFits(in: CGSize(width: width, height: 0)).height }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let commands else { return super.menu(for: event) }
        let menu = NativeMessageMenu.make(commands: commands(false))
        // As SwiftUI's context menu drew them: a destructive item is not red here.
        for item in menu.items { item.attributedTitle = nil }
        return menu
    }

    override func isAccessibilityElement() -> Bool { commands != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { commands != nil ? .group : super.accessibilityRole() }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let commands else { return super.accessibilityCustomActions() }
        return commands(true).filter { $0.isEnabled && !$0.isSeparator }.map { command in
            NSAccessibilityCustomAction(name: command.title) {
                command.perform()
                return true
            }
        }
    }
}

/// A timeline row's SwiftUI content, measured and shown in the same cell. Equal rows draw the same.
struct TimelineRow: View, Equatable {
    /// The cell's coordinates, as SwiftUI names them.
    static let space = "TimelineRow"
    let entry: TimelineEntry
    let hovered: Bool
    /// Zoom, held here rather than read from the shared context, so a change to it redraws the row.
    let metrics: Metrics
    let context: TimelineRowContext

    init(entry: TimelineEntry, hovered: Bool, context: TimelineRowContext) {
        self.entry = entry
        self.hovered = hovered
        metrics = context.metrics
        self.context = context
    }

    static func == (a: Self, b: Self) -> Bool {
        a.entry == b.entry && a.hovered == b.hovered && a.metrics == b.metrics && a.context === b.context
    }

    var body: some View {
        if let appearance = context.appearance {
            content.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                // The content's own height, inside the cell's frame: the frame never gets shorter than the cell, so
                // read there a row whose content shrank (names landing, a preview going) would keep a gap under it.
                .background {
                    GeometryReader { geometry in
                        // From the first layout too: a row measured off screen can change before it is shown.
                        Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                            context.onHeight(entry.id, height)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .environment(\.metrics, metrics).environmentObject(appearance)
                .environment(\.openURL, context.openURL)
                .environment(
                    \.mentions, MentionContext(me: context.matrix?.user?.id, members: context.matrix?.members ?? [])
                )
                .coordinateSpace(.named(Self.space))
        }
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .spacer, .end: Color.clear
        case .loading(let loading, let immediate):
            TimelineLoadingRow(
                loading: loading, offline: context.matrix?.connectionState == .offline, immediate: immediate)
        case .welcome(let welcome):
            TimelineWelcomeRow(welcome: welcome).conversationRow(metrics, isThread: context.isThread)
        case .day(let label):
            TimelineDayDivider(label: label, isThread: context.isThread).conversationRow(
                metrics, isThread: context.isThread)
        case .unread: TimelineUnreadDivider().conversationRow(metrics, isThread: context.isThread)
        case .replies(let count): TimelineRepliesDivider(count: count)
        case .message(let row):
            if let matrix = context.matrix {
                let message = row.message
                let own = message.senderID == matrix.user?.id
                MessageRow(
                    message: message, grouped: row.grouped, followsAttachment: row.followsAttachment,
                    isThread: context.isThread,
                    own: own, highlighted: row.highlighted, isSaved: row.saved,
                    isPinned: row.pinned, sendFailure: row.sendFailure, sendWaitStatus: row.sendWaitStatus,
                    sendBusy: row.sendBusy, hovered: hovered,
                    timeLabel: row.time,
                    seen: row.seenBy.map { readers in
                        (
                            !readers.isEmpty,
                            readers.isEmpty
                                ? nil
                                : SeenPolicy.tooltip(readers) { id in matrix.members.first { $0.id == id }?.name }
                        )
                    },
                    avatar: AvatarView(
                        name: message.senderName, size: metrics.avatar, matrix: matrix, source: message.avatarURL),
                    replierAvatar: message.lastReply.map {
                        AvatarView(
                            name: $0.senderName, size: metrics.avatarSmall, matrix: matrix, source: $0.avatarURL)
                    },
                    replyPreview: message.replyPreview.map { preview in
                        let needsOrigin = preview.state == .unavailable || preview.state == .failed
                        return ReplyPreviewView(
                            matrix: matrix, message: message, preview: preview,
                            origin: needsOrigin ? context.actionTarget(for: message) : nil,
                            onOpen: context.onShowReply, onOpenThread: context.onThread)
                    },
                    attachment: message.attachment.map {
                        AttachmentView(
                            matrix: matrix, message: message, attachment: $0, collapsed: row.mediaCollapsed,
                            pendingSend: own && message.sendState != "sent",
                            actions: context.rowAttachmentActions(for: message))
                    },
                    actions: context.rowActions(for: row),
                    reactionFrame: { context.onReactionFrame(entry.id, $0, $1) })
            }
        }
    }
}

extension View {
    /// Spans the pane width cleanly for both conversations and threads, matching Slack desktop.
    func conversationRow(_ m: Metrics, isThread: Bool) -> some View {
        frame(maxWidth: .infinity)
    }

    /// Keeps this view between the edges of `ConversationGrid`'s column, as the composer does under the messages.
    func conversationColumn(_ m: Metrics, isThread: Bool) -> some View {
        padding(.horizontal, m.conversationInset(thread: isThread)).frame(maxWidth: .infinity)
    }
}

private struct TimelineLoadingRow: View {
    @Environment(\.metrics) private var m
    let loading: Bool
    let offline: Bool
    var immediate = false
    var body: some View {
        DelayedProgress(active: loading, offline: offline, interval: .historyLoading, immediate: immediate)
            .frame(maxWidth: .infinity).frame(height: m.sp40)
    }
}

private struct TimelineWelcomeRow: View {
    private static let tile: CGFloat = 64
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let welcome: TimelineWelcome
    var body: some View {
        let colors = appearance.colors
        VStack(alignment: .leading, spacing: m.sp12) {
            Image(
                systemName: welcome.isDirect
                    ? "bubble.left.and.bubble.right.fill" : welcome.isPrivate ? "lock.fill" : "number"
            )
            .font(m.font(.title1, .semibold)).foregroundStyle(colors.textSecondary)
            .frame(width: m(Self.tile), height: m(Self.tile))
            .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusPanel))
            Text(welcome.isDirect || welcome.isPrivate ? welcome.name : "# \(welcome.name)")
                .font(m.font(.largeTitle, .bold)).foregroundStyle(colors.textPrimary)
            Text(
                !welcome.topic.isEmpty
                    ? welcome.topic
                    : welcome.isDirect
                        ? "This is the beginning of your conversation with \(welcome.name)."
                        : "This is the beginning of the \(welcome.name) channel."
            ).font(m.font(.reading)).foregroundStyle(colors.textSecondary).lineSpacing(m.lineSpacing(.reading))
            if welcome.isEncrypted {
                Label("End-to-end encrypted", systemImage: "lock.shield")
                    .font(m.font(.caption)).foregroundStyle(colors.textSecondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(m.sp20)
    }
}

struct TimelineDayDivider: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let label: String
    let isThread: Bool
    var body: some View {
        let colors = appearance.colors
        HStack(spacing: m.sp12) {
            Rectangle().fill(colors.border).frame(height: 1)
            Text(label).font(m.font(.subheadline, .semibold)).foregroundStyle(colors.textSecondary)
            Rectangle().fill(colors.border).frame(height: 1)
        }
        // 20 above the day and 4 below: a sender's own 12 clears that, a compact row's 2 needs 2 more.
        .frame(height: m.sp16).padding(.horizontal, m.conversationInset(thread: isThread)).padding(.top, m.sp20)
        .padding(.bottom, appearance.density == .compact ? m.sp2 : 0)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Under a thread's root, Slack's count of its replies with a rule running on to the pane's edge.
private struct TimelineRepliesDivider: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let count: Int
    var body: some View {
        let colors = appearance.colors
        HStack(spacing: m.sp8) {
            Text("\(count) \(count == 1 ? "reply" : "replies")").font(m.font(.subheadline, .semibold))
                .foregroundStyle(colors.textSecondary)
            Rectangle().fill(colors.border).frame(height: 1)
        }
        .frame(height: m.sp16).padding(.horizontal, m.conversationInset(thread: true)).padding(.top, m.sp12)
        .padding(.bottom, appearance.density == .compact ? m.sp2 : 0)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A rule over the first unread message, with "New" at its right end, in the accent.
private struct TimelineUnreadDivider: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let colors = appearance.colors
        HStack(spacing: m.sp4) {
            Rectangle().fill(colors.accentFill).frame(height: 1)
            Text("New").font(m.font(.subheadline, .semibold)).foregroundStyle(colors.accent)
        }.padding(.horizontal, m.sp20).padding(.vertical, m.sp8)
            .accessibilityElement(children: .ignore).accessibilityLabel("New messages begin here")
    }
}
