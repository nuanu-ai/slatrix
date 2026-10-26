import AppKit
import SwiftUI

struct TimelineView: View {
    @Environment(\.metrics) private var m
    @Environment(\.openURL) private var openURL
    let matrix: MatrixService
    @EnvironmentObject var appearance: AppearanceStore
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
            focusedEventID: thread ? nil : matrix.focusedEventID, startsAtUnread: startsAtUnread,
            memoryKey: live
                ? "\(matrix.notificationSessionID)|\(room.id)|\(thread ? threadRootID ?? "" : "")" : nil,
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
        .alert(
            "Delete message?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
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
            }
        } message: {
            Text("This can’t be undone.")
        }
        .alert(
            "Cancel sending this message?",
            isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })
        ) {
            Button("Keep sending", role: .cancel) { cancelling = nil }
            Button("Cancel sending", role: .destructive) {
                if let message = cancelling { cancelSend(message) }
                cancelling = nil
            }
        } message: {
            Text("It may already have been delivered.")
        }
        .alert(
            "Couldn’t copy message link",
            isPresented: Binding(get: { linkCopy?.error != nil }, set: { if !$0 { linkCopy?.error = nil } })
        ) {
            Button("Retry") { [target = linkCopy?.target] in if let target { copyLink(target) } }
            Button("Cancel", role: .cancel) { linkCopy = nil }
        } message: {
            Text(linkCopy?.error ?? "Try again in a moment.")
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
            canPin: canPinMessages, savedIDs: savedIDs, highlighted: thread ? nil : matrix.focusedEventID,
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
        let highlighted = thread ? nil : matrix.focusedEventID
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
    var replyPreview: ReplyPreviewView? = nil
    var attachment: AttachmentView? = nil
    var actions = MessageRowActions()
    @Environment(\.metrics) private var m
    private var colors: AppColors { appearance.colors }
    private var pendingSend: Bool { own && message.sendState != "sent" }
    private var compact: Bool { appearance.density == .compact }
    private var time: String { timeLabel ?? message.timestamp.formatted(.dateTime.hour().minute()) }
    var body: some View {
        layout
            .background(hovered ? colors.hover : highlighted ? colors.accent.opacity(0.12) : .clear)
            // Over the row's top edge, like Slack's: hovering never changes the row's height.
            .overlay(alignment: .topTrailing) {
                if hovered && !message.isRedacted { toolbar.padding(.trailing, m.sp16) }
            }
            .contentShape(Rectangle())
    }
    private var layout: some View {
        HStack(alignment: .top, spacing: m.sp12) {
            if !compact {
                if grouped || !appearance.showAvatars {
                    // One line: "12:00 AM" is wider than the gutter, and a wrap would grow the row on hover.
                    Text(hovered ? time : "").font(m.font(.caption)).lineLimit(1).fixedSize()
                        .foregroundStyle(colors.textSecondary).frame(width: m.avatar, alignment: .trailing).padding(
                            .top, m.sp4)
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
                        if own && message.sendState == "sending" { DelayedProgress() }
                        if isSaved {
                            Image(systemName: "bookmark.fill").font(m.font(.caption)).foregroundStyle(colors.accent)
                        }
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
                        NativeMessageBody(
                            body: message.body, formattedBody: message.formattedBody, menuCommands: actions.menu)
                    }
                    if message.isEdited {
                        Text("(edited)").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                    }
                    // A reused cell shows another message: a download or preview in flight must not carry over.
                    if let attachment { attachment.padding(.vertical, m.sp4).id(message.id) }
                    if !message.reactions.isEmpty {
                        HStack(spacing: m.sp4) {
                            ForEach(message.reactions, id: \.key) { reaction in
                                Button {
                                    actions.react?(reaction.key)
                                } label: {
                                    HStack(spacing: m.sp4) {
                                        Text(reaction.key)
                                        Text("\(reaction.count)").font(m.font(.caption, .medium))
                                    }.padding(.horizontal, m.sp8).frame(height: m.sp24).background(
                                        reaction.mine ? colors.selection.opacity(0.6) : colors.raised, in: Capsule()
                                    ).overlay(Capsule().stroke(reaction.mine ? colors.accent : .clear, lineWidth: 1))
                                }.buttonStyle(.row).disabled(actions.react == nil).help(
                                    "\(reaction.key) · \(reaction.count) \(reaction.mine ? "including you" : "reactions")"
                                )
                            }
                            Button {
                                actions.openReactions?()
                            } label: {
                                Image(systemName: "face.smiling").font(m.font(.meta)).padding(.horizontal, m.sp8).frame(
                                    height: m.sp24
                                ).background(colors.raised, in: Capsule())
                            }.buttonStyle(.row).disabled(actions.openReactions == nil).help("Add reaction")
                        }.padding(.top, m.sp2)
                    }
                    if !isThread && message.replyCount > 0 {
                        Button(action: actions.thread) {
                            HStack(spacing: m.sp8) {
                                Image(systemName: "bubble.left.and.bubble.right.fill").font(m.font(.meta))
                                Text("\(message.replyCount) \(message.replyCount == 1 ? "reply" : "replies")").font(
                                    m.font(.meta, .semibold))
                            }.foregroundStyle(colors.accent).padding(.vertical, m.sp4)
                        }.buttonStyle(.row)
                    }
                    if pendingSend {
                        VStack(alignment: .leading, spacing: m.sp8) {
                            if let failure = sendFailure {
                                Label(failure.message, systemImage: "exclamationmark.circle").font(m.font(.caption))
                                    .foregroundStyle(colors.warning)
                                HStack(spacing: m.sp12) {
                                    if failure.canRetry {
                                        Button(
                                            failure.kind == .recoverable ? "Resume sending" : "Retry",
                                            action: actions.retrySend
                                        ).buttonStyle(.row).foregroundStyle(colors.accent).disabled(sendBusy)
                                    }
                                    Button("Cancel sending…", action: actions.cancelSend).buttonStyle(.row)
                                        .foregroundStyle(colors.textSecondary).disabled(sendBusy)
                                    if sendBusy { DelayedProgress() }
                                }.font(m.font(.caption))
                            } else {
                                Label("Sending…", systemImage: "clock").font(m.font(.caption)).foregroundStyle(
                                    colors.textSecondary)
                            }
                        }.padding(.top, m.sp2)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, m.sp20).padding(.top, grouped || compact ? 3 : 12).padding(.bottom, m.sp4)
    }
    /// Small enough to sit inside a one-line grouped message, so hovering never changes a row's height.
    static let toolbarButton: CGFloat = 24
    private var toolbar: some View {
        HStack(spacing: 0) {
            if !pendingSend {
                IconButton(
                    symbol: "face.smiling", label: "Add reaction", role: .body, side: Self.toolbarButton,
                    action: { actions.openReactions?() }
                ).disabled(actions.openReactions == nil)
                if !isThread {
                    IconButton(
                        symbol: "bubble.right", label: "Reply in thread", role: .body, side: Self.toolbarButton,
                        action: actions.thread)
                }
                IconButton(
                    symbol: "arrowshape.turn.up.left",
                    label: "Reply",
                    role: .body, side: Self.toolbarButton,
                    action: actions.reply
                )
                IconButton(
                    symbol: isSaved ? "bookmark.fill" : "bookmark",
                    label: isSaved ? "Remove from Later" : "Save for later", role: .body, side: Self.toolbarButton,
                    action: actions.save
                )
            }
            Menu {
                NativeMessageMenuCommands(commands: actions.menu())
            } label: {
                Image(systemName: "ellipsis").font(m.font(.body)).frame(
                    width: m(Self.toolbarButton), height: m(Self.toolbarButton))
            }.menuStyle(.borderlessButton).frame(width: m(Self.toolbarButton))
        }.padding(.horizontal, m.sp2).frame(height: m(Self.toolbarButton)).background(
            colors.overlay, in: RoundedRectangle(cornerRadius: m.radius)
        )
        .overlay(RoundedRectangle(cornerRadius: m.radius).stroke(colors.border)).elevation(.e1, cornerRadius: m.radius)
    }
}

extension TimelineRowContext {
    func actionTarget(for message: ChatMessage) -> MessageActionTarget? {
        let surface: MessageActionTarget.Surface? = isThread ? threadRootID.map { .thread(rootID: $0) } : .conversation
        return surface.flatMap { matrix?.captureMessageAction(message: message, surface: $0) }
    }

    /// `id` is the row's, for placing the reaction picker over it.
    func actions(for id: String, _ row: TimelineMessageEntry, target: MessageActionTarget?) -> MessageRowActions {
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
                    self.onPickReaction(id, target) { self.onReact(target, $0) }
                }
            },
            retrySend: { self.onRetrySend(message) }, cancelSend: { self.onCancelSend(message) })
        actions.menu = { [actions] in self.menu(row, target: target, actions: actions) }
        return actions
    }

    /// What VoiceOver offers on a message besides its menu.
    func accessibilityCommands(for id: String, _ row: TimelineMessageEntry, target: MessageActionTarget?)
        -> [MessageMenuCommand]
    {
        let actions = actions(for: id, row, target: target)
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
                        id: "retry-send", title: failure.kind == .recoverable ? "Resume sending" : "Retry sending",
                        isEnabled: !row.sendBusy, perform: actions.retrySend))
            }
            commands.append(copyText)
            commands.append(
                MessageMenuCommand(
                    id: "cancel-send", title: "Cancel sending…", isEnabled: !row.sendBusy, isDestructive: true,
                    perform: actions.cancelSend))
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
        if let onForward, ForwardMessageContent.supports(message) {
            commands.append(
                MessageMenuCommand(
                    id: "forward", title: "Forward…", isEnabled: target != nil,
                    perform: { if let target { onForward(target) } }))
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

struct ReactionPicker: View {
    private static let cell: CGFloat = 32
    private static let columns = 6
    @Environment(\.metrics) private var m
    let onSelect: (String) -> Void
    private let emojis = [
        "👍", "👎", "❤️", "😂", "🎉", "🙌", "👀", "✅", "🔥", "🚀", "🤔", "🙏", "👏", "✨", "💯", "👋", "💡", "🤝", "😅", "💪", "🌱", "🫡",
        "😎", "🫶",
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(m(Self.cell)), spacing: m.sp4), count: Self.columns),
                spacing: m.sp4
            ) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        onSelect(emoji)
                    } label: {
                        Text(emoji).font(m.font(.header)).frame(width: m(Self.cell), height: m(Self.cell))
                    }.buttonStyle(.row).help(emoji)
                }
            }
        }.fixedSize()
    }
}
