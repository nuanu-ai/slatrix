import SwiftUI

struct ThreadsFeedView: View {
    private static let historyMaxHeight: CGFloat = 144
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let feed: ThreadFeedService
    @Binding var workspaceID: String?
    var onOpen: (ChatMessage) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var coverageExpanded = false
    private var colors: AppColors { appearance.colors }
    private var failedRoomCount: Int { feed.roomStates.filter { $0.state == .error }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp12) {
                Spacer()
                FeedWorkspacePicker(matrix: matrix, workspaceID: $workspaceID)
                IconButton(symbol: "arrow.clockwise", label: "Refresh threads", role: .body) { refresh() }.disabled(
                    feed.isLoading)
            }.padding(.horizontal, m.sp24).frame(height: m.control + m.sp16)
            Divider().overlay(colors.border)
            if let error = feed.errorMessage {
                HStack {
                    InlineErrorView(message: error)
                    Button("Retry", action: refresh).buttonStyle(.textLink).font(m.font(.meta)).padding(
                        .trailing, m.sp20)
                }.disabled(feed.isLoading)
            }
            if feed.items.isEmpty {
                if feed.isLoading {
                    SkeletonRows(interval: .threadsLoading)
                } else {
                    EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "No threads yet") {
                        if feed.canCheckMore { Button("Look further") { Task { await matrix.checkMoreThreads() } } }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.items) { item in
                            ThreadFeedRow(
                                item: item, root: feed.preview(roomID: item.roomID, eventID: item.root.eventID),
                                latest: item.latest.flatMap {
                                    $0.eventID == item.root.eventID
                                        ? nil : feed.preview(roomID: item.roomID, eventID: $0.eventID)
                                }, matrix: matrix, onOpen: onOpen,
                                hydrate: { [feed] in await feed.hydratePreview(item, retry: $0) })
                            Divider().overlay(colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                        }
                        if feed.isLoading {
                            DelayedProgress().padding(m.sp20).accessibilityLabel(
                                "Checking more threads"
                            ).loadingInterval(.threadsLoading)
                        }
                    }.padding(.horizontal, m.sp2)
                }
            }
            coverage
        }.background(colors.canvas)
            .task(id: workspaceID) { await matrix.openThreads(workspaceID: workspaceID) }
            .onDisappear { matrix.closeThreads() }
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            HStack(alignment: .center) {
                if failedRoomCount > 0 {
                    Button("\(failedRoomCount) couldn’t load") { coverageExpanded = true }.buttonStyle(.textLink).font(
                        m.font(.caption))
                }
                Spacer()
                if feed.canCheckMore {
                    Button("Look further") { Task { await matrix.checkMoreThreads() } }.font(m.font(.caption))
                        .disabled(feed.isLoading)
                }
            }
            DisclosureGroup(isExpanded: $coverageExpanded) {
                ScrollView {
                    LazyVStack(spacing: m.sp8) {
                        ForEach(feed.roomStates) { state in
                            HStack(spacing: m.sp8) {
                                Text(state.name).font(m.font(.caption)).lineLimit(1)
                                Spacer()
                                if state.state == .loading {
                                    DelayedProgress()
                                } else if state.state == .error {
                                    Button("Retry") { Task { await matrix.retryThreads(roomID: state.id) } }
                                        .buttonStyle(.textLink).font(m.font(.caption)).help(
                                            state.errorMessage ?? "Retry this conversation")
                                } else if state.state == .unloaded {
                                    Text("Not loaded").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                                } else if state.hasMore {
                                    Button("Load older") { Task { await matrix.loadOlderThreads(roomID: state.id) } }
                                        .buttonStyle(.textLink).font(m.font(.caption)).disabled(feed.isLoading)
                                } else {
                                    Text("Done").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                                }
                            }
                        }
                    }.padding(.top, m.sp8).padding(.leading, m.sp16)
                }.frame(maxHeight: m(Self.historyMaxHeight))
            } label: {
                Text("\(feed.checkedRoomCount) of \(feed.totalRoomCount) conversations").font(m.font(.caption))
                    .foregroundStyle(colors.textSecondary)
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp12).background(colors.raised)
    }

    private func refresh() { Task { await matrix.openThreads(workspaceID: workspaceID) } }
}

struct FeedWorkspacePicker: View {
    private static let maxWidth: CGFloat = 210
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

/// One thread. It reads only its own previews, so a preview that hydrates redraws this row alone.
private struct ThreadFeedRow: View {
    let item: ThreadFeedItem
    let root: ThreadPreview
    let latest: ThreadPreview?
    let matrix: MatrixService
    let onOpen: (ChatMessage) -> Void
    let hydrate: (_ retry: Bool) async -> Void
    @Environment(\.metrics) private var m
    @EnvironmentObject private var appearance: AppearanceStore
    private var colors: AppColors { appearance.colors }
    private var failed: Bool { root.state == .failed || latest?.state == .failed }

    var body: some View {
        let rootMessage = root.shown(item.root)
        Button {
            onOpen(rootMessage)
        } label: {
            VStack(alignment: .leading, spacing: m.sp12) {
                HStack(spacing: m.sp8) {
                    Image(
                        systemName: item.isDirect ? "bubble.left.and.bubble.right" : item.isPrivate ? "lock" : "number"
                    ).font(
                        m.font(.caption))
                    Text(item.roomName).font(m.font(.meta, .semibold)).lineLimit(1)
                    Spacer()
                    Text(item.lastActivityAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                        m.font(.caption)
                    ).foregroundStyle(colors.textSecondary)
                }.foregroundStyle(colors.textSecondary)
                HStack(alignment: .top, spacing: m.sp12) {
                    AvatarView(
                        name: rootMessage.senderName, size: m.avatar, matrix: matrix, source: rootMessage.avatarURL)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(rootMessage.senderName).font(m.font(.secondary, .semibold)).foregroundStyle(
                            colors.textPrimary)
                        previewBody(rootMessage, state: root.state).font(m.font(.body)).foregroundStyle(
                            colors.textBody
                        ).lineLimit(3).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let latest, let snapshot = item.latest {
                    let message = latest.shown(snapshot)
                    HStack(alignment: .top, spacing: m.sp8) {
                        RoundedRectangle(cornerRadius: 1).fill(colors.border).frame(width: 2).padding(
                            .leading, m.sp16)
                        AvatarView(
                            name: message.senderName, size: m.avatarMedium, matrix: matrix, source: message.avatarURL)
                        VStack(alignment: .leading, spacing: m.sp4) {
                            HStack(spacing: m.sp8) {
                                Text(message.senderName).font(m.font(.meta, .semibold))
                                Text("Latest reply").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                            }
                            previewBody(message, state: latest.state).font(m.font(.meta)).foregroundStyle(
                                colors.textSecondary
                            ).lineLimit(2).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: m.sp8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(m.font(.caption))
                    Text(
                        item.replyCount > 0
                            ? "\(item.replyCount) \(item.replyCount == 1 ? "reply" : "replies")" : "Open thread"
                    ).font(m.font(.caption, .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(m.font(.caption, .semibold))
                }.foregroundStyle(colors.accent).padding(.leading, m.avatar + m.sp12)
                if failed {
                    Text("Preview unavailable").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                        .padding(.leading, m.avatar + m.sp12).help(
                            root.error ?? latest?.error ?? "Right-click to retry")
                }
            }.padding(.horizontal, m.sp24).padding(.vertical, m.sp20).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine).accessibilityLabel(
                    "Thread in \(item.roomName), \(rootMessage.senderName), \(Self.preview(rootMessage)), \(item.replyCount) replies"
                )
        }.buttonStyle(.row)
            .task(id: item.id + (item.latest?.eventID ?? "")) { await hydrate(false) }
            .contextMenu {
                if failed { Button("Retry preview") { Task { await hydrate(true) } } }
            }
    }

    @ViewBuilder private func previewBody(_ message: ChatMessage, state: ThreadPreview.State) -> some View {
        if state == .ready {
            NativeMessageBody(
                body: Self.preview(message), formattedBody: message.formattedBody, showsSpoilerControl: false
            ).allowsHitTesting(false)
        } else {
            Text(Self.preview(message))
        }
    }
    private static func preview(_ message: ChatMessage) -> String {
        if message.isRedacted { return "This message was deleted." }
        if message.formattedBody?.localizedCaseInsensitiveContains("data-mx-spoiler") == true {
            return "[Spoiler hidden]"
        }
        return message.body.isEmpty ? message.attachment?.name ?? "Message" : message.body
    }
}
