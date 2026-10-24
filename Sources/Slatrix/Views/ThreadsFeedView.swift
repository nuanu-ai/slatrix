import SwiftUI

struct ThreadsFeedView: View {
    private static let historyMaxHeight: CGFloat = 144
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @ObservedObject var feed: ThreadFeedService
    @Binding var workspaceID: String?
    var onOpen: (ChatMessage) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var coverageExpanded = false
    private var colors: AppColors { appearance.colors }
    private var items: [ThreadFeedItem] {
        feed.items.sorted {
            $0.lastActivityAt == $1.lastActivityAt ? $0.id < $1.id : $0.lastActivityAt > $1.lastActivityAt
        }
    }
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
                    Button("Retry", action: refresh).buttonStyle(.link).font(m.font(.meta)).padding(.trailing, m.sp20)
                }.disabled(feed.isLoading)
            }
            if items.isEmpty {
                if feed.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "No threads yet") {
                        if feed.canCheckMore { Button("Look further") { Task { await matrix.checkMoreThreads() } } }
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button {
                                onOpen(item.root)
                            } label: {
                                threadRow(item)
                            }.buttonStyle(.row)
                                .task(id: item.id + (item.latest?.eventID ?? "")) { await feed.hydratePreview(item) }
                                .contextMenu {
                                    if item.rootPreviewState == .failed || item.latestPreviewState == .failed {
                                        Button("Retry preview") {
                                            Task { await feed.hydratePreview(item, retry: true) }
                                        }
                                    }
                                }
                            Divider().overlay(colors.border).padding(.leading, m.sp24 + m.avatar + m.sp12)
                        }
                        if feed.isLoading {
                            ProgressView().controlSize(.small).padding(m.sp20).accessibilityLabel(
                                "Checking more threads")
                        }
                    }.padding(.horizontal, m.sp2)
                }
            }
            coverage
        }.background(colors.canvas)
            .task(id: workspaceID) { await matrix.openThreads(workspaceID: workspaceID) }
            .onDisappear { matrix.closeThreads() }
    }

    private func threadRow(_ item: ThreadFeedItem) -> some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            HStack(spacing: m.sp8) {
                Image(
                    systemName: matrix.rooms.first(where: { $0.id == item.roomID })?.isDirect == true
                        ? "bubble.left.and.bubble.right" : "number"
                ).font(m.font(.caption))
                Text(item.roomName).font(m.font(.meta, .semibold)).lineLimit(1)
                Spacer()
                Text(item.lastActivityAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                    m.font(.caption)
                ).foregroundStyle(colors.muted)
            }.foregroundStyle(colors.muted)
            HStack(alignment: .top, spacing: m.sp12) {
                AvatarView(name: item.root.senderName, size: m.avatar, matrix: matrix, source: item.root.avatarURL)
                VStack(alignment: .leading, spacing: m.sp4) {
                    Text(item.root.senderName).font(m.font(.secondary, .semibold)).foregroundStyle(
                        colors.primaryText)
                    previewBody(item.root, state: item.rootPreviewState).font(
                        m.font(.body)
                    ).foregroundStyle(colors.text).lineLimit(3).multilineTextAlignment(.leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let latest = item.latest, latest.eventID != item.root.eventID {
                HStack(alignment: .top, spacing: m.sp8) {
                    RoundedRectangle(cornerRadius: 1).fill(colors.border).frame(width: 2).padding(.leading, m.sp16)
                    AvatarView(name: latest.senderName, size: m.avatarMedium, matrix: matrix, source: latest.avatarURL)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        HStack(spacing: m.sp8) {
                            Text(latest.senderName).font(m.font(.meta, .semibold))
                            Text("Latest reply").font(m.font(.caption)).foregroundStyle(colors.muted)
                        }
                        previewBody(latest, state: item.latestPreviewState).font(m.font(.meta)).foregroundStyle(
                            colors.muted
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
            if item.rootPreviewState == .failed || item.latestPreviewState == .failed {
                Text("Preview unavailable").font(m.font(.caption)).foregroundStyle(colors.muted)
                    .padding(.leading, m.avatar + m.sp12).help(item.previewError ?? "Right-click to retry")
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp20).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(
                Rectangle()
            )
            .accessibilityElement(children: .combine).accessibilityLabel(
                "Thread in \(item.roomName), \(item.root.senderName), \(threadPreview(item.root)), \(item.replyCount) replies"
            )
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: m.sp12) {
            HStack(alignment: .center) {
                if failedRoomCount > 0 {
                    Button("\(failedRoomCount) couldn’t load") { coverageExpanded = true }.buttonStyle(.link).font(
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
                                    ProgressView().controlSize(.mini)
                                } else if state.state == .error {
                                    Button("Retry") { Task { await matrix.retryThreads(roomID: state.id) } }
                                        .buttonStyle(.link).font(m.font(.caption)).help(
                                            state.errorMessage ?? "Retry this conversation")
                                } else if state.state == .unloaded {
                                    Text("Not loaded").font(m.font(.caption)).foregroundStyle(colors.muted)
                                } else if state.hasMore {
                                    Button("Load older") { Task { await matrix.loadOlderThreads(roomID: state.id) } }
                                        .buttonStyle(.link).font(m.font(.caption)).disabled(feed.isLoading)
                                } else {
                                    Text("Done").font(m.font(.caption)).foregroundStyle(colors.muted)
                                }
                            }
                        }
                    }.padding(.top, m.sp8).padding(.leading, m.sp16)
                }.frame(maxHeight: m(Self.historyMaxHeight))
            } label: {
                Text("\(feed.checkedRoomCount) of \(feed.totalRoomCount) conversations").font(m.font(.caption))
                    .foregroundStyle(colors.muted)
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp12).background(colors.raised)
    }

    private func refresh() { Task { await matrix.openThreads(workspaceID: workspaceID) } }
    @ViewBuilder private func previewBody(_ message: ChatMessage, state: ThreadFeedItem.PreviewState) -> some View {
        if state == .ready {
            NativeMessageBody(
                body: threadPreview(message), formattedBody: message.formattedBody, showsSpoilerControl: false
            ).allowsHitTesting(false)
        } else {
            Text(threadPreview(message))
        }
    }
    private func threadPreview(_ message: ChatMessage) -> String {
        if message.isRedacted { return "This message was deleted." }
        if message.formattedBody?.localizedCaseInsensitiveContains("data-mx-spoiler") == true {
            return "[Spoiler hidden]"
        }
        return message.body.isEmpty ? message.attachment?.name ?? "Message" : message.body
    }
}

struct FeedWorkspacePicker: View {
    private static let maxWidth: CGFloat = 210
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    @Binding var workspaceID: String?
    var body: some View {
        Picker("Workspace", selection: $workspaceID) {
            Text("All conversations").tag(Optional<String>.none)
            ForEach(matrix.workspaces) { Text($0.name).tag(Optional($0.id)) }
        }.labelsHidden().pickerStyle(.menu).frame(maxWidth: m(Self.maxWidth)).accessibilityLabel("Filter by workspace")
    }
}
