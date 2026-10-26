import AppKit
import ImageIO
import SwiftUI

struct SharedFilesView: View {
    private static let emptyMinHeight: CGFloat = 260
    private static let roomPickerMaxWidth: CGFloat = 300
    private static let typePickerWidth: CGFloat = 280
    private static let filterMaxWidth: CGFloat = 420
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let service: SharedFilesService
    let workspaceID: String?
    let onOpen: (ChatMessage) -> Void
    let onOpenProfile: (String, ChatUser?) -> Void
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
            if matrix.isPreview {
                EmptyStateView(symbol: "doc.on.doc", title: "Sign in to see shared files")
            } else if roomID == nil {
                EmptyStateView(symbol: "doc.on.doc", title: "No conversations yet")
            } else if service.state == "loading" && service.items.isEmpty {
                SkeletonRows()
            } else {
                ScrollView {
                    LazyVStack(spacing: m.sp12) {
                        if items.isEmpty {
                            EmptyStateView(
                                symbol: filter == .links ? "link" : "doc.on.doc",
                                title: query.isEmpty ? "Nothing shared yet" : "No matches"
                            ).frame(minHeight: m(Self.emptyMinHeight))
                        } else {
                            ForEach(items) { item in
                                let session = matrix.notificationSessionID
                                SharedContentCard(
                                    matrix: matrix, service: service, item: item,
                                    onOpen: { if matrix.notificationSessionID == session { onOpen(item.message) } },
                                    onOpenProfile: onOpenProfile
                                ).id("\(session):\(item.id)")
                            }
                        }
                        if service.hasMore {
                            Button {
                                Task { await service.loadMore() }
                            } label: {
                                HStack(spacing: m.sp8) {
                                    if service.isLoadingMore { DelayedProgress() }
                                    Text(service.isLoadingMore ? "Loading…" : "Load more")
                                }.font(m.font(.meta, .medium)).padding(m.sp12)
                            }.buttonStyle(.textLink).disabled(service.isLoadingMore || service.state == "loading")
                        }
                    }.padding(m.sp24)
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
                guard !matrix.isPreview, let id = roomID else {
                    service.close()
                    return
                }
                selectedRoomID = id
                await service.open(roomID: id)
            }
            .onDisappear { service.close() }
    }
    private var filters: some View {
        VStack(spacing: m.sp16) {
            HStack(spacing: m.sp12) {
                Text("Conversation").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                Picker("Conversation", selection: Binding(get: { roomID ?? "" }, set: { selectedRoomID = $0 })) {
                    ForEach(rooms) { room in Text(room.name).tag(room.id) }
                }.labelsHidden().frame(maxWidth: m(Self.roomPickerMaxWidth), alignment: .leading).disabled(
                    rooms.isEmpty || matrix.isPreview)
                Spacer()
                IconButton(symbol: "arrow.clockwise", label: "Refresh shared files and links", role: .body) {
                    if let id = roomID { Task { await service.open(roomID: id) } }
                }.disabled(service.state == "loading" || service.isLoadingMore || matrix.isPreview || roomID == nil)
            }
            HStack(spacing: m.sp20) {
                Picker("Shared content type", selection: $filter) {
                    ForEach(ContentFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: m(Self.typePickerWidth))
                SearchField(prompt: "Search files and links", text: $query).frame(maxWidth: m(Self.filterMaxWidth))
                Spacer(minLength: 0)
            }
        }.padding(.horizontal, m.sp24).padding(.vertical, m.sp16)
    }
}

private struct SharedContentCard: View {
    private static let thumbnail: CGFloat = 60
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let service: SharedFilesService
    let item: SharedContentItem
    let onOpen: () -> Void
    let onOpenProfile: (String, ChatUser?) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @EnvironmentObject private var previews: AttachmentPreviewController
    @State private var image: NSImage?
    @State private var busy = false
    @State private var error: String?
    @State private var previewBusy = false
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequest = UUID()
    private struct ThumbnailContext: Hashable {
        let session: UUID
        let message: ChatMessage
        let mediaRevision: Data?
    }
    private var colors: AppColors { appearance.colors }
    private var message: ChatMessage { item.message }
    private var canPreview: Bool {
        message.attachment != nil && !message.isRedacted && !matrix.isPreview && !busy && !previewBusy
            && !previews.isLoading
    }
    private var symbol: String {
        switch message.kind {
        case "m.image": "photo"
        case "m.video": "film"
        case "m.audio": "waveform"
        default: message.attachment == nil ? "link" : "doc.text"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: m.sp16) {
            HStack(alignment: .top, spacing: m.sp12) {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: symbol).font(m.font(.header)).foregroundStyle(colors.textSecondary)
                    }
                }.frame(width: m(Self.thumbnail), height: m(Self.thumbnail)).background(
                    colors.canvas, in: RoundedRectangle(cornerRadius: m.radiusLarge)
                )
                .clipShape(RoundedRectangle(cornerRadius: m.radiusLarge))
                VStack(alignment: .leading, spacing: m.sp8) {
                    Text(message.attachment?.name ?? item.links.first?.host ?? "Shared link").font(
                        m.font(.body, .semibold)
                    ).foregroundStyle(colors.textPrimary).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: m.sp8) {
                        Button(message.senderName) {
                            onOpenProfile(
                                message.senderID,
                                ChatUser(id: message.senderID, name: message.senderName, avatarURL: message.avatarURL))
                        }.buttonStyle(.row).help("View profile")
                        Text("·")
                        Text(message.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                        if let size = message.attachment?.size {
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                        }
                        if message.threadRootID != nil {
                            Label("Thread reply", systemImage: "bubble.left.and.bubble.right")
                        }
                    }.font(m.font(.caption)).foregroundStyle(colors.textSecondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if message.attachment != nil {
                    Button(action: preview) {
                        HStack(spacing: m.sp8) {
                            if previewBusy { DelayedProgress() } else { Image(systemName: "eye") }
                            Text(previewBusy ? "Preparing…" : "Preview")
                        }.font(m.font(.meta, .medium)).frame(minHeight: m.iconButton)
                    }.buttonStyle(.row).disabled(!canPreview).help("Open in Quick Look").accessibilityLabel(
                        "Preview \(message.attachment?.name ?? "attachment")")
                    Button(action: download) {
                        if busy {
                            DelayedProgress().frame(width: m.iconButton, height: m.iconButton)
                        } else {
                            Image(systemName: "arrow.down.to.line").font(m.font(.body)).frame(
                                width: m.iconButton, height: m.iconButton)
                        }
                    }.buttonStyle(.row).disabled(busy || previewBusy).help("Download").accessibilityLabel(
                        "Download \(message.attachment?.name ?? "attachment")")
                }
            }
            if !item.links.isEmpty {
                ForEach(item.links, id: \.absoluteString) { link in
                    Link(destination: link) {
                        Label(link.absoluteString, systemImage: "link").font(m.font(.meta)).lineLimit(2)
                            .truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    }.foregroundStyle(colors.accent)
                }
            }
            HStack {
                if let error {
                    Text(error).font(m.font(.caption)).foregroundStyle(colors.warning).fixedSize(
                        horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onOpen) {
                    Label("Open", systemImage: "arrow.up.right").font(m.font(.meta, .medium))
                }.buttonStyle(.row).foregroundStyle(colors.accent)
            }
            if let previewError {
                HStack(alignment: .top, spacing: m.sp12) {
                    Text(previewError).font(m.font(.caption)).foregroundStyle(colors.warning).fixedSize(
                        horizontal: false, vertical: true)
                    Button("Retry", action: preview).buttonStyle(.textLink).font(m.font(.caption)).disabled(
                        !canPreview)
                }
            }
        }.padding(m.sp20).frame(maxWidth: .infinity, alignment: .leading).background(
            colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)
        ).overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
            .task(
                id: ThumbnailContext(
                    session: matrix.notificationSessionID, message: message, mediaRevision: item.mediaRevision)
            ) {
                image = nil
                let session = matrix.notificationSessionID
                guard message.kind == "m.image", let revision = item.mediaRevision else { return }
                do {
                    let data = try await service.thumbnailData(item)
                    let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
                        guard
                            let source = CGImageSourceCreateWithData(
                                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                        else { return nil }
                        return CGImageSourceCreateThumbnailAtIndex(
                            source, 0,
                            [
                                kCGImageSourceCreateThumbnailFromImageAlways: true,
                                kCGImageSourceCreateThumbnailWithTransform: true,
                                kCGImageSourceThumbnailMaxPixelSize: 160, kCGImageSourceShouldCacheImmediately: true,
                            ] as CFDictionary)
                    }.value
                    guard !Task.isCancelled, matrix.notificationSessionID == session,
                        service.items.first(where: { $0.id == item.id })?.mediaRevision == revision
                    else { return }
                    image = decoded.map { NSImage(cgImage: $0, size: .zero) }
                } catch {
                    // Optional; Download still works.
                }
            }
            .onChange(of: item) { _, _ in
                cancelPreview()
                previewError = nil
                error = nil
            }
            .onChange(of: matrix.notificationSessionID) { _, _ in
                cancelPreview()
                image = nil
                previewError = nil
                error = nil
            }
            .onDisappear { cancelPreview() }
    }
    private func preview() {
        guard canPreview else { return }
        let session = matrix.notificationSessionID
        let target = item
        let token = UUID()
        previewRequest = token
        previewBusy = true
        previewError = nil
        previewTask = Task { @MainActor in
            defer {
                if previewRequest == token {
                    previewBusy = false
                    previewTask = nil
                }
            }
            do {
                try await previews.show(sessionID: session) { try await service.preparePreview(target) }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, previewRequest == token, matrix.notificationSessionID == session else {
                    return
                }
                previewError = MatrixService.safeError(error)
            }
        }
    }
    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewRequest = UUID()
        previewBusy = false
    }
    private func download() {
        guard message.attachment != nil, !busy else { return }
        let session = matrix.notificationSessionID
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.filename ?? "attachment"
        panel.title = "Save attachment"
        guard let window = NSApp.windows.first(where: { $0.frameAutosaveName == "SlatrixMainWindow" }) else { return }
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let destination = panel.url, matrix.notificationSessionID == session else { return }
            busy = true
            error = nil
            Task {
                defer { busy = false }
                do {
                    try await service.saveAttachment(item, to: destination)
                    guard matrix.notificationSessionID == session, !Task.isCancelled else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([destination])
                } catch is CancellationError {} catch {
                    if matrix.notificationSessionID == session { self.error = MatrixService.safeError(error) }
                }
            }
        }
    }
}
