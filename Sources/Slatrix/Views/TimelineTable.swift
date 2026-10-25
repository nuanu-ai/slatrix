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
    var previews: AttachmentPreviewController?
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

    static func dismantleNSView(_ view: TimelineScrollView, coordinator: TimelineTableCoordinator) {
        coordinator.closePicker()
        coordinator.remember()
        coordinator.stopLoading()
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

    private var configuration: TimelineTable?
    private var rows: [TimelineEntry] = []
    private var applied: [TimelineEntry]?
    private var index: [String: Int] = [:]
    private let scrollView = TimelineScrollView()
    private let table = TimelineTableView()
    private var sizer: NSHostingController<TimelineRow>?
    private var width: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    private var settings: Settings?
    private var spacerHeight: CGFloat = 0
    /// Rows whose height in the table is an estimate. Only rows within a screen of the viewport are measured, so
    /// opening a room or loading a page lays out a screenful, not the whole history.
    private var estimated = Set<String>()
    private var opened = false
    private var pendingFocus: String?
    private var hoveredID: String?
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
            for row in rows.indices where rows[row] != next[row] || settingsChanged {
                rows[row] = next[row]
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

    private func show(_ entry: TimelineEntry, in cell: TimelineCell) {
        let commands: ((Bool) -> [MessageMenuCommand])? =
            if case .message(let row) = entry.kind, let context = configuration?.context {
                { [id = entry.id] accessibility in
                    let target = context.actionTarget(for: row.message)
                    return accessibility
                        ? context.accessibilityCommands(for: id, row, target: target)
                        : context.actions(for: id, row, target: target).menu()
                }
            } else { nil }
        cell.show(view(for: entry, measuring: false), commands: commands)
    }

    private func view(for entry: TimelineEntry, measuring: Bool) -> TimelineRow {
        TimelineRow(
            entry: entry, hovered: !measuring && entry.id == hoveredID, measuring: measuring,
            context: configuration?.context ?? TimelineRowContext())
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
        if let height = measured(entry) {
            estimated.remove(entry.id)
            return height
        }
        estimated.insert(entry.id)
        return estimate(entry)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? TimelineCell
            ?? TimelineCell(identifier: Self.cellID)
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

    private func measured(_ entry: TimelineEntry) -> CGFloat? { key(entry).flatMap { Self.heights[$0] } }

    private func measure(_ entry: TimelineEntry) {
        guard let key = key(entry), Self.heights[key] == nil else { return }
        let row = view(for: entry, measuring: true)
        let sizer = sizer ?? NSHostingController(rootView: row)
        self.sizer = sizer
        sizer.rootView = row
        // shortcut: the cache is dropped whole when it grows past a few busy rooms at a few widths; an LRU if that
        // shows up in profiles.
        if Self.heights.count > 50_000 { Self.heights.removeAll() }
        // Whole points keep every row, and the text in it, on the pixel grid.
        Self.heights[key] = max(
            1, ceil(sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    /// Rough, cheap and never shown: a row is measured before it comes within a screen of the viewport.
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
            let lines = row.message.body.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
                $0 + max(1, ceil(CGFloat($1.count) / perLine))
            }
            var height = (row.grouped ? m.sp8 : m(40)) + lines * line
            if !row.message.reactions.isEmpty { height += m(30) }
            if row.message.attachment != nil { height += m(300) }
            if row.message.replyPreview != nil { height += m(48) }
            if row.message.replyCount > 0 { height += m(28) }
            return height
        }
    }

    /// Measures the estimated rows in and around the viewport, keeping `position` (or the first measured row on
    /// screen) where it is.
    private func settle(keeping position: Policy.Position?) {
        for _ in 0..<4 {
            let around = table.rows(in: scrollView.contentView.bounds.insetBy(dx: 0, dy: -viewportHeight))
            let pending = IndexSet((Range(around) ?? 0..<0).filter { estimated.contains(rows[$0].id) })
            guard !pending.isEmpty else { return }
            let anchor = position ?? self.position(excluding: pending)
            Performance.measure(.rowsMeasure, ["rows": pending.count]) { for row in pending { measure(rows[row]) } }
            noteHeights(pending)
            updateSpacer()
            scroll(to: anchor)
        }
    }

    /// A row's own state (a revealed spoiler, an error under an attachment) changed its height.
    private func reported(_ reported: CGFloat, for id: String) {
        let height = ceil(reported)
        guard let row = index[id], let key = key(rows[row]), let measured = Self.heights[key],
            abs(height - measured) > 0.5
        else { return }
        Self.heights[key] = height
        // Not inside the SwiftUI update that reported it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.index[id] == row else { return }
            self.preservingPosition { self.noteHeights([row]) }
        }
    }

    /// Every row is re-estimated at a new width; the settle that follows measures the ones near the viewport.
    private func remeasure() {
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

final class TimelineCell: NSView {
    private let host = TimelineHost(rootView: nil)

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.sizingOptions = []
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { nil }

    /// `commands` gives a message's menu, or with `true` its VoiceOver actions, when one is asked for.
    func show(_ row: TimelineRow, commands: ((Bool) -> [MessageMenuCommand])?) {
        host.rootView = row
        host.commands = commands
    }
}

/// A row's hosting view, which also answers for the row's context menu and VoiceOver actions, as SwiftUI's own
/// modifiers would from here, without every row at rest carrying them.
final class TimelineHost: NSHostingView<TimelineRow?> {
    var commands: ((Bool) -> [MessageMenuCommand])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let commands else { return super.menu(for: event) }
        let menu = NativeMessageMenu.make(commands: commands(false))
        // As SwiftUI's context menu drew them: a destructive item is not red here.
        for item in menu.items { item.attributedTitle = nil }
        return menu
    }

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

/// A timeline row's SwiftUI content. Measured once offscreen for its height, then shown in a cell of that height.
struct TimelineRow: View {
    let entry: TimelineEntry
    let hovered: Bool
    let measuring: Bool
    /// Zoom, held here rather than read from the shared context, so a change to it redraws the row.
    let metrics: Metrics
    let context: TimelineRowContext

    init(entry: TimelineEntry, hovered: Bool, measuring: Bool, context: TimelineRowContext) {
        self.entry = entry
        self.hovered = hovered
        self.measuring = measuring
        metrics = context.metrics
        self.context = context
    }

    var body: some View {
        if let appearance = context.appearance, let previews = context.previews {
            content.frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: measuring ? nil : .infinity, alignment: .top)
                .background {
                    if !measuring {
                        GeometryReader { geometry in
                            Color.clear.onChange(of: geometry.size.height) { _, height in
                                context.onHeight(entry.id, height)
                            }
                        }
                    }
                }
                // A reused cell shows another row: its row state must not carry over.
                .id(measuring ? "" : entry.id)
                .environment(\.metrics, metrics).environmentObject(appearance).environmentObject(previews)
                .environment(\.openURL, context.openURL)
        }
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .spacer, .end: Color.clear
        case .loading(let loading): TimelineLoadingRow(loading: loading)
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
                        AttachmentView(matrix: matrix, message: message, attachment: $0)
                    },
                    actions: context.actions(for: entry.id, row, target: target))
            }
        }
    }
}

private struct TimelineLoadingRow: View {
    @Environment(\.metrics) private var m
    let loading: Bool
    var body: some View {
        DelayedProgress(active: loading, interval: .historyLoading).frame(maxWidth: .infinity).frame(height: m.sp40)
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
                .font(m.font(.display, .bold)).foregroundStyle(colors.primaryText)
            Text(
                !welcome.topic.isEmpty
                    ? welcome.topic
                    : welcome.isDirect
                        ? "This is the beginning of your conversation with \(welcome.name)."
                        : "This is the beginning of the \(welcome.name) channel."
            ).font(m.font(.body)).foregroundStyle(colors.muted).lineSpacing(m.size(.body) / 5)
            if welcome.isEncrypted {
                Image(systemName: "lock.shield").font(m.font(.caption)).foregroundStyle(colors.muted)
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
