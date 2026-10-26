import AppKit
import SwiftUI

/// One row of a conversation or thread timeline: everything its cell shows, so an unchanged entry never redraws.
struct TimelineEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Fills a short conversation from the top, so its messages sit on the composer like Slack's.
        case spacer
        /// Room for a spinner while history beyond this end exists.
        case loading(Bool)
        case welcome(TimelineWelcome)
        case day(String)
        case unread
        case message(TimelineMessageEntry)
        case end
    }
    let id: String
    var kind: Kind

    /// The parts of this entry that decide its height, the same in every timeline that shows the message.
    fileprivate var layoutKey: TimelineEntry {
        guard case .message(var entry) = kind else { return TimelineEntry(id: "", kind: kind) }
        entry.message.id = entry.message.eventID
        entry.message.timelineEventID = nil
        entry.saved = false
        entry.highlighted = false
        entry.sendBusy = false
        entry.context = nil
        return TimelineEntry(id: "", kind: .message(entry))
    }
}

struct TimelineWelcome: Hashable {
    var name: String
    var topic: String
    var isDirect: Bool
    var isEncrypted: Bool
}

struct TimelineMessageEntry: Hashable {
    var message: ChatMessage
    var grouped: Bool
    var time: String
    var saved: Bool
    var pinned: Bool
    var canPin: Bool
    var highlighted: Bool
    var sendFailure: MessageSendFailure?
    var sendBusy: Bool
    /// The reader collapsed this message's image or video.
    var mediaCollapsed = false
    /// Rows capture their action target from it, so a new context redraws them.
    var context: MessageActionTarget.Context?
}

/// What every row of one timeline shares: the session and the actions rows call back into.
@MainActor final class TimelineRowContext {
    var matrix = MatrixService?.none
    var isThread = false
    var threadRootID: String?
    var metrics = Metrics()
    var appearance: AppearanceStore?
    var openURL = OpenURLAction { _ in .systemAction }
    var onThread: (ChatMessage) -> Void = { _ in }
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
    var onReact: (MessageActionTarget, String) -> Void = { _, _ in }
    var onRetrySend: (ChatMessage) -> Void = { _ in }
    var onCancelSend: (ChatMessage) -> Void = { _ in }
    var onCopyLink: (MessagePermalinkTarget) -> Void = { _ in }
    /// Whether a link to this event is being copied.
    var isCopyingLink: (String) -> Bool = { _ in false }
    /// Shows the one reaction picker over a row, by row ID; the table owns it.
    var onPickReaction: (String, MessageActionTarget, @escaping (String) -> Void) -> Void = { _, _, _ in }
    /// A displayed row whose height no longer matches its measurement, after state of its own changed.
    var onHeight: (String, CGFloat) -> Void = { _, _ in }
}

/// Lets the SwiftUI shell move the list without owning it.
@MainActor final class TimelineScroller {
    fileprivate var bottom: (() -> Void)?
    func scrollToBottom() { bottom?() }
}

/// The timeline list: an AppKit table of SwiftUI rows with measured, cached heights. Every change to the rows, their
/// heights or the viewport is applied and the scroll position corrected in the same layout pass, before anything is
/// drawn, so content never jumps. `TimelineScrollPolicy` decides where the viewport goes.
struct TimelineTable: NSViewRepresentable {
    var entries: [TimelineEntry]
    var context: TimelineRowContext
    var live: Bool
    var bottomAligned: Bool
    var focusedEventID: String?
    var startsAtUnread: Bool
    /// Where to remember the reading position across visits; nil for a timeline opened at an older message.
    var memoryKey: String?
    var canLoadOlder: Bool
    var canLoadNewer: Bool
    var scroller: TimelineScroller
    var onLoadOlder: () -> Void
    var onLoadNewer: () -> Void
    /// Whether the newest message is on screen, and whether to offer "Jump to recent".
    var onScroll: (Bool, Bool) -> Void

    func makeCoordinator() -> TimelineTableCoordinator { TimelineTableCoordinator() }

    func makeNSView(context: Context) -> TimelineScrollView {
        context.coordinator.makeView()
    }

    func updateNSView(_ view: TimelineScrollView, context: Context) {
        context.coordinator.update(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    static func dismantleNSView(_ view: TimelineScrollView, coordinator: TimelineTableCoordinator) {
        coordinator.closePicker()
        coordinator.remember()
        coordinator.stopLoading()
        coordinator.recycleCells()
    }
}

/// Reading positions by conversation, for coming back to where you left off. Session-scoped keys keep accounts apart.
@MainActor private enum TimelineMemory {
    static var positions: [String: TimelineScrollPolicy.Position] = [:]
}

@MainActor final class TimelineTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private typealias Policy = TimelineScrollPolicy
    private static let cellID = NSUserInterfaceItemIdentifier("timeline-row")
    /// Heights by layout, width and display settings, shared by every timeline so revisiting a room measures nothing.
    private struct HeightKey: Hashable {
        var entry: TimelineEntry
        var width: CGFloat
        var settings: Settings
    }
    private struct Settings: Hashable {
        var zoom: CGFloat
        var density: MessageDensity
        var showAvatars: Bool
    }
    private static var heights: [HeightKey: CGFloat] = [:]
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
    /// Rows whose height in the table is an estimate. Only rows on screen are measured at once, and those near it
    /// between frames, so opening a room or loading a page lays out a screenful, not the whole history.
    private var estimated = Set<String>()
    private var opened = false
    private var pendingFocus: String?
    private var hoveredID: String?
    /// Heights of this table's rows the table has been given, by row ID; the rest are estimates.
    private var known: [String: CGFloat] = [:]
    private var prefetching = false
    private var scrollingUp = true
    private var lastTop: CGFloat = 0
    private var applying = false
    private var reported: (Bool, Bool)?
    /// While the table waits for its first rows.
    private var loading: Performance.Interval?
    /// The reaction picker, over the row it was opened for.
    private var picker: (popover: NSPopover, rowID: String, target: MessageActionTarget)?

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
        scrollView.onTile = { [weak self] in self?.viewportResized() }
        scrollView.onPointer = { [weak self] point in self?.pointerMoved(point) }
        return scrollView
    }

    func update(_ configuration: TimelineTable) {
        let previous = self.configuration
        self.configuration = configuration
        if previous == nil, !opened {
            loading = Performance.begin(configuration.context.isThread ? .threadLoading : .timelineLoading)
        }
        configuration.context.onHeight = { [weak self] id, height in self?.reported(height, for: id) }
        configuration.context.onPickReaction = { [weak self] id, target, pick in
            self?.showPicker(over: id, target: target, onPick: pick)
        }
        if let picker, configuration.context.matrix?.isCurrentMessageAction(picker.target) != true { closePicker() }
        configuration.scroller.bottom = { [weak self] in self?.scrollToBottom(animated: true) }
        if previous?.focusedEventID != configuration.focusedEventID { pendingFocus = configuration.focusedEventID }
        apply(configuration.entries)
    }

    // MARK: Rows

    private func apply(_ entries: [TimelineEntry]) {
        guard width > 0, let configuration else { return }
        let settings = Settings(
            zoom: configuration.context.metrics.zoom,
            density: configuration.context.appearance?.density ?? .comfortable,
            showAvatars: configuration.context.appearance?.showAvatars ?? true)
        let settingsChanged = settings != self.settings
        self.settings = settings
        // The timeline hands back the same array while nothing in it changed, which makes this check instant.
        guard entries != applied || settingsChanged else { return }
        applied = entries
        let next =
            [TimelineEntry(id: "spacer", kind: .spacer)] + entries + [TimelineEntry(id: "end", kind: .end)]
        guard next != rows || settingsChanged else { return }
        let interval = Performance.begin(.timelineApply)
        defer { Performance.end(interval, ["rows": next.count]) }
        guard opened || !rows.isEmpty else {
            rows = next
            reindex()
            table.reloadData()
            open()
            return
        }
        preservingPosition {
            let difference = next.map(\.id).difference(from: rows.map(\.id))
            if !difference.isEmpty {
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.beginUpdates()
                for case .remove(let offset, _, _) in difference.removals.reversed() {
                    rows.remove(at: offset)
                    table.removeRows(at: [offset], withAnimation: [])
                }
                for case .insert(let offset, _, _) in difference.insertions {
                    rows.insert(next[offset], at: offset)
                    table.insertRows(at: [offset], withAnimation: [])
                }
                table.endUpdates()
                NSAnimationContext.endGrouping()
                reindex()
            }
            var changed = IndexSet()
            if settingsChanged { known = [:] }
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
                { [id = entry.id] accessibility in
                    let target = context.actionTarget(for: row.message)
                    return accessibility
                        ? context.accessibilityCommands(for: id, row, target: target)
                        : context.actions(for: id, row, target: target).menu()
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
        for cell in cells where Self.recycled.count < Self.recycledCells {
            cell.removeFromSuperview()
            Self.recycled.append(cell)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let entry = rows[row]
        switch entry.kind {
        case .spacer: return max(1, spacerHeight)
        case .end: return configuration?.context.metrics.sp8 ?? 8
        default: break
        }
        if let height = known[entry.id] {
            estimated.remove(entry.id)
            return height
        }
        estimated.insert(entry.id)
        return estimate(entry)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = prepared.removeValue(forKey: rows[row].id) ?? dequeue()
        show(rows[row], in: cell)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    /// The picker follows its row off screen, as a popover attached to the row itself would.
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        if let picker, row < 0 || index[picker.rowID] == row || index[picker.rowID] == nil { closePicker() }
    }

    // MARK: Reaction picker

    private func showPicker(over id: String, target: MessageActionTarget, onPick: @escaping (String) -> Void) {
        closePicker()
        guard let row = index[id], let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false),
            let configuration
        else { return }
        let m = configuration.context.metrics
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ReactionPicker { [weak self] key in
                onPick(key)
                self?.closePicker()
            }.padding(m.sp12).environment(\.metrics, m))
        picker = (popover, id, target)
        popover.show(relativeTo: cell.bounds, of: cell, preferredEdge: .maxY)
    }

    func closePicker() {
        picker?.popover.close()
        picker = nil
    }

    // MARK: Heights

    private func key(_ entry: TimelineEntry) -> HeightKey? {
        settings.map { HeightKey(entry: entry.layoutKey, width: width, settings: $0) }
    }

    /// Builds the row's cell off screen and measures it there, so showing it later costs no SwiftUI work. Returns
    /// whether the table had only an estimate for it.
    @discardableResult private func prepare(_ row: Int) -> Bool {
        let entry = rows[row]
        guard let key = key(entry) else { return false }
        let shown = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell
        let cell = shown ?? prepared[entry.id] ?? dequeue()
        if shown == nil { prepared[entry.id] = cell }
        show(entry, in: cell)
        let wasKnown = known[entry.id] != nil
        let measured = Self.heights[key]
        // shortcut: the cache is dropped whole when it grows past a few busy rooms at a few widths; an LRU if that
        // shows up in profiles.
        if Self.heights.count > 50_000 { Self.heights.removeAll() }
        // Whole points keep every row, and the text in it, on the pixel grid.
        let height = measured ?? max(1, ceil(cell.height(width: width)))
        Self.heights[key] = height
        known[entry.id] = height
        if shown == nil { cell.frame = NSRect(x: 0, y: 0, width: width, height: height) }
        return !wasKnown
    }

    /// Rows the reader left behind give their cells back for the next ones.
    private func releasePrepared(outside near: NSRange) {
        for (id, cell) in prepared where index[id].map({ !NSLocationInRange($0, near) }) ?? true {
            prepared[id] = nil
            if spares.count < Self.spareCells { spares.append(cell) }
        }
    }

    /// Rough, cheap and never shown: a row is measured before it is drawn.
    private func estimate(_ entry: TimelineEntry) -> CGFloat {
        let m = configuration?.context.metrics ?? Metrics()
        switch entry.kind {
        case .spacer, .end, .loading: return m.sp40
        case .welcome: return m(220)
        case .day: return m(56)
        case .unread: return m(40)
        case .message(let row):
            let line = m.size(.body) * 1.4
            let perLine = max(20, (width - m(100)) / (m.size(.body) * 0.5))
            // Characters counted as UTF-8 lead bytes: a whole room is estimated at once, and grapheme breaking costs
            // more than this guess is worth.
            var lines: CGFloat = 0
            var characters: CGFloat = 0
            for byte in row.message.body.utf8 {
                if byte == 10 {
                    lines += max(1, ceil(characters / perLine))
                    characters = 0
                } else if byte & 0xC0 != 0x80 {
                    characters += 1
                }
            }
            lines += max(1, ceil(characters / perLine))
            var height = (row.grouped ? m.sp8 : m(40)) + lines * line
            if !row.message.reactions.isEmpty { height += m(30) }
            if row.message.attachment != nil { height += m(300) }
            if row.message.replyPreview != nil { height += m(48) }
            if row.message.replyCount > 0 { height += m(28) }
            return height
        }
    }

    /// Measures the estimated rows on screen, keeping `position` (or the first measured row on screen) where it is.
    /// Rows near the screen are measured ahead, between frames.
    private func settle(keeping position: Policy.Position?) {
        defer { prefetchSoon() }
        for _ in 0..<4 {
            let shown = table.rows(in: scrollView.contentView.bounds)
            let pending = IndexSet((Range(shown) ?? 0..<0).filter { estimated.contains(rows[$0].id) })
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
        DispatchQueue.main.async { [weak self] in self?.prefetch() }
    }

    /// Prepares the cells of rows within `Self.ahead` screens of the viewport, nearest first, for a few milliseconds
    /// a pass, so scrolling finds them built and measured and no frame waits on many at once.
    private func prefetch() {
        prefetching = false
        guard opened, viewportHeight > 0 else { return }
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
        Performance.measure(.rowsMeasure, ["rows": pending.count]) {
            for row in pending where done == 0 || ContinuousClock.now < deadline {
                if prepare(row) { measured.insert(row) }
                done += 1
            }
        }
        if measured.isEmpty { prefetchSoon() } else { preservingPosition { noteHeights(measured) } }
    }

    /// A row's own state (a revealed spoiler, an error under an attachment) changed its height.
    private func reported(_ reported: CGFloat, for id: String) {
        let height = ceil(reported)
        // Only a row laid out at its measured height says something about its content: a reused cell reports its
        // old row's height first.
        guard let row = index[id], let key = key(rows[row]), let measured = Self.heights[key],
            abs(height - measured) > 0.5,
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineCell,
            cell.entry?.id == id, abs(cell.frame.height - measured) < 0.5
        else { return }
        Self.heights[key] = height
        known[id] = height
        // Not inside the SwiftUI update that reported it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.index[id] == row else { return }
            self.preservingPosition { self.noteHeights([row]) }
        }
    }

    /// Every row is re-estimated at a new width; the settle that follows measures the ones near the viewport.
    private func remeasure() {
        known = [:]
        guard !rows.isEmpty else { return }
        preservingPosition { noteHeights(IndexSet(integersIn: 0..<rows.count)) }
    }

    /// Without an explicit zero duration the table animates row heights, drawing rows where they no longer are.
    private func noteHeights(_ rows: IndexSet) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.noteHeightOfRows(withIndexesChanged: rows)
        NSAnimationContext.endGrouping()
    }

    // MARK: Position

    private var viewport: Policy.Viewport {
        let bounds = scrollView.contentView.bounds
        return Policy.Viewport(
            top: bounds.minY, height: bounds.height,
            contentHeight: rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY)
    }

    private func frame(_ id: String) -> Policy.RowFrame? {
        guard let row = index[id] else { return nil }
        let rect = table.rect(ofRow: row)
        return Policy.RowFrame(id: id, top: rect.minY, height: rect.height)
    }

    /// The first message on screen anchors the view: unlike a day divider it never moves among its neighbours.
    /// Rows about to be measured anchor it only when nothing else is on screen.
    private func firstVisibleRow(excluding excluded: IndexSet) -> Policy.RowFrame? {
        let visible = table.rows(in: scrollView.contentView.bounds)
        guard let range = Range(visible) else { return nil }
        let shown = range.filter { rows[$0].kind != .spacer && rows[$0].kind != .end }
        // After a jump into rows never measured, the first of them holds its place while they are.
        let measured = shown.filter { !excluded.contains($0) }
        let candidates = measured.isEmpty ? shown : measured
        let row = candidates.first { if case .message = rows[$0].kind { true } else { false } } ?? candidates.first
        return row.flatMap { frame(rows[$0].id) }
    }

    private func position(excluding excluded: IndexSet = []) -> Policy.Position {
        Policy.position(
            of: viewport, live: configuration?.live ?? true, firstVisibleRow: firstVisibleRow(excluding: excluded))
    }

    /// Applies a change to rows or heights and puts the viewport back where the policy says, before display.
    private func preservingPosition(_ change: () -> Void) {
        let position = opened ? position() : nil
        let reading = readingRow()
        applying = true
        change()
        updateSpacer()
        if let position { scroll(to: position) }
        settle(keeping: position)
        applying = false
        noteJump(from: reading)
        afterScroll()
    }

    /// The row the reader is looking at and where it sits in the viewport, unless they are at the newest message.
    private func readingRow() -> (id: String, top: CGFloat)? {
        guard opened, !viewport.isAtBottom, let row = firstVisibleRow(excluding: []) else { return nil }
        return (row.id, row.top - scrollView.contentView.bounds.minY)
    }

    /// The policy holds the reader's row still through every change; this counts each time it did not.
    private func noteJump(from reading: (id: String, top: CGFloat)?) {
        guard let reading, let row = frame(reading.id) else { return }
        let moved = row.top - scrollView.contentView.bounds.minY - reading.top
        if abs(moved) >= 1 { Performance.event(.timelineJump, ["px": Int(moved.rounded())]) }
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
        guard hasContent else {
            scroll(to: .bottom)
            return settle(keeping: .bottom)
        }
        opened = true
        let focused = pendingFocus.flatMap { focus in rows.first { $0.messageEventID == focus }?.id }
        if focused != nil { pendingFocus = nil }
        let remembered = configuration.memoryKey.flatMap { TimelineMemory.positions[$0] }.flatMap(local)
        let opening = Policy.opening(
            focusedRowID: focused, unreadRowID: index["unread"] == nil ? nil : "unread",
            startsAtUnread: configuration.startsAtUnread, remembered: remembered, contains: { index[$0] != nil })
        scroll(to: opening)
        settle(keeping: opening)
        stopLoading()
        if !configuration.context.isThread {
            Performance.finishOnScreen(.roomOpen, ["rows": rows.count])
            Performance.finishOnScreen(.launchConversation, ["rows": rows.count])
        }
    }

    func stopLoading() {
        if let loading { Performance.end(loading) }
        loading = nil
    }

    private func scroll(to position: Policy.Position) {
        table.tile()
        let viewport = viewport
        guard
            let top = Policy.top(
                for: position, contentHeight: viewport.contentHeight, viewportHeight: viewport.height, frame: frame)
        else { return }
        let clip = scrollView.contentView
        guard abs(clip.bounds.minY - top) > 0.01 else { return }
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: top))
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollToBottom(animated: Bool) {
        let viewport = viewport
        let top = max(0, viewport.contentHeight - viewport.height)
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
        let content = table.rect(ofRow: rows.count - 1).maxY - table.rect(ofRow: 0).height
        let height = max(0, viewportHeight - content)
        guard abs(height - spacerHeight) > 0.25 else { return }
        spacerHeight = height
        noteHeights([0])
    }

    private func viewportResized() {
        let size = scrollView.contentView.bounds.size
        guard size.width > 0, size != NSSize(width: width, height: viewportHeight) else { return }
        let widthChanged = size.width != width
        let first = width == 0
        width = size.width
        viewportHeight = size.height
        table.tableColumns.first?.width = width
        if first, let configuration { return apply(configuration.entries) }
        if widthChanged {
            remeasure()
        } else {
            preservingPosition {}
        }
    }

    @objc private func boundsChanged() {
        guard !applying, scrollView.contentView.bounds.size == NSSize(width: width, height: viewportHeight) else {
            return
        }
        // The reader moved: a linked message that has not loaded yet no longer takes over the view.
        pendingFocus = nil
        let top = scrollView.contentView.bounds.minY
        if top != lastTop { scrollingUp = top < lastTop }
        lastTop = top
        let reading = readingRow()
        applying = true
        settle(keeping: nil)
        applying = false
        noteJump(from: reading)
        updateHover()
        afterScroll()
    }

    /// Reports the viewport's state and loads history ahead of the reader.
    private func afterScroll() {
        guard let configuration else { return }
        let viewport = viewport
        let state = (viewport.isAtBottom, opened && Policy.showsJumpToLatest(viewport, live: configuration.live))
        if reported.map({ $0 != state }) ?? true {
            reported = state
            // SwiftUI state; never changed from inside its own update or layout.
            DispatchQueue.main.async { configuration.onScroll(state.0, state.1) }
        }
        if let pendingFocus, let row = rows.first(where: { $0.messageEventID == pendingFocus }) {
            self.pendingFocus = nil
            applying = true
            scroll(to: .centered(rowID: row.id))
            settle(keeping: .centered(rowID: row.id))
            applying = false
        }
        checkHistory()
    }

    private func checkHistory() {
        guard opened, let configuration else { return }
        let viewport = viewport
        if configuration.canLoadOlder && Policy.needsOlder(viewport) {
            DispatchQueue.main.async { configuration.onLoadOlder() }
        } else if configuration.canLoadNewer && Policy.needsNewer(viewport) {
            DispatchQueue.main.async { configuration.onLoadNewer() }
        }
    }

    func remember() {
        guard opened, let key = configuration?.memoryKey else { return }
        TimelineMemory.positions[key] = persistent(position())
    }

    /// Row IDs are per timeline instance; a remembered position names a message by its event instead.
    private func persistent(_ position: Policy.Position) -> Policy.Position {
        guard case .anchored(let id, let offset) = position, let row = index[id], let event = rows[row].messageEventID
        else { return position }
        return .anchored(rowID: "event:" + event, offset: offset)
    }

    private func local(_ position: Policy.Position) -> Policy.Position? {
        guard case .anchored(let id, let offset) = position, id.hasPrefix("event:") else { return position }
        let event = String(id.dropFirst(6))
        return rows.first { $0.messageEventID == event }.map { .anchored(rowID: $0.id, offset: offset) }
    }

    // MARK: Hover

    private func pointerMoved(_ point: NSPoint?) {
        let row = point.map { table.row(at: table.convert($0, from: nil)) } ?? -1
        let id: String? =
            if row >= 0, row < rows.count, case .message = rows[row].kind { rows[row].id } else { nil }
        guard id != hoveredID else { return }
        let previous = hoveredID.flatMap { index[$0] }
        hoveredID = id
        if let previous { refresh(previous) }
        if let id, let row = index[id] { refresh(row) }
    }

    private func updateHover() {
        guard let window = scrollView.window else { return }
        let point = window.mouseLocationOutsideOfEventStream
        let inside = scrollView.bounds.contains(scrollView.convert(point, from: nil))
        pointerMoved(inside ? point : nil)
    }
}

extension TimelineEntry {
    fileprivate var messageEventID: String? {
        if case .message(let entry) = kind { entry.message.eventID } else { nil }
    }
}

final class TimelineScrollView: NSScrollView {
    var onTile: (() -> Void)?
    var onPointer: ((NSPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func tile() {
        super.tile()
        onTile?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointer?(event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }
}

final class TimelineTableView: NSTableView {
    // Rows are messages, not selectable records; text inside them stays selectable.
    override var acceptsFirstResponder: Bool { false }
}

/// A row's cell. It answers for the row's context menu and VoiceOver actions, as SwiftUI's own modifiers would, without
/// every row at rest carrying them.
final class TimelineCell: NSView {
    private let host = NSHostingController(rootView: TimelineRow?.none)
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
                .frame(maxHeight: .infinity, alignment: .top)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.height) { _, height in
                            context.onHeight(entry.id, height)
                        }
                    }
                }
                .environment(\.metrics, metrics).environmentObject(appearance)
                .environment(\.openURL, context.openURL)
                .environment(
                    \.mentions, MentionContext(me: context.matrix?.user?.id, members: context.matrix?.members ?? []))
        }
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .spacer, .end: Color.clear
        case .loading(let loading):
            TimelineLoadingRow(loading: loading, offline: context.matrix?.connectionState == .offline)
        case .welcome(let welcome): TimelineWelcomeRow(welcome: welcome)
        case .day(let label): TimelineDayDivider(label: label)
        case .unread: TimelineUnreadDivider()
        case .message(let row):
            if let matrix = context.matrix {
                let message = row.message
                let target = context.actionTarget(for: message)
                MessageRow(
                    message: message, grouped: row.grouped, isThread: context.isThread,
                    own: message.senderID == matrix.user?.id, highlighted: row.highlighted, isSaved: row.saved,
                    isPinned: row.pinned, sendFailure: row.sendFailure, sendBusy: row.sendBusy, hovered: hovered,
                    timeLabel: row.time,
                    avatar: AvatarView(
                        name: message.senderName, size: metrics.avatar, matrix: matrix,
                        source: message.avatarURL),
                    replyPreview: message.replyPreview.map {
                        ReplyPreviewView(
                            matrix: matrix, message: message, preview: $0, origin: target, onOpen: context.onShowReply)
                    },
                    attachment: message.attachment.map {
                        AttachmentView(
                            matrix: matrix, message: message, attachment: $0, collapsed: row.mediaCollapsed,
                            actions: context.attachmentActions(for: message, target: target))
                    },
                    actions: context.actions(for: entry.id, row, target: target))
            }
        }
    }
}

private struct TimelineLoadingRow: View {
    @Environment(\.metrics) private var m
    let loading: Bool
    let offline: Bool
    var body: some View {
        DelayedProgress(active: loading, offline: offline, interval: .historyLoading).frame(maxWidth: .infinity).frame(
            height: m.sp40)
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
                    ? "bubble.left.and.bubble.right.fill" : welcome.isEncrypted ? "lock.fill" : "number"
            )
            .font(m.font(.display, .bold)).frame(width: m(Self.tile), height: m(Self.tile))
            .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusPanel))
            Text(welcome.isDirect || welcome.isEncrypted ? welcome.name : "# \(welcome.name)")
                .font(m.font(.display, .bold)).foregroundStyle(colors.textPrimary)
            Text(
                !welcome.topic.isEmpty
                    ? welcome.topic
                    : welcome.isDirect
                        ? "This is the beginning of your conversation with \(welcome.name)."
                        : "This is the beginning of the \(welcome.name) channel."
            ).font(m.font(.body)).foregroundStyle(colors.textSecondary).lineSpacing(m.size(.body) / 5)
            if welcome.isEncrypted {
                Image(systemName: "lock.shield").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                    .help("End-to-end encrypted").accessibilityLabel("End-to-end encrypted")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(m.sp24)
    }
}

private struct TimelineDayDivider: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    let label: String
    var body: some View {
        let colors = appearance.colors
        HStack(spacing: 0) {
            Rectangle().fill(colors.border).frame(height: 1)
            Text(label).font(m.font(.meta, .semibold)).padding(.horizontal, m.sp12).padding(.vertical, m.sp4)
                .background(colors.canvas, in: Capsule()).overlay(Capsule().stroke(colors.border))
            Rectangle().fill(colors.border).frame(height: 1)
        }.padding(.vertical, m.sp16)
    }
}

private struct TimelineUnreadDivider: View {
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let accent = appearance.colors.accent
        HStack(spacing: m.sp12) {
            Rectangle().fill(accent).frame(height: 1)
            Text("New messages").font(m.font(.caption, .semibold)).foregroundStyle(accent)
            Rectangle().fill(accent).frame(height: 1)
        }.padding(.horizontal, m.sp20).padding(.vertical, m.sp12).accessibilityLabel("New messages begin here")
    }
}
