import AppKit
import SwiftUI

struct TimelineView: View {
    @Environment(\.metrics) private var m
    @Environment(\.openURL) private var openURL
    @Environment(\.timelineBarInsets) private var barInsets
    let matrix: MatrixService
    @EnvironmentObject var appearance: AppearanceStore
    @Environment(Popovers.self) private var popovers: Popovers?
    @Environment(Toasts.self) private var toasts: Toasts?
    let room: ChatRoom
    var thread = false
    var threadRootID: String? = nil
    var savedIDs: Set<String>
    var onThread: (ChatMessage) -> Void
    /// Opens a thread from its replies link, which shows a count.
    var onOpenReplies: (ChatMessage) -> Void = { _ in }
    var onReply: (ChatMessage) -> Void
    var onEdit: (MessageActionTarget) -> Void
    var onSave: (ChatMessage) -> Void
    var onShowReply: ((String) -> Void)? = nil
    var onOpenProfile: ((String, ChatUser?) -> Void)? = nil
    var canPinMessages = false
    var onTogglePin: ((ChatMessage) -> Void)? = nil
    /// What the pane shows, for the read checks; nothing once it leaves.
    var onReport: ((PaneReport) -> Void)? = nil
    /// What the read checks take the report for; when it changes, the pane reports again.
    var readKey: AnyHashable? = nil
    var onJumpToLatest: (() -> Void)? = nil
    /// The fully-read event of a conversation opened at its unread line.
    var unreadAnchor: String? = nil
    /// Whether an edit to a message in this conversation is open.
    var editing = false
    var onForward: ((MessageActionTarget) -> Void)? = nil
    var onEditCaption: ((MessageActionTarget) -> Void)? = nil
    var onOpenMedia: ((ChatMessage) -> Void)? = nil
    /// The window's one inline video player.
    var inlineVideo: InlineVideo? = nil
    /// Messages scrolled up under the header, which then gets its line. Held by the pane in an isolated observable
    /// state so toggling the hairline never redraws the window or timeline shell.
    var scrollEdge: ScrollEdgeState? = nil
    /// The header's and the composer's heights, which float over the timeline's ends.
    var insets = EdgeInsets()
    @State private var loadingHistory = false
    /// In a thread, the loading row sits between the root and replies; show it only after the loading delay so short
    /// threads never open with a 40 pt blank gap that snaps replies up when history ends.
    @State private var showThreadOlder = false
    @State private var deleting: MessageActionTarget?
    @State private var cancelling: ChatMessage?
    /// Retries and cancellations started here and not yet finished, by message ID.
    @State private var sendActions = Set<String>()
    @State private var linkCopy: LinkCopy?
    @State private var jumpVisible = false
    @State private var atBottom = false
    /// The message jumped to, while its highlight lasts from the landing.
    @State private var highlighted: String?
    @State private var landing: UUID?
    @State private var layout = TimelineLayoutCache()
    @State private var rowContext = TimelineRowContext()
    @State private var scroller = TimelineScroller()
    private var colors: AppColors { appearance.colors }
    private var messages: [ChatMessage] { thread ? matrix.threadMessages : matrix.messages }
    /// A conversation loaded around an older message does not follow new messages.
    private var live: Bool { thread || matrix.focusedEventID == nil }
    /// A thread's page loads for whoever asked for it: its loading row, Retry, or a jump reading back.
    private var loadingOlder: Bool { thread ? matrix.isLoadingThreadPage : loadingHistory }
    private var hasOlder: Bool {
        !matrix.isPreview && (thread ? matrix.loadsMoreThreadHistory : matrix.loadsMoreHistory)
    }
    private var memoryKey: TimelineMemory.Key {
        TimelineMemory.Key(
            sessionID: matrix.notificationSessionID, roomID: room.id, threadRootID: thread ? threadRootID : nil)
    }
    /// True while a cold thread open is still awaiting its timeline or first page with only its root present.
    private var awaitingThreadReplies: Bool {
        guard thread, let rootID = threadRootID, matrix.threadOpening?.rootID == rootID else { return false }
        return matrix.isOpeningThread
    }
    /// Holds back the synthetic `[root]` row while replies or a remembered/jumped position are still arriving so a
    /// tall thread never flashes its root and teleports off-screen.
    private var holdsThreadEntries: Bool {
        guard awaitingThreadReplies else { return false }
        return matrix.isBuildingThreadTimeline || matrix.threadExpectsReplies
            || TimelineMemory.positions[memoryKey] != nil || jumpTarget != nil
    }
    /// The intro tops a conversation loaded back to its start, or one with nothing else to show.
    var reachedStart: Bool { !thread && (matrix.isPreview || !matrix.hasMoreHistory) }
    /// The message jumped to, when this pane shows it.
    private var jumpTarget: String? {
        thread ? threadRootID.flatMap { matrix.jump?.eventID(inThread: $0) } : matrix.jump?.eventID(inThread: nil)
    }
    private var hasNewer: Bool { !thread && matrix.focusedEventID != nil && matrix.hasMoreForwardHistory }
    private var turnsLive: Bool {
        TimelineScrollPolicy.turnsLive(atBottom: atBottom, live: live, hasNewer: hasNewer, editing: editing)
    }

    var body: some View {
        TimelineTable(
            entries: entries, context: updatedContext, live: live, bottomAligned: !thread,
            canOpen: !awaitingThreadReplies,
            focusedEventID: thread ? jumpTarget : jumpTarget ?? matrix.focusedEventID,
            jumpID: jumpTarget == nil ? nil : matrix.jump?.id,
            sends: matrix.sends[Conversation(roomID: room.id, threadRootID: thread ? threadRootID : nil)] ?? 0,
            startsAtUnread: unreadAnchor != nil,
            memoryKey: memoryKey,
            timelineID: thread ? matrix.threadSelection : matrix.shownTimelineID,
            pagesLanded: thread ? matrix.threadPagesLanded : 0,
            // A thread whose page failed asks again when the reader retries or the connection returns.
            canLoadOlder: hasOlder && !loadingOlder && !(thread && matrix.threadPageError != nil),
            canLoadNewer: hasNewer && !loadingHistory && !matrix.isLoadingForwardHistory,
            scroller: scroller, onLoadOlder: { loadHistory() }, onLoadNewer: { loadHistory(forward: true) },
            onLand: { jump in
                guard let target = jumpTarget, matrix.jump?.id == jump else { return }
                matrix.landed(jump, inThread: thread ? threadRootID : nil)
                highlighted = target
                landing = jump
            },
            onScroll: { atBottom, showsJump, scrolled, report in
                self.atBottom = atBottom
                jumpVisible = showsJump
                if let scrolled, let scrollEdge, scrolled != scrollEdge.contentAbove {
                    scrollEdge.contentAbove = scrolled
                }
                onReport?(report)
            }, readKey: readKey, insets: insets, barInsets: barInsets
        )
        .overlay(alignment: .bottom) {
            // A conversation still reading its first rows, after the loading delay, holds their place on the composer.
            if !thread && messages.isEmpty && matrix.timelineLoading {
                SkeletonRows(count: 8).fixedSize(horizontal: false, vertical: true)
                    .conversationRow(m, isThread: false).padding(.bottom, insets.bottom)
            }
        }
        .overlay(alignment: .top) {
            if thread && holdsThreadEntries {
                SkeletonRows(count: 6).fixedSize(horizontal: false, vertical: true)
                    .conversationRow(m, isThread: true).padding(.top, insets.top)
            }
        }
        .overlay(alignment: .top) {
            if let scrollEdge { ScrollEdgeHairline(state: scrollEdge, top: insets.top) }
        }
        .overlay(alignment: .bottomTrailing) {
            if jumpVisible && !messages.isEmpty {
                Button {
                    if matrix.focusedEventID != nil {
                        if let onJumpToLatest {
                            onJumpToLatest()
                        } else {
                            Task { await matrix.selectRoom(room.id) }
                        }
                    } else {
                        scroller.scrollToBottom()
                    }
                } label: {
                    Label("Jump to recent", systemImage: "arrow.down").font(m.font(.subheadline, .semibold))
                        .padding(.horizontal, m.sp16).padding(.vertical, m.sp8)
                        .background(colors.raised, in: Capsule()).overlay(Capsule().stroke(colors.border))
                        .elevation(.e2, cornerRadius: m.sp20)
                }.buttonStyle(.row).padding(m.sp20).padding(.bottom, insets.bottom).transition(.opacity)
            }
        }
        .animation(Motion.overlay, value: jumpVisible)
        .task(id: turnsLive) {
            guard turnsLive else { return }
            await matrix.goLive { scroller.screenAnchorEventID }
        }
        .task(id: thread && hasOlder && loadingOlder && matrix.connectionState != .offline) {
            showThreadOlder = false
            guard thread, hasOlder, loadingOlder, matrix.connectionState != .offline else { return }
            try? await Task.sleep(for: LoadingPresentation.indicatorDelay)
            if !Task.isCancelled { showThreadOlder = true }
        }
        .loadingInterval(.historyLoading, while: thread && hasOlder && loadingOlder)
        .task(id: landing) {
            // Held long enough to find, then faded by the row.
            guard landing != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            highlighted = nil
        }
        // A frame theme's doodles, which stay put while the messages scroll over them.
        .background { if colors.theme.framed { WallpaperBackground(ink: colors.wallpaperDoodle) } }
        .background(colors.canvas)
        // Every message redraws the timeline; it fills what it is given, so that never lays out the window.
        .layoutIsolated()
        .onDisappear {
            deleting = nil
            cancelling = nil
            linkCopy = nil
            onReport?(PaneReport())
            inlineVideo?.stop(from: rowContext)
        }
        .onChange(of: matrix.messageActionContext) { _, _ in
            if let deleting, !matrix.isCurrentMessageAction(deleting) { self.deleting = nil }
            if let linkCopy, !matrix.isCurrentMessagePermalink(linkCopy.target) { self.linkCopy = nil }
        }
        .modal(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            ConfirmModal(
                title: "Delete message?", message: "This can’t be undone.", action: "Delete",
                onConfirm: {
                    let target = deleting
                    deleting = nil
                    if let target {
                        Task {
                            do { try await matrix.deleteMessage(target) } catch is CancellationError {} catch {
                                if matrix.isCurrentMessageAction(target) {
                                    matrix.errorMessage = MatrixService.safeError(error)
                                }
                            }
                        }
                    }
                }, onCancel: { deleting = nil })
        }
        .modal(isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })) {
            let failed =
                cancelling.flatMap { matrix.sendFailure(for: $0)?.shown(offline: matrix.connectionState == .offline) }
                != nil
            ConfirmModal(
                title: failed ? "Delete message?" : "Cancel sending this message?",
                message: failed ? "This can’t be undone." : "It may already have been delivered.",
                action: failed ? "Delete" : "Cancel sending", cancel: failed ? "Cancel" : "Keep sending",
                onConfirm: {
                    if let message = cancelling { cancelSend(message) }
                    cancelling = nil
                }, onCancel: { cancelling = nil })
        }
        .modal(isPresented: Binding(get: { linkCopy?.error != nil }, set: { if !$0 { linkCopy?.error = nil } })) {
            ConfirmModal(
                title: "Couldn’t copy message link", message: linkCopy?.error ?? "Try again in a moment.",
                action: "Retry", kind: .primary,
                onConfirm: { [target = linkCopy?.target] in if let target { copyLink(target) } },
                onCancel: { linkCopy = nil })
        }
    }

    /// One row per layout row, plus what the row shows from the session; the layout itself changes only with the
    /// messages.
    private var entries: [TimelineEntry] {
        if holdsThreadEntries { return [] }
        let rows = layout.rows(
            messages, firstUnreadEventID: thread ? nil : matrix.firstUnreadEventID,
            unreadAnchor: unreadAnchor, me: matrix.user?.id,
            groups: appearance.density != .compact, threadRootEventID: thread ? threadRootID : nil,
            repliesLine: thread ? matrix.threadRepliesLine : nil)
        let offline = matrix.connectionState == .offline
        let failures = matrix.sendFailures.compactMapValues { $0.shown(offline: offline) }
        let showOlder = thread ? (hasOlder && showThreadOlder) : hasOlder
        let inputs = TimelineLayoutCache.EntryInputs(
            rows: rows, hasOlder: showOlder, reachedStart: reachedStart, reading: !thread && matrix.timelineLoading,
            hasNewer: hasNewer,
            loadingHistory: loadingOlder, welcome: welcome,
            pinned: room.pinnedEventIDs,
            savedIDs: savedIDs, highlighted: highlighted,
            sendFailures: failures, pendingSendActions: matrix.pendingSendActions, sendActions: sendActions,
            collapsedMedia: matrix.collapsedMedia)
        return layout.entries(for: inputs) {
            buildEntries(rows, showOlder: showOlder, failures: failures)
        }
    }

    private var welcome: TimelineWelcome {
        TimelineWelcome(
            name: room.name, topic: room.topic, isDirect: room.isDirect, isPrivate: room.isPrivate,
            isEncrypted: room.isEncrypted)
    }

    private func buildEntries(
        _ rows: [TimelineLayout.Row], showOlder: Bool,
        failures: [SendQueueMessageKey: MessageSendFailure]
    ) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        entries.reserveCapacity(rows.count + 2)
        // A thread's older replies load under its root and the line counting them.
        var olderAt = 0
        if !showOlder && !thread && (reachedStart || rows.isEmpty && !matrix.timelineLoading) {
            entries.append(
                TimelineEntry(
                    id: "welcome",
                    kind: .welcome(welcome)))
        }
        // Read once: each read of a published property costs more than the lookups below.
        let pinned = Set(room.pinnedEventIDs)
        let pending = matrix.pendingSendActions
        let collapsed = matrix.collapsedMedia
        let seen = matrix.user.map { SeenPolicy.headers(rows, me: $0.id) } ?? [:]
        for row in rows {
            switch row.kind {
            case .day(let label): entries.append(TimelineEntry(id: row.id, kind: .day(label)))
            case .unread: entries.append(TimelineEntry(id: row.id, kind: .unread))
            case .replies(let count):
                entries.append(TimelineEntry(id: row.id, kind: .replies(count)))
                olderAt = entries.count
            case .message(let message, let grouped, let time):
                if message.eventID == threadRootID { olderAt = entries.count + 1 }
                let key = SendQueueMessageKey(roomID: message.roomID, messageID: message.eventID)
                entries.append(
                    TimelineEntry(
                        id: row.id,
                        kind: .message(
                            TimelineMessageEntry(
                                message: message, grouped: grouped, time: time,
                                saved: !savedIDs.isEmpty
                                    && savedIDs.contains(
                                        SavedMessageReference(roomID: message.roomID, eventID: message.eventID).id),
                                pinned: pinned.contains(message.eventID),
                                highlighted: highlighted == message.eventID,
                                sendFailure: failures.isEmpty ? nil : failures[key],
                                sendBusy: !pending.isEmpty && pending.contains(key) || sendActions.contains(message.id),
                                seenBy: seen[row.id],
                                mediaCollapsed: !collapsed.isEmpty && collapsed.contains(message.eventID)))))
            }
        }
        if showOlder {
            entries.insert(TimelineEntry(id: "older", kind: .loading(loadingOlder, immediate: thread)), at: olderAt)
        }
        if hasNewer { entries.append(TimelineEntry(id: "newer", kind: .loading(loadingHistory))) }
        return entries
    }

    private var updatedContext: TimelineRowContext {
        let context = rowContext
        context.matrix = matrix
        context.isThread = thread
        context.threadRootID = threadRootID
        context.canPin = canPinMessages
        context.canAct = !matrix.isPreview && room.membership == "join" && matrix.user != nil && matrix.isAuthenticated
        context.metrics = m
        context.appearance = appearance
        context.openURL = openURL
        context.onThread = onThread
        context.onOpenReplies = onOpenReplies
        context.onReply = onReply
        context.onEdit = onEdit
        context.onSave = onSave
        context.onDelete = { deleting = $0 }
        context.onReact = { react($1, target: $0) }
        context.onRetrySend = { retrySend($0) }
        context.onCancelSend = { cancelling = $0 }
        context.onCopyLink = { copyLink($0) }
        context.isCopyingLink = { [linkCopy] in linkCopy?.attempt != nil && linkCopy?.target.eventID == $0 }
        context.onShowReply = onShowReply
        context.onOpenProfile = onOpenProfile
        context.onTogglePin = onTogglePin
        context.onForward = onForward
        context.onEditCaption = onEditCaption
        context.onOpenMedia = { onOpenMedia?($0) }
        context.inlineVideo = inlineVideo
        context.onPickEmoji = { [popovers] in popovers?.show(.emoji($0)) }
        return context
    }

    /// A link being copied, or the error that copying it ended with. Only the latest request writes the pasteboard.
    private struct LinkCopy {
        var target: MessagePermalinkTarget
        var attempt: UUID?
        var error: String?
    }

    private func copyLink(_ target: MessagePermalinkTarget) {
        guard linkCopy?.attempt == nil || linkCopy?.target.eventID != target.eventID,
            matrix.isCurrentMessagePermalink(target)
        else { return }
        let attempt = UUID()
        linkCopy = LinkCopy(target: target, attempt: attempt)
        Task {
            defer { if linkCopy?.attempt == attempt { linkCopy?.attempt = nil } }
            do {
                let link = try await matrix.messagePermalink(for: target)
                guard !Task.isCancelled, linkCopy?.attempt == attempt, matrix.isCurrentMessagePermalink(target)
                else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                linkCopy = nil
                toasts?.show("Link copied")
            } catch is CancellationError {} catch {
                guard linkCopy?.attempt == attempt, matrix.isCurrentMessagePermalink(target) else { return }
                linkCopy?.error = MatrixService.safeError(error)
            }
        }
    }

    private func react(_ key: String, target: MessageActionTarget) {
        Task {
            do { try await matrix.toggleReaction(target, key: key) } catch is CancellationError {} catch {
                if matrix.isCurrentMessageAction(target) { matrix.errorMessage = MatrixService.safeError(error) }
            }
        }
    }

    private func retrySend(_ message: ChatMessage) {
        guard sendActions.insert(message.id).inserted else { return }
        let account = matrix.notificationSessionID
        Task {
            defer { sendActions.remove(message.id) }
            guard matrix.notificationSessionID == account else { return }
            do { try await matrix.retryMessage(message) } catch {
                if matrix.notificationSessionID == account, matrix.selectedRoomID == message.roomID {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }

    private func cancelSend(_ message: ChatMessage) {
        guard sendActions.insert(message.id).inserted else { return }
        let account = matrix.notificationSessionID
        Task {
            defer { sendActions.remove(message.id) }
            guard matrix.notificationSessionID == account else { return }
            do {
                let cancelled = try await matrix.cancelMessage(message)
                if !cancelled, matrix.notificationSessionID == account, matrix.selectedRoomID == message.roomID {
                    matrix.errorMessage = "Too late to cancel; the message may have sent."
                }
            } catch {
                if matrix.notificationSessionID == account, matrix.selectedRoomID == message.roomID {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }

    private func loadHistory(forward: Bool = false) {
        guard !loadingHistory else { return }
        loadingHistory = true
        let session = matrix.notificationSessionID
        let selection = matrix.timelineSelectionID
        Task {
            defer { loadingHistory = false }
            guard matrix.selectedRoomID == room.id, matrix.notificationSessionID == session,
                matrix.timelineSelectionID == selection
            else { return }
            do {
                if thread {
                    guard let threadRootID else { throw MatrixServiceError.noRoom }
                    _ = try await matrix.loadMoreThread(rootID: threadRootID)
                } else if forward {
                    _ = try await matrix.loadMoreForward()
                } else {
                    _ = try await matrix.loadMore()
                }
            } catch is CancellationError {} catch {
                // A thread says so in its own banner.
                if !thread, matrix.notificationSessionID == session, matrix.timelineSelectionID == selection {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }
}

/// Lays the messages out once per change, and pins the "New messages" line to the first unread event as the
/// conversation opens, so reading does not move the line and nothing arriving while it's open adds one. An unread
/// conversation that opens before its read marker takes the line from the fully-read event it opened at.
@MainActor final class TimelineLayoutCache {
    private var input: (messages: [ChatMessage], unread: String?, groups: Bool, repliesLine: Int?)?
    private var rows: [TimelineLayout.Row] = []
    private var unreadBoundary: String?
    private var opened = false
    /// The newest event present when partial cached rows first arrived without their unread anchor; live arrivals
    /// appended after it never create an unread line.
    private var openedNewestEventID: String?
    /// Everything a timeline's entries show besides the rows; the timeline redraws for many changes that touch none.
    struct EntryInputs: Equatable {
        var rows: [TimelineLayout.Row]
        var hasOlder: Bool
        var reachedStart: Bool
        var reading: Bool
        var hasNewer: Bool
        var loadingHistory: Bool
        var welcome: TimelineWelcome
        var pinned: [String]
        var savedIDs: Set<String>
        var highlighted: String?
        var sendFailures: [SendQueueMessageKey: MessageSendFailure]
        var pendingSendActions: Set<SendQueueMessageKey>
        var sendActions: Set<String>
        var collapsedMedia: Set<String>
    }
    private var entryInputs: EntryInputs?
    private var entries: [TimelineEntry] = []

    /// The same array, and so a cheap comparison for the table, until an input changes.
    func entries(for inputs: EntryInputs, build: () -> [TimelineEntry]) -> [TimelineEntry] {
        if inputs != entryInputs {
            entries = build()
            entryInputs = inputs
        }
        return entries
    }

    /// A cache serves one timeline, so `threadRootEventID` never changes under it.
    func rows(
        _ messages: [ChatMessage], firstUnreadEventID: String?, unreadAnchor: String? = nil, me: String? = nil,
        groups: Bool, threadRootEventID: String? = nil, repliesLine: Int? = nil
    ) -> [TimelineLayout.Row] {
        if !opened, !messages.isEmpty {
            if openedNewestEventID == nil { openedNewestEventID = messages.last?.eventID }
            let ceiling =
                openedNewestEventID.flatMap { id in messages.lastIndex { $0.eventID == id } }
                ?? (messages.count - 1)
            if let firstUnreadEventID,
                let unreadIndex = messages.firstIndex(where: { $0.eventID == firstUnreadEventID }),
                unreadIndex <= ceiling
            {
                opened = true
                unreadBoundary = firstUnreadEventID
            } else if let unreadAnchor {
                if let anchor = messages.firstIndex(where: { $0.eventID == unreadAnchor }) {
                    opened = true
                    // The read marker can land after the messages; it would go before the next one someone else sent.
                    let afterAnchor = anchor + 1
                    if afterAnchor <= ceiling {
                        unreadBoundary = messages[afterAnchor...ceiling].first { $0.senderID != me }?.eventID
                    }
                }
            } else {
                opened = true
            }
        }
        if let input, input.groups == groups, input.unread == unreadBoundary, input.repliesLine == repliesLine,
            input.messages == messages
        {
            return rows
        }
        rows = TimelineLayout.rows(
            messages, unreadBoundaryEventID: unreadBoundary, groups: groups, threadRootEventID: threadRootEventID,
            repliesLine: repliesLine, now: Date(), calendar: .current, locale: .current)
        input = (messages, unreadBoundary, groups, repliesLine)
        return rows
    }
}

/// What a message row does when someone acts on it, bound to that message by the timeline.
struct MessageRowActions {
    var openProfile: (() -> Void)?
    var thread: () -> Void = {}
    /// Opens the thread from its replies link.
    var openReplies: () -> Void = {}
    /// Opens the thread's timeline ahead of a click on its replies.
    var prepareThread: () -> Void = {}
    var reply: () -> Void = {}
    var save: () -> Void = {}
    /// Nil while the message cannot take a reaction.
    var react: ((String) -> Void)?
    var openReactions: (() -> Void)?
    /// Nil when the message can't be forwarded.
    var forward: (() -> Void)?
    var retrySend: () -> Void = {}
    var cancelSend: () -> Void = {}
    /// Built when a menu opens (a right-click, the toolbar's ellipsis, the text's own menu), never at rest.
    var menu: () -> [MessageMenuCommand] = { [] }
}

/// A message as the timeline shows it at rest. Menus, the reaction picker and confirmations live with the timeline
/// and are made when someone asks for them.
struct MessageRow: View {
    @EnvironmentObject var appearance: AppearanceStore
    let message: ChatMessage
    var grouped = false
    var isThread = false
    var own = false
    var highlighted = false
    var isSaved = false
    var isPinned = false
    var sendFailure: MessageSendFailure? = nil
    var sendBusy = false
    /// The timeline tracks the pointer for all rows, so hover never resets when a row's values change.
    var hovered = false
    /// Precomputed by the timeline's layout; formatted here only for rows shown elsewhere.
    var timeLabel: String? = nil
    /// Ticks by the time: whether someone has read it, and who, for the tooltip.
    var seen: (read: Bool, tooltip: String?)? = nil
    var avatar: AvatarView? = nil
    /// The thread's last replier, in the replies bar.
    var replierAvatar: AvatarView? = nil
    var replyPreview: ReplyPreviewView? = nil
    var attachment: AttachmentView? = nil
    var actions = MessageRowActions()
    /// Where each reaction sits while the row is hovered, for the timeline's tooltip naming who reacted.
    var reactionFrame: ((String, CGRect) -> Void)? = nil
    @Environment(\.metrics) private var m
    @Environment(\.mentions) private var mentions
    private var colors: AppColors { appearance.colors }
    private var pendingSend: Bool { own && message.sendState != "sent" }
    private var sending: Bool { pendingSend && sendFailure == nil }
    private var compact: Bool { appearance.density == .compact }
    private var time: String { timeLabel ?? message.timestamp.formatted(.dateTime.hour().minute()) }
    private var gutterTime: String {
        TimelineLayout.gutterTime(message.timestamp, calendar: .autoupdatingCurrent, locale: .autoupdatingCurrent)
    }
    var body: some View {
        layout
            // Inset and rounded, as Mail marks the row under the pointer.
            .background {
                RoundedRectangle(cornerRadius: m.radius).fill(hovered ? colors.hover : .clear)
                    .padding(.horizontal, isThread ? m.sp8 : m.sp12)
            }
            .conversationRow(m, isThread: isThread)
            .background {
                // A cell shows another message after a scroll; that one's highlight starts afresh, never fading in.
                colors.highlight.opacity(highlighted ? 1 : 0)
                    .animation(highlighted ? nil : Motion.highlight, value: highlighted).id(message.id)
            }
            .contentShape(Rectangle())
    }
    private var layout: some View {
        let gutter = m(ConversationGrid.gap(thread: isThread))
        return VStack(alignment: .leading, spacing: m.sp2) {
            // Above the avatar and the name, so both start on the name's line as in every other row; the pin stands in
            // the avatar's column, as in Slack.
            if isPinned {
                HStack(spacing: compact ? m.sp4 : gutter) {
                    Image(systemName: "pin.fill").frame(width: compact ? nil : m.avatar, alignment: .trailing)
                    Text("Pinned")
                }.font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
            }
            content(gutter: gutter)
        }.padding(.horizontal, m.conversationInset(thread: isThread))
            // 12 above a sender and 2 around a message under them, counted from 20 pt lines: a one-line row has none of
            // that leading of its own, so it comes on top of them. Two grouped rows share both their 2s, so a sender's
            // first gap is the tightest.
            .padding(.top, Self.topInset(m, grouped: grouped, compact: compact))
            .padding(.bottom, compact ? m.sp4 : grouped ? m.sp4 : m.sp2)
    }
    /// The space above a row's first line, which the hover toolbar may hang into.
    static func topInset(_ m: Metrics, grouped: Bool, compact: Bool) -> CGFloat {
        compact ? (grouped ? 0 : m.sp2) : grouped ? m(3) : m.sp12
    }
    private func content(gutter: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gutter) {
            if !compact {
                if grouped || !appearance.showAvatars {
                    // One line: a wrap would grow the row on hover.
                    Text(hovered ? gutterTime : "").font(m.font(.subheadline)).monospacedDigit().lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(colors.textSecondary).frame(width: m.avatar, alignment: .trailing)
                        .overlay(alignment: .trailing) { if grouped && sending && !hovered { clock } }
                        .padding(.top, m.sp2)
                } else {
                    Button {
                        actions.openProfile?()
                    } label: {
                        avatar ?? AvatarView(name: message.senderName, size: m.avatar)
                    }.buttonStyle(.row).disabled(actions.openProfile == nil).linkCursor().help(
                        "View \(message.senderName)’s profile"
                    ).padding(.top, m.sp2)
                }
            }
            VStack(alignment: .leading, spacing: m.sp2) {
                if !grouped || compact {
                    HStack(alignment: .firstTextBaseline, spacing: m(6)) {
                        if compact {
                            Text(time).font(m.font(.subheadline)).monospacedDigit()
                                .foregroundStyle(colors.textSecondary)
                        }
                        Button {
                            actions.openProfile?()
                        } label: {
                            Text(message.senderName).font(m.font(.body, .semibold))
                                .foregroundStyle(colors.textPrimary)
                        }.buttonStyle(.row).disabled(actions.openProfile == nil).linkCursor().help("View profile")
                        if !compact {
                            Text(time).font(m.font(.subheadline)).monospacedDigit()
                                .foregroundStyle(colors.textSecondary)
                        }
                        if let seen, !pendingSend {
                            ReadTicks(read: seen.read).help(seen.tooltip ?? "")
                        }
                        if isSaved {
                            Image(systemName: "bookmark.fill").font(m.font(.subheadline)).foregroundStyle(colors.accent)
                        }
                    }.overlay(alignment: .trailing) {
                        if sending { clock.padding(.leading, m.sp8).frame(width: 0, alignment: .leading) }
                    }
                }
                if message.isRedacted {
                    Text(ChatMessage.deletedBody).italic().font(m.font(.reading)).foregroundStyle(
                        colors.textSecondary
                    )
                } else {
                    // State of its own per message, so a reused cell never names another copy's thread.
                    if let replyPreview { replyPreview.id(message.id) }
                    if message.kind == "m.room.encrypted" {
                        // One quiet line per message; the header offers the recovery key once for all of them.
                        Label(message.body, systemImage: "lock").font(m.font(.body)).italic()
                            .foregroundStyle(colors.textSecondary)
                    } else if message.showsMessageBody {
                        // Slack draws a message that hasn't reached the server lighter, and nothing else.
                        NativeMessageBody(
                            body: message.body, formattedBody: message.formattedBody, edited: message.isEdited,
                            menuCommands: actions.menu
                        ).opacity(pendingSend ? 0.5 : 1)
                    }
                    if message.isEdited && (!message.showsMessageBody || message.kind == "m.room.encrypted") {
                        Text("(edited)").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                    }
                    // A reused cell shows another message: a download or preview in flight must not carry over.
                    if let attachment { attachment.padding(.top, m(6)).id(message.id) }
                    if !message.reactions.isEmpty { reactions.padding(.top, m(3)) }
                    if !isThread, let count = message.replyCount, count > 0 {
                        ThreadRepliesBar(
                            count: count, lastReply: message.lastReply, avatar: replierAvatar,
                            prepare: actions.prepareThread, action: actions.openReplies
                        ).padding(.top, m.sp4)
                    }
                    if pendingSend, let failure = sendFailure {
                        VStack(alignment: .leading, spacing: m.sp4) {
                            HStack(alignment: .firstTextBaseline, spacing: m.sp12) {
                                Label("Not delivered", systemImage: "exclamationmark.circle.fill")
                                    .foregroundStyle(colors.destructive)
                                if failure.canRetry {
                                    Button("Retry", action: actions.retrySend).buttonStyle(.textLink)
                                }
                                Button("Delete", role: .destructive, action: actions.cancelSend).buttonStyle(.textLink)
                            }.disabled(sendBusy).overlay(alignment: .trailing) {
                                if sendBusy {
                                    DelayedProgress().padding(.leading, m.sp8).frame(width: 0, alignment: .leading)
                                }
                            }
                            // A network failure needs only Retry; the others say what to do first.
                            if failure.kind != .recoverable {
                                Text(failure.message).foregroundStyle(colors.textSecondary)
                            }
                        }.font(m.font(.subheadline)).padding(.top, m.sp2)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var clock: some View { SendingClock(since: message.timestamp) }

    private var reactions: some View {
        WrappingRow(spacing: m.sp4) {
            ForEach(message.reactions, id: \.key) { reaction in
                Button {
                    actions.react?(reaction.key)
                } label: {
                    ReactionChip(mine: reaction.mine) {
                        Text(EmojiCatalog.presented(reaction.key)).font(m.font(.subheadline)).lineLimit(1)
                        Text("\(reaction.count)").font(m.font(.subheadline, .semibold)).fixedSize()
                            .foregroundStyle(reaction.mine ? colors.accent : colors.textSecondary)
                    }
                }.buttonStyle(.row).disabled(actions.react == nil)
                    .accessibilityLabel(
                        reaction.tooltip(me: mentions.me) { id in mentions.members.first { $0.id == id }?.name }
                    )
                    .background {
                        // Only the hovered row says where its reactions are, so rows at rest do no work for the tooltip.
                        if hovered, let reactionFrame {
                            Color.clear.onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named(TimelineRow.space))
                            } action: {
                                reactionFrame(reaction.key, $0)
                            }
                        }
                    }
            }
            // Shown on hover only, in space it always has, as Slack does.
            Button {
                actions.openReactions?()
            } label: {
                ReactionChip(mine: false) {
                    Image(systemName: "face.smiling").font(m.font(.body)).foregroundStyle(colors.textSecondary)
                }
            }.buttonStyle(.row).disabled(actions.openReactions == nil).help("Add reaction")
                .opacity(hovered ? 1 : 0).allowsHitTesting(hovered).accessibilityHidden(!hovered)
        }
    }
}

/// Slack's clock for a send still going after a few seconds. It always takes its space, so the row never moves for it.
private struct SendingClock: View {
    let since: Date
    @State private var shown: Bool
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    init(since: Date) {
        self.since = since
        // A message that has been sending a while shows its clock in its first frame.
        _shown = State(initialValue: Self.shows(since))
    }

    private static func shows(_ since: Date) -> Bool {
        LoadingPresentation.showsSendingClock(sendingFor: .seconds(Date().timeIntervalSince(since)))
    }

    var body: some View {
        Image(systemName: "clock").font(m.font(.subheadline)).foregroundStyle(appearance.colors.textSecondary)
            .opacity(shown ? 1 : 0).accessibilityHidden(!shown).accessibilityLabel("Sending")
            .task(id: since) {
                shown = Self.shows(since)
                guard !shown else { return }
                let left = LoadingPresentation.sendingClockDelay - .seconds(Date().timeIntervalSince(since))
                try? await Task.sleep(for: left)
                if !Task.isCancelled { shown = Self.shows(since) }
            }
    }
}

/// A reaction's pill: 24 pt, gray at rest; yours are tinted.
private struct ReactionChip<Content: View>: View {
    let mine: Bool
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let colors = appearance.colors
        // The emoji and its count on one baseline: centered frames put the count low, as an emoji's line is taller.
        HStack(alignment: .firstTextBaseline, spacing: m.sp4) { content }.padding(.horizontal, m.sp8)
            .frame(height: m.sp24)
            .background(mine ? colors.accentTint : colors.sunken, in: Capsule())
    }
}

/// Its views in lines as wide as the column, as Slack wraps reactions, so none is ever squeezed.
private struct WrappingRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        frames(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: proposal.width ?? bounds.width, subviews).frames) {
            let origin = CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY)
            view.place(at: origin, proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var size = CGSize.zero
        for view in subviews {
            // Never wider than the column: a pill with a long custom key truncates it instead.
            let ideal = view.sizeThatFits(.unspecified).width
            let fit = view.sizeThatFits(ProposedViewSize(width: min(ideal, width), height: nil))
            if origin.x > 0, origin.x + fit.width > width { origin = CGPoint(x: 0, y: size.height + spacing) }
            frames.append(CGRect(origin: origin, size: fit))
            origin.x += fit.width + spacing
            size = CGSize(width: max(size.width, origin.x - spacing), height: max(size.height, origin.y + fit.height))
        }
        return (frames, size)
    }
}

/// The replies bar: who replied last, how many replies and when. Hovering fills it and offers the thread, at the same
/// height.
private struct ThreadRepliesBar: View {
    private static let maxWidth: CGFloat = 600
    let count: Int
    let lastReply: ThreadReply?
    let avatar: AvatarView?
    let prepare: () -> Void
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radius)
        Button(action: action) {
            HStack(spacing: m.sp8) {
                if let avatar { avatar }
                Text("\(count) \(count == 1 ? "reply" : "replies")").font(m.font(.body, .semibold))
                    .foregroundStyle(colors.accent)
                if hovering {
                    Text("View thread").font(m.font(.body)).foregroundStyle(colors.textSecondary)
                    Spacer(minLength: m.sp8)
                    Image(systemName: "chevron.right").font(m.font(.subheadline, .semibold))
                        .foregroundStyle(colors.textSecondary)
                } else if let lastReply {
                    Text(ThreadReply.lastReplyText(lastReply.timestamp, now: Date())).font(m.font(.body))
                        .foregroundStyle(colors.textSecondary)
                }
            }.lineLimit(1).padding(.horizontal, m.sp4).frame(
                maxWidth: m(Self.maxWidth), minHeight: m.sp24, alignment: .leading
            )
            .background(hovering ? colors.hover : .clear, in: shape)
        }.buttonStyle(.row)
            .onHover {
                hovering = $0
                if $0 { prepare() }
            }
            .accessibilityLabel("\(count) replies, view thread")
            // The face lines up with the text above; the hover box reaches past it.
            .padding(.leading, -m.sp4)
    }
}

/// Slack's hover toolbar: three one-click reactions, then add reaction, reply in thread, forward, save and more.
/// The timeline floats one over the hovered row's top edge, so no row draws it or changes height for it.
struct MessageToolbar: View {
    static let button: CGFloat = 24
    let quick: [String]
    let isThread: Bool
    let isSaved: Bool
    /// A message still sending offers only its menu.
    let pending: Bool
    let actions: MessageRowActions
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        let colors = appearance.colors
        let shape = RoundedRectangle(cornerRadius: m.radiusLarge)
        HStack(spacing: 0) {
            if !pending {
                // Left out, not dimmed, while the message can't take a reaction: a faded emoji looks broken.
                if let react = actions.react {
                    ForEach(quick, id: \.self) { emoji in
                        Button {
                            react(emoji)
                        } label: {
                            Text(EmojiCatalog.presented(emoji)).font(m.font(.body))
                                .frame(width: m(Self.button), height: m(Self.button))
                        }.buttonStyle(.icon).help("React with \(EmojiCatalog.shortcode(for: emoji))")
                    }
                }
                if let openReactions = actions.openReactions {
                    button("face.smiling", "Find another reaction", action: openReactions)
                }
                if !isThread { button("text.bubble", "Reply in thread", action: actions.thread) }
                button(
                    isSaved ? "bookmark.fill" : "bookmark", isSaved ? "Remove from Later" : "Save for later",
                    action: actions.save)
            }
            Menu {
                NativeMessageMenuCommands(commands: actions.menu())
            } label: {
                Image(systemName: "ellipsis").font(m.font(.body))
                    .frame(width: m(Self.button), height: m(Self.button))
            }.menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).help("More actions")
                .accessibilityLabel("More actions")
        }
        .foregroundStyle(colors.textSecondary).padding(m.sp2)
        .background(colors.overlay, in: shape).elevation(.e1, cornerRadius: m.radiusLarge)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, label: label, role: .body, side: Self.button, action: action)
    }
}

/// The toolbar for the hovered row, with the account's recent emoji; it redraws when they change.
struct HoveredMessageToolbar: View {
    let entry: TimelineMessageEntry
    let context: TimelineRowContext
    var body: some View {
        if let matrix = context.matrix, let appearance = context.appearance {
            let message = entry.message
            MessageToolbar(
                quick: EmojiRecents.quick(matrix.recentEmoji), isThread: context.isThread, isSaved: entry.saved,
                pending: message.senderID == matrix.user?.id && message.sendState != "sent",
                actions: context.actions(for: entry, target: context.actionTarget(for: message))
            ).environment(\.metrics, context.metrics).environmentObject(appearance)
        }
    }
}

extension TimelineRowContext {
    func actionTarget(for message: ChatMessage) -> MessageActionTarget? {
        let surface: MessageActionTarget.Surface? = isThread ? threadRootID.map { .thread(rootID: $0) } : .conversation
        return surface.flatMap { matrix?.captureMessageAction(message: message, surface: $0) }
    }

    func actions(for row: TimelineMessageEntry, target: MessageActionTarget?) -> MessageRowActions {
        let message = row.message
        var actions = MessageRowActions(
            openProfile: onOpenProfile.map { open in
                {
                    open(
                        message.senderID,
                        ChatUser(id: message.senderID, name: message.senderName, avatarURL: message.avatarURL))
                }
            },
            thread: { self.onThread(message) }, openReplies: { self.onOpenReplies(message) },
            prepareThread: { self.matrix?.prepareThread(message) },
            reply: { self.onReply(message) }, save: { self.onSave(message) },
            react: target.map { target in { self.onReact(target, $0) } },
            openReactions: target.map { target in
                {
                    guard self.matrix?.isCurrentMessageAction(target) == true else { return }
                    self.onPickEmoji(EmojiPick { self.onReact(target, $0) })
                }
            },
            forward: onForward.flatMap { forward in
                guard let target, ForwardMessageContent.supports(message) else { return nil }
                return { forward(target) }
            },
            retrySend: { self.onRetrySend(message) }, cancelSend: { self.onCancelSend(message) })
        actions.menu = { [actions] in self.menu(row, target: target, actions: actions) }
        return actions
    }

    /// What VoiceOver offers on a message besides its menu.
    func accessibilityCommands(for row: TimelineMessageEntry, target: MessageActionTarget?) -> [MessageMenuCommand] {
        let actions = actions(for: row, target: target)
        if row.message.senderID == matrix?.user?.id && row.message.sendState != "sent" {
            return [MessageMenuCommand(id: "cancel-send", title: "Cancel sending…", perform: actions.cancelSend)]
        }
        return [
            MessageMenuCommand(id: "thread", title: "Reply in thread", perform: actions.thread),
            MessageMenuCommand(
                id: "reaction", title: "Add reaction", isEnabled: actions.openReactions != nil,
                perform: { actions.openReactions?() }),
            MessageMenuCommand(
                id: "save", title: row.saved ? "Remove from Later" : "Save for later", perform: actions.save),
        ]
    }

    private func menu(_ row: TimelineMessageEntry, target: MessageActionTarget?, actions: MessageRowActions)
        -> [MessageMenuCommand]
    {
        let message = row.message
        let own = message.senderID == matrix?.user?.id
        let copyText = MessageMenuCommand(
            id: "copy-text", title: "Copy text",
            perform: { [members = matrix?.members ?? []] in
                // The text as shown, so a mention copies as "@Name", never as its link or ID.
                let rendered = MessageBodyRenderer.shared.render(
                    body: message.body, formattedBody: message.formattedBody, revealSpoilers: true)
                let runs = MessageBodyRenderer.named(rendered.runs) { id in members.first { $0.id == id }?.name }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(runs.map(\.text).joined(), forType: .string)
            })
        var commands: [MessageMenuCommand] = []
        if own && message.sendState != "sent" {
            if let failure = row.sendFailure, failure.canRetry {
                commands.append(
                    MessageMenuCommand(
                        id: "retry-send", title: "Retry", isEnabled: !row.sendBusy, perform: actions.retrySend))
            }
            commands.append(copyText)
            commands.append(
                MessageMenuCommand(
                    id: "cancel-send", title: row.sendFailure == nil ? "Cancel sending…" : "Delete message…",
                    isEnabled: !row.sendBusy, isDestructive: true, perform: actions.cancelSend))
            return commands
        }
        if let openProfile = actions.openProfile {
            commands.append(MessageMenuCommand(id: "profile", title: "View profile", perform: openProfile))
            commands.append(MessageMenuCommand(id: "profile-divider", title: "", isSeparator: true))
        }
        commands += [
            MessageMenuCommand(
                id: "reaction", title: "Add reaction…", isEnabled: actions.openReactions != nil,
                perform: { actions.openReactions?() }),
            MessageMenuCommand(id: "thread", title: "Reply in thread", perform: actions.thread),
            MessageMenuCommand(id: "reply", title: "Reply", perform: actions.reply),
            MessageMenuCommand(
                id: "save", title: row.saved ? "Remove from Later" : "Save for later", perform: actions.save),
        ]
        if onForward != nil, ForwardMessageContent.supports(message) {
            commands.append(
                MessageMenuCommand(
                    id: "forward", title: "Forward…", isEnabled: actions.forward != nil,
                    perform: { actions.forward?() }))
        }
        if let onTogglePin {
            commands.append(
                MessageMenuCommand(
                    id: "pin", title: row.pinned ? "Unpin from conversation" : "Pin to conversation",
                    isEnabled: self.canPin && (row.pinned || !message.isRedacted) && message.eventID.hasPrefix("$"),
                    perform: { onTogglePin(message) }))
        }
        let link = permalinkTarget(for: message)
        let copying = isCopyingLink(message.eventID)
        commands += [
            copyText,
            MessageMenuCommand(
                id: "copy-link", title: copying ? "Copying link…" : "Copy link", isEnabled: link != nil && !copying,
                perform: { if let link { self.onCopyLink(link) } }),
        ]
        if own && !message.isRedacted {
            commands.append(MessageMenuCommand(id: "edit-divider", title: "", isSeparator: true))
            if message.supportsCaptionEditing, let onEditCaption {
                commands.append(
                    MessageMenuCommand(
                        id: "edit-caption", title: "Edit caption…", isEnabled: target != nil,
                        perform: { if let target { onEditCaption(target) } }))
            }
            if message.supportsTextEditing {
                commands.append(
                    MessageMenuCommand(
                        id: "edit", title: "Edit message", isEnabled: target != nil,
                        perform: { if let target { self.onEdit(target) } }))
            }
            commands.append(
                MessageMenuCommand(
                    id: "delete", title: "Delete message…", isEnabled: target != nil, isDestructive: true,
                    perform: { if let target { self.onDelete(target) } }))
        }
        return commands
    }

    private func canAct(on message: ChatMessage) -> Bool {
        canAct && message.eventID.hasPrefix("$") && message.sendState == "sent" && !message.isRedacted
    }

    /// Actions for a resting row: captures the SDK action target only when the user actually interacts or opens a menu,
    /// so evaluating `TimelineRow.body` never subscribes cells to `messages`, `threadMessages` or action context.
    func rowActions(for row: TimelineMessageEntry) -> MessageRowActions {
        let message = row.message
        let actionable = canAct(on: message)
        var actions = MessageRowActions(
            openProfile: onOpenProfile.map { open in
                {
                    open(
                        message.senderID,
                        ChatUser(id: message.senderID, name: message.senderName, avatarURL: message.avatarURL))
                }
            },
            thread: { self.onThread(message) }, openReplies: { self.onOpenReplies(message) },
            prepareThread: { self.matrix?.prepareThread(message) },
            reply: { self.onReply(message) }, save: { self.onSave(message) },
            react: actionable
                ? { emoji in
                    guard let target = self.actionTarget(for: message) else { return }
                    self.onReact(target, emoji)
                } : nil,
            openReactions: actionable
                ? {
                    guard let target = self.actionTarget(for: message),
                        self.matrix?.isCurrentMessageAction(target) == true
                    else { return }
                    self.onPickEmoji(EmojiPick { self.onReact(target, $0) })
                } : nil,
            forward: onForward.flatMap { send in
                guard actionable, ForwardMessageContent.supports(message) else { return nil }
                return {
                    guard let target = self.actionTarget(for: message) else { return }
                    send(target)
                }
            },
            retrySend: { self.onRetrySend(message) }, cancelSend: { self.onCancelSend(message) })
        actions.menu = {
            let target = self.actionTarget(for: message)
            return self.actions(for: row, target: target).menu()
        }
        return actions
    }

    func rowAttachmentActions(for message: ChatMessage) -> AttachmentActions {
        let actionable = canAct(on: message)
        return AttachmentActions(
            open: { self.onOpenMedia(message) },
            forward: actionable && ForwardMessageContent.supports(message)
                ? onForward.map { send in
                    {
                        guard let target = self.actionTarget(for: message) else { return }
                        send(target)
                    }
                } : nil,
            copyLink: { if let link = self.permalinkTarget(for: message) { self.onCopyLink(link) } },
            inlineVideo: matrix.flatMap { matrix in inlineVideo?.slot(message, matrix: matrix, in: self) })
    }

    func attachmentActions(for message: ChatMessage, target: MessageActionTarget?) -> AttachmentActions {
        AttachmentActions(
            open: { self.onOpenMedia(message) },
            forward: ForwardMessageContent.supports(message)
                ? target.flatMap { target in self.onForward.map { forward in { forward(target) } } } : nil,
            copyLink: { if let link = self.permalinkTarget(for: message) { self.onCopyLink(link) } },
            inlineVideo: matrix.flatMap { matrix in inlineVideo?.slot(message, matrix: matrix, in: self) })
    }

    private func permalinkTarget(for message: ChatMessage) -> MessagePermalinkTarget? {
        guard let matrix else { return nil }
        let surface: MessageActionTarget.Surface
        if isThread {
            guard let rootID = matrix.messageActionContext.readyThreadID else { return nil }
            surface = .thread(rootID: rootID)
        } else {
            surface = .conversation
        }
        return matrix.captureMessagePermalink(message: message, surface: surface)
    }
}

/// Isolated scroll-edge hairline state held by the pane so scrolling across the header never redraws the window.
@Observable @MainActor final class ScrollEdgeState {
    var contentAbove = false
}

private struct ScrollEdgeHairline: View {
    let state: ScrollEdgeState
    let top: CGFloat
    @ThemeColors private var colors
    var body: some View {
        if state.contentAbove {
            Divider().overlay(colors.border).padding(.top, top)
        }
    }
}

/// Measured heights of the floating header and composer bars over a timeline, pushed synchronously to the table in
/// `TimelineUnderBars`'s layout pass before the table places or opens.
@MainActor final class TimelineBarInsets {
    private(set) var current = EdgeInsets()
    private(set) var measured = false
    var onChange: ((EdgeInsets) -> Void)?

    func update(_ new: EdgeInsets) {
        let changed = !measured || new.top != current.top || new.bottom != current.bottom
        current = new
        measured = true
        if changed { onChange?(new) }
    }
}

private struct TimelineBarInsetsKey: EnvironmentKey {
    static let defaultValue: TimelineBarInsets? = nil
}

extension EnvironmentValues {
    var timelineBarInsets: TimelineBarInsets? {
        get { self[TimelineBarInsetsKey.self] }
        set { self[TimelineBarInsetsKey.self] = newValue }
    }
}

/// Measures the floating header and composer bars before placing the timeline under them, so the table receives its
/// real insets synchronously before its first `open()`.
private struct TimelineBarsLayout: Layout {
    let onMeasure: @MainActor (EdgeInsets) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return proposal.replacingUnspecifiedDimensions() }
        return first.sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 3 else {
            for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
            return
        }
        let barProposal = ProposedViewSize(width: bounds.width, height: bounds.height)
        let headerSize = subviews[1].sizeThatFits(barProposal)
        let footerSize = subviews[2].sizeThatFits(barProposal)
        if bounds.width > 0 && bounds.height > 0 {
            let measured = EdgeInsets(top: headerSize.height, leading: 0, bottom: footerSize.height, trailing: 0)
            MainActor.assumeIsolated { onMeasure(measured) }
        }
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        subviews[1].place(
            at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top,
            proposal: ProposedViewSize(width: bounds.width, height: headerSize.height))
        subviews[2].place(
            at: CGPoint(x: bounds.midX, y: bounds.maxY), anchor: .bottom,
            proposal: ProposedViewSize(width: bounds.width, height: footerSize.height))
    }
}

/// A timeline with its header over its top and its composer over its bottom, floating so rows scroll under both. Their
/// heights, tracked here as the composer grows, keep the timeline's own view of the screen between them.
struct TimelineUnderBars<Timeline: View, Header: View, Footer: View>: View {
    @State private var insets = EdgeInsets()
    @State private var barInsets = TimelineBarInsets()
    let timeline: (EdgeInsets) -> Timeline
    @ViewBuilder let header: Header
    @ViewBuilder let footer: Footer

    var body: some View {
        TimelineBarsLayout(onMeasure: measured) {
            timeline(insets).environment(\.timelineBarInsets, barInsets)
            ZStack(alignment: .top) { header }
            ZStack(alignment: .bottom) { footer }
        }
    }

    private func measured(_ new: EdgeInsets) {
        barInsets.update(new)
        if insets != new { DispatchQueue.main.async { insets = new } }
    }
}
