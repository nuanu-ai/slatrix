import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Slack-parity Forward modal: searchable destination picker (recent-first, with channel icons & DM avatars),
/// optional accompanying message ("Add a message, if you’d like…"), and a rich preview card of the forwarded item.
struct ForwardMessageView: View {
    private static let destinationListHeight: CGFloat = 176
    private static let imagePreviewHeight: CGFloat = 200
    private static let previewHeight: CGFloat = 148
    private static let imageMaxSize = CGSize(width: 440, height: 140)
    private static let fileTile: CGFloat = 44
    private enum Field: Hashable { case search, note }

    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let target: MessageActionTarget
    var visited: [String] = []
    var onForwarded: ((ChatRoom) -> Void)? = nil
    let onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @FocusState private var focused: Field?
    @State private var review: ForwardMessageReview?
    @State private var query = ""
    @State private var selection = 0
    @State private var destinationID = ""
    @State private var note = ""
    @State private var loading = false
    @State private var sending = false
    @State private var error: String?
    @State private var notice: String?
    @State private var queued: ForwardMessageQueuedResult?
    @State private var presented = true
    @State private var request = UUID()
    @State private var thumbnail: NSImage?

    private struct ThumbnailContext: Hashable {
        let session: UUID
        let reviewID: UUID?
        let source: Data?
        let queued: Bool
    }
    private var thumbnailContext: ThumbnailContext {
        ThumbnailContext(
            session: matrix.notificationSessionID, reviewID: review?.id,
            source: review.flatMap { matrix.attachmentSourceRevision($0.message) }, queued: queued != nil)
    }

    private var current: Bool { presented && matrix.isCurrentMessageAction(target) }
    private var destinations: [ChatRoom] {
        let fromEncrypted = matrix.rooms.first { $0.id == target.message.roomID }?.isEncrypted != false
        return matrix.rooms.filter { $0.membership == "join" && ($0.isEncrypted || !fromEncrypted) && !$0.isSpace }
    }
    private var filteredDestinations: [ChatRoom] {
        ConversationSwitcher.results(destinations, query: query, visited: visited)
    }
    private var selectedDestination: ChatRoom? {
        destinations.first { $0.id == destinationID }
    }
    private var canSend: Bool {
        current && review != nil && !loading && !sending && queued == nil && selectedDestination != nil
    }
    private var colors: AppColors { appearance.colors }

    var body: some View {
        Modal(
            title: "Forward message", size: .medium, busy: sending, onClose: onClose,
            secondary: ModalAction("Cancel", action: onClose),
            primary: ModalAction(
                "Forward", disabled: !canSend, shortcut: KeyboardShortcut(.return, modifiers: .command), action: send)
        ) {
            destinationPicker
            noteField
            if let notice {
                Text(notice).font(m.font(.subheadline)).foregroundStyle(colors.accent).fixedSize(
                    horizontal: false, vertical: true)
            }
            if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
            if review == nil && !loading && error != nil {
                Button("Reload") { Task { await loadReview() } }.buttonStyle(.textLink).disabled(sending || !current)
            }
            previewSection
        }
        .onAppear { focused = .search }
        .onChange(of: query) { _, _ in selection = 0 }
        .task(id: matrix.forwardMessageSourceRevision(target)) { await loadReview() }
        .task(id: thumbnailContext) { await loadThumbnail() }
        .onChange(of: thumbnailContext) { _, _ in thumbnail = nil }
        .onDisappear {
            presented = false
            request = UUID()
            thumbnail = nil
        }
    }

    @ViewBuilder private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: m.sp8) {
            if let room = selectedDestination {
                HStack(spacing: m.sp8) {
                    RoomIcon(room: room, matrix: matrix, size: m.avatarSmall)
                        .foregroundStyle(colors.textSecondary)
                    Text(room.name).font(m.font(.body, .medium)).foregroundStyle(colors.textPrimary).lineLimit(1)
                    if let detail = conversationDetail(room, matrix) {
                        Text(detail).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    IconButton(symbol: "xmark.circle.fill", label: "Change destination", role: .body, side: 20) {
                        destinationID = ""
                        query = ""
                        selection = 0
                        focused = .search
                    }.foregroundStyle(colors.textTertiary).disabled(sending)
                }
                .padding(.horizontal, m.sp12).frame(minHeight: m.control)
                .background(colors.control, in: RoundedRectangle(cornerRadius: m.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: m.radius).strokeBorder(colors.borderStrong, lineWidth: 0.5)
                }
            } else {
                FieldChrome(focused: focused == .search) {
                    HStack(spacing: m.sp8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(colors.textSecondary)
                            .accessibilityHidden(true)
                        TextField("Add by name or channel", text: $query)
                            .focused($focused, equals: .search)
                            .onKeyPress(.upArrow) { moveSelection(-1) }
                            .onKeyPress(.downArrow) { moveSelection(1) }
                            .onSubmit {
                                let matches = filteredDestinations
                                if matches.indices.contains(selection) { selectDestination(matches[selection]) }
                            }
                        if !query.isEmpty {
                            IconButton(symbol: "xmark.circle.fill", label: "Clear search", role: .body, side: 20) {
                                query = ""
                            }.foregroundStyle(colors.textTertiary)
                        }
                    }
                }.disabled(sending || !current)

                let matches = filteredDestinations
                if destinations.isEmpty {
                    Text("No conversations to forward to.").font(m.font(.subheadline)).foregroundStyle(
                        colors.textSecondary)
                } else if matches.isEmpty {
                    Text("No matching conversations").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                        .padding(.horizontal, m.sp4)
                } else {
                    let visible = Array(matches.prefix(40))
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: m.sp2) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, room in
                                    MenuRow(
                                        title: room.name, detail: conversationDetail(room, matrix),
                                        selected: index == selection
                                    ) {
                                        selectDestination(room)
                                    } icon: {
                                        RoomIcon(room: room, matrix: matrix, size: m.avatarSmall)
                                            .foregroundStyle(colors.textSecondary)
                                    }.id(room.id)
                                }
                            }.padding(m.sp4)
                        }
                        .onChange(of: selection) { _, index in
                            if visible.indices.contains(index) { proxy.scrollTo(visible[index].id) }
                        }
                    }
                    .frame(maxHeight: m(Self.destinationListHeight))
                    .background(colors.canvas, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                    .overlay {
                        RoundedRectangle(cornerRadius: m.radiusLarge).strokeBorder(colors.border, lineWidth: 0.5)
                    }
                    .disabled(sending || !current)
                }
            }
        }
    }

    private var noteField: some View {
        let shape = RoundedRectangle(cornerRadius: m.radius)
        let isFocused = focused == .note
        return TextField("Add a message, if you’d like…", text: $note, axis: .vertical)
            .textFieldStyle(.plain)
            .font(m.font(.reading))
            .foregroundStyle(colors.textPrimary)
            .lineLimit(2...5)
            .focused($focused, equals: .note)
            .disabled(sending || !current)
            .padding(.horizontal, m.sp12).padding(.vertical, m.sp8)
            .background(colors.control, in: shape)
            .overlay(
                shape.strokeBorder(
                    isFocused ? colors.accentFill : colors.borderStrong, lineWidth: isFocused ? 1 : 0.5)
            )
            .accessibilityLabel("Optional message")
    }

    @ViewBuilder private var previewSection: some View {
        if let review {
            let sourceRoom = matrix.rooms.first { $0.id == review.message.roomID }
            let cardShape = RoundedRectangle(cornerRadius: m.radiusLarge)
            HStack(alignment: .top, spacing: m.sp12) {
                RoundedRectangle(cornerRadius: m(1.5)).fill(colors.borderStrong).frame(width: m(3))
                VStack(alignment: .leading, spacing: m.sp8) {
                    HStack(spacing: m.sp8) {
                        AvatarView(
                            name: review.message.senderName, size: m.avatarSmall, matrix: matrix,
                            source: review.message.avatarURL)
                        Text(review.message.senderName).font(m.font(.body, .semibold))
                            .foregroundStyle(colors.textPrimary).lineLimit(1)
                        Text("·").font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                        Text(
                            sourceRoom.map { $0.isDirect ? $0.name : "#\($0.name)" } ?? review.message.roomID
                        ).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary).lineLimit(1)
                        Spacer(minLength: m.sp4)
                        Text(LatestMessage(body: nil, timestamp: review.message.timestamp, isOwn: false).time())
                            .font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                    }
                    ScrollView { messagePreview(review).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(
                            maxHeight: m(
                                review.message.kind == "m.image" ? Self.imagePreviewHeight : Self.previewHeight))
                }
            }
            .padding(m.sp12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surfaceCard, in: cardShape)
            .overlay { cardShape.strokeBorder(colors.border, lineWidth: 0.5) }
        } else if loading {
            HStack {
                Spacer(minLength: 0)
                DelayedProgress(interval: .sheetLoading).accessibilityLabel("Preparing message")
                Spacer(minLength: 0)
            }.padding(.vertical, m.sp16)
        }
    }

    private func selectDestination(_ room: ChatRoom) {
        destinationID = room.id
        error = nil
        focused = .note
    }

    private func moveSelection(_ step: Int) -> KeyPress.Result {
        let count = min(filteredDestinations.count, 40)
        guard count > 0 else { return .ignored }
        selection = (selection + step + count) % count
        return .handled
    }

    @ViewBuilder private func messagePreview(_ review: ForwardMessageReview) -> some View {
        switch review.value {
        case .image(let image):
            VStack(alignment: .leading, spacing: m.sp8) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: m(min(Self.imageMaxSize.width, max(1, thumbnail.size.width))),
                            maxHeight: m(Self.imageMaxSize.height)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: m.radius)).accessibilityLabel(
                            "Image preview: \(image.filename)")
                }
                attachmentCard(
                    filename: image.filename, mimeType: image.info?.mimetype, size: image.info?.size,
                    symbol: "photo", fallbackType: "Image")
                if let caption = image.caption, !caption.isEmpty {
                    NativeMessageBody(body: caption, formattedBody: review.message.formattedBody)
                }
            }
        case .file(let file):
            VStack(alignment: .leading, spacing: m.sp8) {
                attachmentCard(
                    filename: file.filename, mimeType: file.info?.mimetype, size: file.info?.size, symbol: "doc.text",
                    fallbackType: "File")
                if let caption = file.caption, !caption.isEmpty {
                    NativeMessageBody(body: caption, formattedBody: review.message.formattedBody)
                }
            }
        case .video(let video):
            VStack(alignment: .leading, spacing: m.sp8) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: m(min(Self.imageMaxSize.width, max(1, thumbnail.size.width))),
                            maxHeight: m(Self.imageMaxSize.height)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: m.radius)).accessibilityLabel(
                            "Video preview: \(video.filename)")
                }
                attachmentCard(
                    filename: video.filename, mimeType: video.info?.mimetype, size: video.info?.size,
                    symbol: "film", fallbackType: "Video")
                if let caption = video.caption, !caption.isEmpty {
                    NativeMessageBody(body: caption, formattedBody: review.message.formattedBody)
                }
            }
        case .audio(let audio):
            VStack(alignment: .leading, spacing: m.sp8) {
                attachmentCard(
                    filename: audio.filename, mimeType: audio.info?.mimetype, size: audio.info?.size,
                    symbol: "waveform", fallbackType: "Audio")
                if let caption = audio.caption, !caption.isEmpty {
                    NativeMessageBody(body: caption, formattedBody: review.message.formattedBody)
                }
            }
        case .text, .notice, .emote:
            NativeMessageBody(body: review.message.body, formattedBody: review.message.formattedBody)
        }
    }

    private func attachmentCard(
        filename: String, mimeType: String?, size: UInt64?, symbol: String, fallbackType: String
    ) -> some View {
        HStack(alignment: .center, spacing: m.sp12) {
            Image(systemName: symbol)
                .font(m.font(.title2)).foregroundStyle(colors.accent)
                .frame(width: m(Self.fileTile), height: m(Self.fileTile))
                .background(colors.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: m.radius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: m.sp2) {
                Text(filename).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                    .lineLimit(2).textSelection(.enabled).help(filename)
                HStack(spacing: m.sp8) {
                    Text(attachmentType(filename: filename, mimeType: mimeType, fallback: fallbackType))
                    if let size {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                    }
                }.font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
            }
            Spacer(minLength: 0)
        }.padding(m.sp12).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.canvas, in: RoundedRectangle(cornerRadius: m.radius))
            .overlay(RoundedRectangle(cornerRadius: m.radius).strokeBorder(colors.border, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
    }

    private func attachmentType(filename: String, mimeType: String?, fallback: String) -> String {
        let type =
            mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (filename as NSString).pathExtension)
        if let type, type != .data, let description = type.localizedDescription { return description }
        return fallback
    }

    @MainActor private func loadThumbnail() async {
        thumbnail = nil
        guard current, !matrix.isPreview, queued == nil, let captured = review,
            let source = matrix.attachmentSourceRevision(captured.message)
        else { return }
        switch captured.value {
        case .image, .video: break
        default: return
        }
        let session = matrix.notificationSessionID
        @MainActor func isCurrentThumbnail() -> Bool {
            !Task.isCancelled && current && queued == nil && matrix.notificationSessionID == session
                && review?.id == captured.id && review?.value == captured.value
                && matrix.attachmentSourceRevision(captured.message) == source
        }
        do {
            let data = try await matrix.thumbnailData(captured.message, width: 880, height: 280)
            guard isCurrentThumbnail() else { return }
            let image = await Task.detached(priority: .utility) {
                MediaImageDecoder.decodeStill(data, maxPixels: 880)
            }.value
            guard isCurrentThumbnail(), let image else { return }
            thumbnail = NSImage(cgImage: image, size: .zero)
        } catch {
            // Optional preview: keep the reviewed metadata and forwarding action available.
        }
    }

    @MainActor private func loadReview() async {
        guard !Task.isCancelled, current, !sending, queued == nil else { return }
        let token = UUID()
        let previous = review
        request = token
        loading = true
        review = nil
        error = nil
        defer { if request == token { loading = false } }
        do {
            let fresh = try await matrix.loadForwardMessage(target)
            guard !Task.isCancelled, request == token, current, !sending, queued == nil else { return }
            review = previous?.value == fresh.value ? previous : fresh
            if let previous, previous.value != fresh.value {
                notice = "The message changed. Check it, then forward."
            }
        } catch is CancellationError {
            guard !Task.isCancelled, request == token, current, !sending, queued == nil else { return }
            error = "This message is no longer here. Forward it again from the conversation."
        } catch {
            guard !Task.isCancelled, request == token, current, !sending, queued == nil else { return }
            self.error = MatrixService.safeError(error)
        }
    }

    @MainActor private func send() {
        guard canSend, let submitted = review, let room = selectedDestination else { return }
        let destination = room.id
        let messageNote = note
        let token = UUID()
        request = token
        sending = true
        error = nil
        notice = nil
        Task { @MainActor in
            guard current, request == token else {
                sending = false
                return
            }
            do {
                let accepted = try await matrix.forwardMessage(submitted, to: destination, note: messageNote)
                // Record the send first so a retry is never offered for it.
                queued = accepted
                sending = false
                onForwarded?(room)
                onClose()
            } catch let changed as ForwardMessageReviewChanged {
                guard current, request == token else { return }
                review = changed.review
                notice = changed.localizedDescription
                sending = false
            } catch is CancellationError {
                guard current, request == token else { return }
                sending = false
                review = nil
                error = "The message changed. Reload it, then forward."
            } catch {
                guard current, request == token else { return }
                sending = false
                self.error = MatrixService.safeError(error)
            }
        }
    }
}
