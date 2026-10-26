import AppKit
import SwiftUI

struct SharedFilesView: View {
    private static let emptyMinHeight: CGFloat = 260
    private static let filterMaxWidth: CGFloat = 420
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let service: SharedFilesService
    let workspaceID: String?
    /// Goes to the message in its conversation.
    let onOpen: (ChatMessage) -> Void
    /// Opens a file in the viewer, which steps through the list's files in order.
    let onOpenMedia: (ChatMessage, [ChatMessage]) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var selectedRoomID = ""
    @State private var query = ""
    @State private var filter = ContentFilter.all
    private enum ContentFilter: String, CaseIterable {
        case all = "All"
        case files = "Files"
        case images = "Images"
        case links = "Links"
    }
    private struct Scope: Hashable {
        let session: UUID
        let roomID: String?
        let preview: Bool
    }
    private var colors: AppColors { appearance.colors }
    private var rooms: [ChatRoom] {
        matrix.rooms.filter {
            !$0.isSpace && $0.membership == "join"
                && ($0.isDirect || workspaceID == nil || $0.spaceIDs.contains(workspaceID!))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var roomID: String? {
        if rooms.contains(where: { $0.id == selectedRoomID }) { return selectedRoomID }
        if let current = matrix.selectedRoomID, rooms.contains(where: { $0.id == current }) { return current }
        return rooms.first?.id
    }
    private var items: [SharedContentItem] {
        guard service.roomID == roomID else { return [] }
        let text = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
        return service.items.filter { item in
            let matchesType: Bool
            switch filter {
            case .all: matchesType = true
            case .files: matchesType = item.message.attachment != nil
            case .images: matchesType = item.message.kind == "m.image"
            case .links: matchesType = !item.links.isEmpty
            }
            guard matchesType else { return false }
            return text.isEmpty || (item.message.attachment?.name ?? "").localizedCaseInsensitiveContains(text)
                || item.message.senderName.localizedCaseInsensitiveContains(text)
                || String(item.message.body.prefix(4_096)).localizedCaseInsensitiveContains(text)
                || item.links.contains { $0.absoluteString.localizedCaseInsensitiveContains(text) }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            filters
            Divider().overlay(colors.border)
            if let error = service.errorMessage {
                HStack {
                    InlineErrorView(message: error)
                    Button("Retry") { Task { await service.retry() } }.buttonStyle(.textLink).padding(.trailing, m.sp20)
                        .disabled(service.state == "loading" || service.isLoadingMore)
                }
            }
            if roomID == nil {
                EmptyStateView(symbol: "doc.on.doc", title: "No conversations yet")
            } else if service.state == "loading" && service.items.isEmpty {
                SkeletonRows()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if items.isEmpty {
                            EmptyStateView(
                                symbol: filter == .links ? "link" : "doc.on.doc",
                                title: query.isEmpty ? "Nothing shared yet" : "No matches"
                            ).frame(minHeight: m(Self.emptyMinHeight))
                        } else {
                            let shown = items
                            ForEach(shown) { item in
                                let session = matrix.notificationSessionID
                                SharedFileRow(
                                    matrix: matrix, item: item,
                                    onOpen: {
                                        guard matrix.notificationSessionID == session else { return }
                                        onOpenMedia(item.message, shown.map(\.message))
                                    },
                                    onOpenMessage: {
                                        if matrix.notificationSessionID == session { onOpen(item.message) }
                                    }
                                ).id("\(session):\(item.id)")
                            }
                        }
                        if service.hasMore {
                            Button {
                                Task { await service.loadMore() }
                            } label: {
                                HStack(spacing: m.sp8) {
                                    if service.isLoadingMore { DelayedProgress() }
                                    Text("Load more")
                                }.font(m.font(.meta, .medium)).padding(m.sp12)
                            }.buttonStyle(.textLink).disabled(service.isLoadingMore || service.state == "loading")
                        }
                    }.padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
                }
                if service.unavailableEncryptedCount > 0 {
                    HStack {
                        Label("\(service.unavailableEncryptedCount) locked", systemImage: "lock")
                        Spacer(minLength: 0)
                    }.font(m.font(.caption)).foregroundStyle(colors.textSecondary).padding(.horizontal, m.sp24).padding(
                        .vertical, m.sp12
                    )
                    .background(colors.raised)
                }
            }
        }.background(colors.canvas)
            .task(id: Scope(session: matrix.notificationSessionID, roomID: roomID, preview: matrix.isPreview)) {
                guard let id = roomID else {
                    service.close()
                    return
                }
                selectedRoomID = id
                if matrix.isPreview {
                    service.openPreview(
                        roomID: id,
                        messages: id == PreviewMedia.roomID
                            ? PreviewMedia.messages(roomID: id, members: matrix.members, now: .now) : [])
                } else {
                    await service.open(roomID: id)
                }
            }
            .onDisappear { service.close() }
    }
    private var filters: some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp12) {
                SearchField(prompt: "Search files and links", text: $query).frame(maxWidth: m(Self.filterMaxWidth))
                conversationMenu
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: "Refresh shared files and links", role: .body) {
                    if let id = roomID { Task { await service.open(roomID: id) } }
                }.disabled(service.state == "loading" || service.isLoadingMore || matrix.isPreview || roomID == nil)
            }.padding(.vertical, m.sp16)
            TabBar(tabs: ContentFilter.allCases.map { .init(value: $0, title: $0.rawValue) }, selection: $filter)
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, m.sp24)
    }

    /// Slack's "In: #design" filter: which conversation's files the list shows.
    private var conversationMenu: some View {
        let room = rooms.first { $0.id == roomID }
        return Menu {
            Picker("Conversation", selection: Binding(get: { roomID ?? "" }, set: { selectedRoomID = $0 })) {
                ForEach(rooms) { Text(Self.title($0)).tag($0.id) }
            }.pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: m.sp4) {
                Text("In: \(room.map(Self.title) ?? "")").lineLimit(1)
                Image(systemName: "chevron.down").font(m.font(.caption, .semibold))
            }.font(m.font(.secondary, .medium))
        }
        .menuStyle(.button).buttonStyle(.secondary).menuIndicator(.hidden).fixedSize()
        .disabled(rooms.isEmpty).accessibilityLabel("Conversation")
    }

    private static func title(_ room: ChatRoom) -> String { room.isDirect ? room.name : "#" + room.name }
}

/// A row of the Files list: a file, image or video opens in the viewer, a link in the browser.
private struct SharedFileRow: View {
    @Environment(\.openURL) private var openURL
    let matrix: MatrixService
    let item: SharedContentItem
    let onOpen: () -> Void
    let onOpenMessage: () -> Void
    @State private var still: CGImage?
    @State private var stillFailed = false
    @State private var downloading = false
    private var message: ChatMessage { item.message }

    var body: some View {
        let link = message.attachment == nil ? item.links.first : nil
        FileRow(
            tile: tile, name: message.attachment?.name ?? link?.absoluteString ?? "",
            caption: SharedContentMapping.caption(
                sender: message.senderName, room: matrix.rooms.first { $0.id == message.roomID },
                date: message.timestamp),
            downloading: downloading, onDownload: link == nil ? download : nil,
            onOpen: { if let link { openURL(link) } else { onOpen() } }
        ) {
            if let link {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            } else {
                AttachmentMenuItems(
                    matrix: matrix, message: message,
                    copyLink: matrix.isPreview ? nil : { copyFilesLink(item, matrix: matrix) })
            }
            Button("View in conversation", action: onOpenMessage)
        }
        .task(id: item) {
            // An edit keeps the row but may replace its file.
            still = nil
            stillFailed = false
            guard message.isViewerMedia, matrix.cachedMediaImage(message) == nil else { return }
            still = await matrix.loadMediaImage(message)
            stillFailed = still == nil && !Task.isCancelled
        }
    }

    private var tile: FileRowTile {
        guard let attachment = message.attachment else { return .link }
        guard message.isViewerMedia, !stillFailed else { return .file(attachment.fileKind) }
        return .thumbnail(still ?? matrix.cachedMediaImage(message))
    }

    private func download() {
        downloading = true
        Task {
            await AttachmentFiles.shared.download(message, matrix: matrix)
            downloading = false
        }
    }
}

/// Copies a Files row's permalink; a failure lands in the window's error toast.
@MainActor func copyFilesLink(_ item: SharedContentItem, matrix: MatrixService) {
    let session = matrix.notificationSessionID
    Task {
        do {
            let link = try await matrix.sharedFiles.permalink(item)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        } catch is CancellationError {} catch {
            if matrix.notificationSessionID == session { matrix.errorMessage = MatrixService.safeError(error) }
        }
    }
}
