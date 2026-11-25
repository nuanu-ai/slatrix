import SwiftUI

struct ThreadsFeedView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let feed: ThreadFeedService
    @Binding var workspaceID: String?
    var unreadOnly = false
    var onOpen: (ChatMessage) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    private var displayedItems: [ThreadFeedItem] { unreadOnly ? feed.items.filter(\.isUnread) : feed.items }

    private var errorBannerMessage: String? {
        if let error = feed.errorMessage { return error }
        let failed = feed.failedRoomCount
        guard failed > 0 else { return nil }
        return failed == 1 ? "Couldn’t check 1 conversation" : "Couldn’t check \(failed) conversations"
    }

    var body: some View {
        let visibleItems = displayedItems
        VStack(spacing: 0) {
            Divider().overlay(colors.border)
            if let error = errorBannerMessage {
                HStack {
                    InlineErrorView(message: error)
                    Button("Retry") {
                        if feed.errorMessage != nil { refresh() } else { Task { await matrix.retryFailedThreads() } }
                    }.buttonStyle(.textLink).font(m.font(.subheadline)).padding(.trailing, m.sp20)
                }.disabled(feed.isLoading)
                Divider().overlay(colors.border)
            }
            if visibleItems.isEmpty {
                if feed.items.isEmpty && (feed.isLoading || feed.isDiscovering) {
                    SkeletonRows(interval: .threadsLoading)
                        .frame(maxWidth: m(ConversationGrid.collectionWidth), alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if unreadOnly && !feed.items.isEmpty {
                    EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "No unread threads")
                } else {
                    EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "No threads yet")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: m.sp12) {
                        ForEach(visibleItems) { item in
                            ThreadFeedRow(
                                item: item, root: feed.preview(roomID: item.roomID, eventID: item.root.eventID),
                                latest: item.latest.flatMap {
                                    $0.eventID == item.root.eventID
                                        ? nil : feed.preview(roomID: item.roomID, eventID: $0.eventID)
                                }, matrix: matrix, onOpen: onOpen,
                                hydrate: { [feed] in await feed.hydratePreview(item, retry: $0) })
                        }
                        if feed.hasOlderThreads {
                            Button("Load older threads") { Task { await matrix.loadOlderThreads() } }
                                .buttonStyle(.textLink)
                                .font(m.font(.subheadline, .medium))
                                .padding(.vertical, m.sp8)
                                .disabled(feed.isLoading)
                        }
                    }.padding(.horizontal, m.sp20).padding(.vertical, m.sp16)
                        .frame(maxWidth: m(ConversationGrid.collectionWidth), alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
        }.background(colors.canvas)
            .environment(\.mentions, MentionContext(me: matrix.user?.id))
            .onAppear { matrix.prepareThreads(workspaceID: workspaceID) }
            .onChange(of: workspaceID) { _, next in matrix.prepareThreads(workspaceID: next) }
            .task(id: workspaceID) { await matrix.openThreads(workspaceID: workspaceID) }
            .onDisappear { matrix.closeThreads() }
    }

    private func refresh() { Task { await matrix.openThreads(workspaceID: workspaceID) } }
}

struct FeedWorkspacePicker: View {
    private static let maxWidth: CGFloat = 180
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    @Binding var workspaceID: String?
    var body: some View {
        Picker("Workspace", selection: $workspaceID) {
            Text("All conversations").tag(Optional<String>.none)
            ForEach(matrix.workspaces) { Text($0.name).tag(Optional($0.id)) }
        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: m(Self.maxWidth)).accessibilityLabel("Filter by workspace")
    }
}

/// Toolbar controls for Threads, isolated from `RootView` so refresh state changes never re-evaluate the window body.
struct ThreadsToolbarControls: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let feed: ThreadFeedService
    @Binding var workspaceID: String?
    @Binding var unreadOnly: Bool

    var body: some View {
        HStack(spacing: m.sp12) {
            Toggle(isOn: $unreadOnly) { Text("Unreads").font(m.font(.body)) }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            if !matrix.workspaces.isEmpty {
                FeedWorkspacePicker(matrix: matrix, workspaceID: $workspaceID)
            }
            IconButton(symbol: "arrow.clockwise", label: "Refresh threads", role: .body) {
                Task { await matrix.openThreads(workspaceID: workspaceID) }
            }.disabled(feed.isLoading)
        }
    }
}

/// One thread card. It reads only its own previews, so a preview that hydrates redraws this row alone.
struct ThreadFeedRow: View {
    let item: ThreadFeedItem
    let root: ThreadPreview
    let latest: ThreadPreview?
    let matrix: MatrixService
    let onOpen: (ChatMessage) -> Void
    let hydrate: (_ retry: Bool) async -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var hovering = false
    private var colors: AppColors { appearance.colors }
    private var failed: Bool { root.state == .failed || latest?.state == .failed }
    private var replyLabel: String {
        item.replyCount > 0 ? "\(item.replyCount) \(item.replyCount == 1 ? "reply" : "replies")" : "Thread"
    }

    var body: some View {
        let rootMessage = root.shown(item.root)
        let cardShape = RoundedRectangle(cornerRadius: m.radiusLarge)
        Button {
            onOpen(rootMessage)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: m.sp8) {
                    Image(systemName: item.isDirect ? "person" : item.isPrivate ? "lock" : "number")
                        .font(m.font(.subheadline))
                    Text(item.roomName)
                        .font(m.font(.subheadline, item.isUnread ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: m.sp8)
                    Text(replyLabel)
                        .font(m.font(.subheadline, item.isUnread ? .semibold : .medium))
                        .foregroundStyle(item.isUnread ? colors.accent : colors.textSecondary)
                    Text("·").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                    Text(LatestMessage(body: nil, timestamp: item.lastActivityAt, isOwn: false).time())
                        .font(m.font(.subheadline))
                        .foregroundStyle(colors.textSecondary)
                        .help(item.lastActivityAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
                    if item.isUnread { Circle().fill(colors.accent).frame(width: m.sp8, height: m.sp8) }
                }.foregroundStyle(item.isUnread ? colors.textPrimary : colors.textSecondary)
                    .padding(.horizontal, m.sp16).padding(.top, m.sp12).padding(.bottom, m.sp8)

                HStack(alignment: .top, spacing: m.sp12) {
                    AvatarView(
                        name: rootMessage.senderName, size: m.avatar, matrix: matrix, source: rootMessage.avatarURL)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(rootMessage.senderName).font(m.font(.reading, .semibold))
                            .foregroundStyle(colors.textPrimary).lineLimit(1)
                        previewBody(
                            rootMessage, state: root.state, shape: item.root, role: .reading, color: colors.textBody,
                            limit: 3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, m.sp16).padding(.top, m.sp4)
                    .padding(.bottom, latest == nil ? m.sp16 : m.sp12)

                if let latest, let snapshot = item.latest {
                    let message = latest.shown(snapshot)
                    let textColumnInset = m.sp16 + m.avatar + m.sp12
                    Divider().overlay(colors.border).padding(.leading, textColumnInset).padding(.trailing, m.sp16)
                    HStack(alignment: .top, spacing: m.sp8) {
                        AvatarView(
                            name: message.senderName, size: m.avatarSmall, matrix: matrix, source: message.avatarURL)
                        VStack(alignment: .leading, spacing: m.sp2) {
                            Text(message.senderName)
                                .font(m.font(.body, item.isUnread ? .semibold : .medium))
                                .foregroundStyle(item.isUnread ? colors.textPrimary : colors.textSecondary)
                                .lineLimit(1)
                            previewBody(
                                message, state: latest.state, shape: snapshot, role: .body,
                                color: item.isUnread ? colors.textBody : colors.textSecondary, limit: 2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.leading, textColumnInset).padding(.trailing, m.sp16).padding(.vertical, m.sp12)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? colors.rowHover : colors.surfaceCard, in: cardShape)
                .overlay { cardShape.strokeBorder(hovering ? colors.borderStrong : colors.border, lineWidth: 0.5) }
                .contentShape(cardShape)
                .onHover { hovering = $0 }
                .accessibilityElement(children: .combine).accessibilityLabel(
                    "Thread in \(item.roomName), \(rootMessage.senderName), \(Self.plainPreview(rootMessage)), \(item.replyCount) \(item.replyCount == 1 ? "reply" : "replies")"
                ).accessibilityValue(item.isUnread ? "Unread" : "")
        }.buttonStyle(.row)
            .task(id: item.id + (item.latest?.eventID ?? "")) { await hydrate(false) }
            .contextMenu {
                Button("Open thread") { onOpen(rootMessage) }
                if failed { Button("Retry preview") { Task { await hydrate(true) } } }
            }
    }

    /// Until its current text is read, a message shows as bars using the same font role, line spacing and line limit
    /// as `NativeMessageBody`, so hydrating or failing keeps the card's height still and never exposes unedited text.
    @ViewBuilder private func previewBody(
        _ message: ChatMessage, state: ThreadPreview.State, shape: ChatMessage, role: TextRole, color: Color, limit: Int
    ) -> some View {
        let spacing = MessageBlocks.readingLineSpacing(m.size(role))
        let minLine = ceil(m.size(role) + 3)
        Group {
            switch state {
            case .ready where message.isRedacted:
                Text(ChatMessage.deletedBody).italic().font(m.font(role)).lineSpacing(spacing)
                    .foregroundStyle(colors.textSecondary)
            case .ready:
                NativeMessageBody(
                    body: Self.preview(message), formattedBody: message.formattedBody, showsSpoilerControl: false,
                    largeEmoji: false, role: role, textColor: color
                ).allowsHitTesting(false)
            case .failed:
                Text("Preview unavailable").italic().font(m.font(role)).lineSpacing(spacing)
                    .foregroundStyle(colors.textSecondary)
                    .help(root.error ?? latest?.error ?? "Right-click to retry")
            case .snapshot, .loading:
                Text(Self.plainPreview(shape)).font(m.font(role)).lineSpacing(spacing)
                    .foregroundStyle(color)
                    .redacted(reason: .placeholder).accessibilityHidden(true)
            }
        }
        .lineLimit(limit)
        .multilineTextAlignment(.leading)
        .frame(minHeight: minLine, alignment: .topLeading)
    }

    private static func preview(_ message: ChatMessage) -> String {
        if message.isRedacted { return ChatMessage.deletedBody }
        if message.formattedBody?.localizedCaseInsensitiveContains("data-mx-spoiler") == true {
            return "[Spoiler hidden]"
        }
        return message.body.isEmpty ? message.attachment?.name ?? "Message" : message.body
    }

    private static func plainPreview(_ message: ChatMessage) -> String {
        if message.isRedacted { return ChatMessage.deletedBody }
        let text = ActivityService.previewBody(for: message)
        return text.isEmpty ? message.attachment?.name ?? "Message" : text
    }
}
