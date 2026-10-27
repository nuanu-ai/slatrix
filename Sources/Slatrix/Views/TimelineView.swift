import AppKit
import SwiftUI

struct TimelineView: View {
    @Environment(\.metrics) private var m
    @Environment(\.openURL) private var openURL
    let matrix: MatrixService
    @EnvironmentObject var appearance: AppearanceStore
    @Environment(Popovers.self) private var popovers: Popovers?
    let room: ChatRoom
    var thread = false
    var threadRootID: String? = nil
    var savedIDs: Set<String>
    var onThread: (ChatMessage) -> Void
    var onReply: (ChatMessage) -> Void
    var onEdit: (MessageActionTarget) -> Void
    var onSave: (ChatMessage) -> Void
    var onShowReply: ((String) -> Void)? = nil
    var onOpenProfile: ((String, ChatUser?) -> Void)? = nil
    var canPinMessages = false
    var onTogglePin: ((ChatMessage) -> Void)? = nil
    var onBottomVisibilityChange: ((Bool) -> Void)? = nil
    var onJumpToLatest: (() -> Void)? = nil
    var startsAtUnread = false
    var onForward: ((MessageActionTarget) -> Void)? = nil
    var onEditCaption: ((MessageActionTarget) -> Void)? = nil
    var onOpenMedia: ((ChatMessage) -> Void)? = nil
    @State private var loadingHistory = false
    @State private var deleting: MessageActionTarget?
    @State private var cancelling: ChatMessage?
    /// Retries and cancellations started here and not yet finished, by message ID.
    @State private var sendActions = Set<String>()
    @State private var linkCopy: LinkCopy?
    @State private var jumpVisible = false
    /// The message jumped to, while its highlight lasts.
    @State private var highlighted: String?
    @State private var layout = TimelineLayoutCache()
    @State private var rowContext = TimelineRowContext()
    @State private var scroller = TimelineScroller()
    private var colors: AppColors { appearance.colors }
    private var messages: [ChatMessage] { thread ? matrix.threadMessages : matrix.messages }
    /// A conversation opened at an older message is not live: it neither follows new messages nor is remembered.
    private var live: Bool { thread || matrix.focusedEventID == nil }
    private var hasOlder: Bool {
        !matrix.isPreview && (thread ? matrix.hasMoreThreadHistory : matrix.hasMoreHistory)
    }
    private var hasNewer: Bool { !thread && matrix.focusedEventID != nil && matrix.hasMoreForwardHistory }

    var body: some View {
        TimelineTable(
            entries: entries, context: updatedContext, live: live, bottomAligned: !thread,
            focusedEventID: thread ? nil : matrix.jump?.eventID ?? matrix.focusedEventID,
            jumpID: thread ? nil : matrix.jump?.id, startsAtUnread: startsAtUnread,
            memoryKey: "\(matrix.notificationSessionID)|\(room.id)|\(thread ? threadRootID ?? "" : "")",
            canLoadOlder: hasOlder && !loadingHistory,
            canLoadNewer: hasNewer && !loadingHistory && !matrix.isLoadingForwardHistory,
            scroller: scroller, onLoadOlder: { loadHistory() }, onLoadNewer: { loadHistory(forward: true) },
            onScroll: { atBottom, showsJump in
                jumpVisible = showsJump
                onBottomVisibilityChange?(atBottom)
            }
        )
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
                    Label("Jump to recent", systemImage: "arrow.down").font(m.font(.meta, .semibold))
                        .padding(.horizontal, m.sp16).padding(.vertical, m.sp8)
                        .background(colors.raised, in: Capsule()).overlay(Capsule().stroke(colors.border))
                        .elevation(.e2, cornerRadius: m.sp20)
                }.buttonStyle(.row).padding(m.sp16).transition(.opacity)
            }
        }
        .animation(Motion.overlay, value: jumpVisible)
        .task(id: thread ? nil : matrix.jump?.id) {
            highlighted = thread ? nil : matrix.jump?.eventID
            // Held long enough to find, then faded by the row.
            guard highlighted != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            highlighted = nil
        }
        .background(colors.canvas)
        // Every message redraws the timeline; it fills what it is given, so that never lays out the window.
        .layoutIsolated()
        .onDisappear {
            deleting = nil
            cancelling = nil
            linkCopy = nil
            onBottomVisibilityChange?(false)
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
        let rows = layout.rows(
            messages, firstUnreadEventID: thread ? nil : matrix.firstUnreadEventID,
            groups: appearance.density != .compact)
        let context = matrix.messageActionContext
        let offline = matrix.connectionState == .offline
        let failures = matrix.sendFailures.compactMapValues { $0.shown(offline: offline) }
        let inputs = TimelineLayoutCache.EntryInputs(
            rows: rows, hasOlder: hasOlder, hasNewer: hasNewer, loadingHistory: loadingHistory, welcome: welcome,
            pinned: room.pinnedEventIDs,
            canPin: canPinMessages, savedIDs: savedIDs, highlighted: highlighted,
            sendFailures: failures, pendingSendActions: matrix.pendingSendActions, sendActions: sendActions,
            context: context, collapsedMedia: matrix.collapsedMedia)
        return layout.entries(for: inputs) { buildEntries(rows, context: context, failures: failures) }
    }

    private var welcome: TimelineWelcome {
        TimelineWelcome(name: room.name, topic: room.topic, isDirect: room.isDirect, isEncrypted: room.isEncrypted)
    }

    private func buildEntries(
        _ rows: [TimelineLayout.Row], context: MessageActionTarget.Context,
        failures: [SendQueueMessageKey: MessageSendFailure]
    ) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        entries.reserveCapacity(rows.count + 2)
        if hasOlder {
            entries.append(TimelineEntry(id: "older", kind: .loading(loadingHistory)))
        } else if !thread {
            entries.append(
                TimelineEntry(
                    id: "welcome",
                    kind: .welcome(welcome)))
        }
        // Read once: each read of a published property costs more than the lookups below.
        let pinned = Set(room.pinnedEventIDs)
        let pending = matrix.pendingSendActions
        let collapsed = matrix.collapsedMedia
        for row in rows {
            switch row.kind {
            case .day(let label): entries.append(TimelineEntry(id: row.id, kind: .day(label)))
            case .unread: entries.append(TimelineEntry(id: row.id, kind: .unread))
            case .message(let message, let grouped, let time):
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
                                pinned: pinned.contains(message.eventID), canPin: canPinMessages,
                                highlighted: highlighted == message.eventID,
                                sendFailure: failures.isEmpty ? nil : failures[key],
                                sendBusy: !pending.isEmpty && pending.contains(key) || sendActions.contains(message.id),
                                mediaCollapsed: !collapsed.isEmpty && collapsed.contains(message.eventID),
                                context: context))))
            }
        }
        if hasNewer { entries.append(TimelineEntry(id: "newer", kind: .loading(loadingHistory))) }
        return entries
    }

    private var updatedContext: TimelineRowContext {
        let context = rowContext
        context.matrix = matrix
        context.isThread = thread
        context.threadRootID = threadRootID
        context.metrics = m
        context.appearance = appearance
        context.openURL = openURL
        context.onThread = onThread
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
                if matrix.notificationSessionID == session, matrix.timelineSelectionID == selection {
                    matrix.errorMessage = MatrixService.safeError(error)
                }
            }
        }
    }
}

/// Lays the messages out once per change, and pins the "New messages" line to the first unread event it saw, so
/// reading does not move the line.
@MainActor final class TimelineLayoutCache {
    private var input: (messages: [ChatMessage], unread: String?, groups: Bool)?
    private var rows: [TimelineLayout.Row] = []
    private var unreadBoundary: String?
    /// Everything a timeline's entries show besides the rows; the timeline redraws for many changes that touch none.
    struct EntryInputs: Equatable {
        var rows: [TimelineLayout.Row]
        var hasOlder: Bool
        var hasNewer: Bool
        var loadingHistory: Bool
        var welcome: TimelineWelcome
        var pinned: [String]
        var canPin: Bool
        var savedIDs: Set<String>
        var highlighted: String?
        var sendFailures: [SendQueueMessageKey: MessageSendFailure]
        var pendingSendActions: Set<SendQueueMessageKey>
        var sendActions: Set<String>
        var context: MessageActionTarget.Context
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

    func rows(_ messages: [ChatMessage], firstUnreadEventID: String?, groups: Bool) -> [TimelineLayout.Row] {
        if unreadBoundary == nil, let firstUnreadEventID, messages.contains(where: { $0.eventID == firstUnreadEventID })
        {
            unreadBoundary = firstUnreadEventID
        }
        if let input, input.groups == groups, input.unread == unreadBoundary, input.messages == messages { return rows }
        rows = TimelineLayout.rows(
            messages, unreadBoundaryEventID: unreadBoundary, groups: groups, now: Date(), calendar: .current,
            locale: .current)
        input = (messages, unreadBoundary, groups)
        return rows
    }
}

/// What a message row does when someone acts on it, bound to that message by the timeline.
struct MessageRowActions {
    var openProfile: (() -> Void)?
    var thread: () -> Void = {}
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
    var body: some View {
        layout
            .background(hovered ? colors.hover : .clear)
            .background {
                // A cell shows another message after a scroll; that one's highlight starts afresh, never fading in.
                colors.highlight.opacity(highlighted ? 1 : 0)
                    .animation(highlighted ? nil : Motion.highlight, value: highlighted).id(message.id)
            }
            .contentShape(Rectangle())
    }
    private var layout: some View {
        HStack(alignment: .top, spacing: m.sp12) {
            if !compact {
                if grouped || !appearance.showAvatars {
                    // One line: "12:00 AM" is wider than the gutter, and a wrap would grow the row on hover.
                    Text(hovered ? time : "").font(m.font(.caption)).lineLimit(1).fixedSize()
                        .foregroundStyle(colors.textSecondary).frame(width: m.avatar, alignment: .trailing)
                        .overlay(alignment: .trailing) { if grouped && sending && !hovered { clock } }
                        .padding(.top, m.sp4)
                } else {
                    Button {
                        actions.openProfile?()
                    } label: {
                        avatar ?? AvatarView(name: message.senderName, size: m.avatar)
                    }.buttonStyle(.row).disabled(actions.openProfile == nil).help(
                        "View \(message.senderName)’s profile")
                }
            }
            VStack(alignment: .leading, spacing: m.sp4) {
                if isPinned {
                    Label("Pinned", systemImage: "pin.fill").font(m.font(.caption))
                        .foregroundStyle(colors.textSecondary)
                }
                if !grouped || compact {
                    HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                        if compact {
                            Text(time).font(m.font(.caption))
                                .foregroundStyle(colors.textSecondary)
                        }
                        Button {
                            actions.openProfile?()
                        } label: {
                            Text(message.senderName).font(m.font(.body, .bold))
                                .foregroundStyle(colors.textPrimary)
                        }.buttonStyle(.row).disabled(actions.openProfile == nil).help("View profile")
                        if !compact {
                            Text(time).font(m.font(.caption))
                                .foregroundStyle(colors.textSecondary)
                        }
                        if isSaved {
                            Image(systemName: "bookmark.fill").font(m.font(.caption)).foregroundStyle(colors.accent)
                        }
                    }.overlay(alignment: .trailing) {
                        if sending { clock.padding(.leading, m.sp8).frame(width: 0, alignment: .leading) }
                    }
                }
                if message.isRedacted {
                    Text("This message was deleted.").italic().font(m.font(.body)).foregroundStyle(
                        colors.textSecondary
                    )
                } else {
                    if let replyPreview { replyPreview }
                    if message.kind == "m.room.encrypted" {
                        // One quiet line per message; the header offers the recovery key once for all of them.
                        Label(message.body, systemImage: "lock").font(m.font(.secondary)).italic()
                            .foregroundStyle(colors.textSecondary)
                    } else if message.showsMessageBody {
                        // Slack draws a message that hasn't reached the server lighter, and nothing else.
                        NativeMessageBody(
                            body: message.body, formattedBody: message.formattedBody, edited: message.isEdited,
                            menuCommands: actions.menu
                        ).opacity(pendingSend ? 0.5 : 1)
                    }
                    if message.isEdited && (!message.showsMessageBody || message.kind == "m.room.encrypted") {
                        Text("(edited)").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                    }
                    // A reused cell shows another message: a download or preview in flight must not carry over.
                    if let attachment { attachment.padding(.vertical, m.sp4).id(message.id) }
                    if !message.reactions.isEmpty { reactions.padding(.top, m.sp2) }
                    if !isThread && message.replyCount > 0 {
                        ThreadRepliesBar(
                            count: message.replyCount, lastReply: message.lastReply, avatar: replierAvatar,
                            action: actions.thread)
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
                        }.font(m.font(.caption)).padding(.top, m.sp2)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, m.sp20).padding(.top, grouped || compact ? 3 : 12).padding(.bottom, m.sp4)
    }
    private var clock: some View { SendingClock(since: message.timestamp) }

    private var reactions: some View {
        HStack(spacing: m.sp4) {
            ForEach(message.reactions, id: \.key) { reaction in
                Button {
                    actions.react?(reaction.key)
                } label: {
                    ReactionChip(mine: reaction.mine) {
                        Text(reaction.key).font(m.font(.secondary))
                        Text("\(reaction.count)").font(m.font(.caption, .semibold))
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
                    Image(systemName: "face.smiling").font(m.font(.secondary)).foregroundStyle(colors.textSecondary)
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
        Image(systemName: "clock").font(m.font(.caption)).foregroundStyle(appearance.colors.textSecondary)
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

/// A reaction's pill: 24 pt, gray at rest; yours are tinted, with an accent edge.
private struct ReactionChip<Content: View>: View {
    let mine: Bool
    @ViewBuilder let content: Content
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    var body: some View {
        let colors = appearance.colors
        HStack(spacing: m.sp4) { content }.padding(.horizontal, m.sp8).frame(height: m.sp24)
            .background(mine ? colors.accentTint : colors.sunken, in: Capsule())
            .overlay(Capsule().strokeBorder(mine ? colors.accent : .clear))
    }
}

/// Slack's replies bar: who replied last, how many replies and when. Hovering outlines it and offers the thread,
/// at the same height.
private struct ThreadRepliesBar: View {
    private static let maxWidth: CGFloat = 600
    let count: Int
    let lastReply: ThreadReply?
    let avatar: AvatarView?
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
                Text("\(count) \(count == 1 ? "reply" : "replies")").font(m.font(.meta, .semibold))
                    .foregroundStyle(colors.accent)
                if hovering {
                    Text("View thread").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                    Spacer(minLength: m.sp8)
                    Image(systemName: "chevron.right").font(m.font(.caption, .semibold))
                        .foregroundStyle(colors.textSecondary)
                } else if let lastReply {
                    Text(ThreadReply.lastReplyText(lastReply.timestamp, now: Date())).font(m.font(.meta))
                        .foregroundStyle(colors.textSecondary)
                }
            }.lineLimit(1).padding(m.sp4).frame(maxWidth: m(Self.maxWidth), minHeight: m.sp32, alignment: .leading)
                .background(hovering ? colors.canvas : .clear, in: shape)
                .overlay(shape.strokeBorder(hovering ? colors.border : .clear))
        }.buttonStyle(.row).onHover { hovering = $0 }.accessibilityLabel("\(count) replies, view thread")
            // The face lines up with the text above; the hover box reaches past it.
            .padding(.leading, -m.sp4)
    }
}

/// Slack's hover toolbar: three one-click reactions, then add reaction, reply in thread, forward, save and more.
/// The timeline floats one over the hovered row's top edge, so no row draws it or changes height for it.
struct MessageToolbar: View {
    static let button: CGFloat = 28
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
                            Text(emoji).font(m.font(.body)).frame(width: m(Self.button), height: m(Self.button))
                        }.buttonStyle(.icon).help("React with \(EmojiCatalog.shortcode(for: emoji))")
                    }
                }
                if let openReactions = actions.openReactions {
                    button("face.smiling", "Find another reaction", action: openReactions)
                }
                if !isThread { button("text.bubble", "Reply in thread", action: actions.thread) }
                if let forward = actions.forward {
                    button("arrowshape.turn.up.right", "Forward message", action: forward)
                }
                button(
                    isSaved ? "bookmark.fill" : "bookmark", isSaved ? "Remove from Later" : "Save for later",
                    action: actions.save)
            }
            Menu {
                NativeMessageMenuCommands(commands: actions.menu())
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(m.font(.body))
                    .frame(width: m(Self.button), height: m(Self.button))
            }.menuStyle(.button).buttonStyle(.icon).menuIndicator(.hidden).help("More actions")
                .accessibilityLabel("More actions")
        }
        .foregroundStyle(colors.textSecondary).padding(m.sp2)
        .background(colors.overlay, in: shape).overlay(shape.strokeBorder(colors.border))
        .elevation(.e1, cornerRadius: m.radiusLarge)
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
            thread: { self.onThread(message) }, reply: { self.onReply(message) }, save: { self.onSave(message) },
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
                    isEnabled: row.canPin && (row.pinned || !message.isRedacted) && message.eventID.hasPrefix("$"),
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

    func attachmentActions(for message: ChatMessage, target: MessageActionTarget?) -> AttachmentActions {
        AttachmentActions(
            open: { self.onOpenMedia(message) },
            forward: ForwardMessageContent.supports(message)
                ? target.flatMap { target in self.onForward.map { forward in { forward(target) } } } : nil,
            copyLink: { if let link = self.permalinkTarget(for: message) { self.onCopyLink(link) } })
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
