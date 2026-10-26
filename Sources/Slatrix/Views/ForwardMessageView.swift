import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ForwardMessageView: View {
    private static let width: CGFloat = 540
    private static let imagePreviewHeight: CGFloat = 300
    private static let previewHeight: CGFloat = 212
    private static let imageMaxSize = CGSize(width: 460, height: 160)
    private static let fileTile: CGFloat = 48
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let target: MessageActionTarget
    let onClose: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var review: ForwardMessageReview?
    @State private var destinationID = ""
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
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var canSend: Bool {
        current && review != nil && !loading && !sending && queued == nil
            && destinations.contains { $0.id == destinationID }
    }
    private var colors: AppColors { appearance.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp20) {
            HStack(alignment: .top) {
                Text("Forward message").font(m.font(.header, .bold)).foregroundStyle(colors.textPrimary)
                Spacer(minLength: m.sp8)
                IconButton(symbol: "xmark", label: "Close forwarding", role: .body, action: onClose).disabled(sending)
            }
            if let queued {
                Label(
                    "Forwarded to \(matrix.rooms.first(where: { $0.id == queued.destinationRoomID })?.name ?? queued.destinationRoomID)",
                    systemImage: "checkmark.circle"
                ).foregroundStyle(colors.success)
                HStack {
                    Spacer()
                    Button("Done", action: onClose).keyboardShortcut(.defaultAction)
                }
            } else {
                if loading {
                    HStack(spacing: m.sp8) {
                        DelayedProgress(interval: .sheetLoading)
                        Text("Loading…").font(m.font(.meta))
                    }
                }
                if let review {
                    VStack(alignment: .leading, spacing: m.sp8) {
                        Text(
                            "From \(matrix.rooms.first(where: { $0.id == review.message.roomID })?.name ?? review.message.roomID)"
                        )
                        .font(m.font(.meta, .semibold)).foregroundStyle(colors.textSecondary)
                        Text(review.message.senderName).font(m.font(.meta, .semibold))
                        ScrollView { messagePreview(review).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(
                                maxHeight: m(
                                    review.message.kind == "m.image" ? Self.imagePreviewHeight : Self.previewHeight))
                    }.padding(m.sp16).frame(maxWidth: .infinity, alignment: .leading).background(
                        colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge))
                }
                if let notice {
                    Text(notice).font(m.font(.meta)).foregroundStyle(colors.accent).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let error { InlineErrorView(message: error).clipShape(RoundedRectangle(cornerRadius: m.radius)) }
                if review == nil && !loading && error != nil {
                    Button("Reload") { Task { await loadReview() } }.buttonStyle(.textLink).disabled(
                        sending || !current)
                }
                Picker("Destination", selection: $destinationID) {
                    Text("Choose a conversation").tag("")
                    ForEach(destinations) { room in Text(room.name).tag(room.id) }
                }.disabled(sending || loading || !current)
                if destinations.isEmpty {
                    Text("No conversations to forward to.").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                }
                HStack {
                    Button("Cancel", action: onClose).keyboardShortcut(.cancelAction).disabled(sending)
                    Spacer()
                    if sending { DelayedProgress() }
                    Button(sending ? "Forwarding…" : "Forward", action: send).buttonStyle(.primary)
                        .disabled(!canSend)
                }
            }
        }.padding(m.sp24).sheetSize(width: Self.width).background(colors.canvas).foregroundStyle(colors.textBody)
            .interactiveDismissDisabled(sending)
            .task(id: matrix.forwardMessageSourceRevision(target)) { await loadReview() }
            .task(id: thumbnailContext) { await loadThumbnail() }
            .onChange(of: thumbnailContext) { _, _ in thumbnail = nil }
            .onDisappear {
                presented = false
                request = UUID()
                thumbnail = nil
            }
            .onExitCommand { if !sending { onClose() } }
    }

    @ViewBuilder private func messagePreview(_ review: ForwardMessageReview) -> some View {
        switch review.value {
        case .image(let image):
            VStack(alignment: .leading, spacing: m.sp12) {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: m(min(Self.imageMaxSize.width, max(1, thumbnail.size.width))),
                            maxHeight: m(Self.imageMaxSize.height)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: m.radiusLarge)).accessibilityLabel(
                            "Image preview: \(image.filename)")
                }
                attachmentCard(
                    filename: image.filename, mimeType: image.info?.mimetype, size: image.info?.size, image: true)
                if let caption = image.caption, !caption.isEmpty {
                    NativeMessageBody(body: caption, formattedBody: review.message.formattedBody)
                }
            }
        case .file(let file):
            VStack(alignment: .leading, spacing: m.sp12) {
                attachmentCard(
                    filename: file.filename, mimeType: file.info?.mimetype, size: file.info?.size, image: false)
                if let caption = file.caption, !caption.isEmpty {
                    NativeMessageBody(body: caption, formattedBody: review.message.formattedBody)
                }
            }
        case .text, .notice, .emote:
            NativeMessageBody(body: review.message.body, formattedBody: review.message.formattedBody)
        }
    }

    private func attachmentCard(filename: String, mimeType: String?, size: UInt64?, image: Bool) -> some View {
        HStack(alignment: .center, spacing: m.sp12) {
            Image(systemName: image ? "photo" : "doc.text")
                .font(m.font(.header)).foregroundStyle(colors.accent)
                .frame(width: m(Self.fileTile), height: m(Self.fileTile))
                .background(colors.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: m.radiusLarge))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: m.sp4) {
                Text(filename).font(m.font(.body, .semibold)).foregroundStyle(colors.textPrimary)
                    .lineLimit(2).textSelection(.enabled).help(filename)
                HStack(spacing: m.sp8) {
                    Text(attachmentType(filename: filename, mimeType: mimeType, image: image))
                    if let size {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
                    }
                }.font(m.font(.caption)).foregroundStyle(colors.textSecondary)
            }
            Spacer(minLength: 0)
        }.padding(m.sp12).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.canvas, in: RoundedRectangle(cornerRadius: m.radiusLarge))
            .overlay(RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border))
            .accessibilityElement(children: .combine)
    }

    private func attachmentType(filename: String, mimeType: String?, image: Bool) -> String {
        let type =
            mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: (filename as NSString).pathExtension)
        if let type, type != .data, let description = type.localizedDescription { return description }
        return image ? "Image" : "File"
    }

    @MainActor private func loadThumbnail() async {
        thumbnail = nil
        guard current, !matrix.isPreview, queued == nil, let captured = review,
            case .image = captured.value, let source = matrix.attachmentSourceRevision(captured.message)
        else { return }
        let session = matrix.notificationSessionID
        @MainActor func isCurrentThumbnail() -> Bool {
            !Task.isCancelled && current && queued == nil && matrix.notificationSessionID == session
                && review?.id == captured.id && review?.value == captured.value
                && matrix.attachmentSourceRevision(captured.message) == source
        }
        do {
            let data = try await matrix.thumbnailData(captured.message, width: 920, height: 320)
            guard isCurrentThumbnail() else { return }
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard
                    let source = CGImageSourceCreateWithData(
                        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 920,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary)
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
            error =
                "This message is no longer here. Forward it again from the conversation."
        } catch {
            guard !Task.isCancelled, request == token, current, !sending, queued == nil else { return }
            self.error = MatrixService.safeError(error)
        }
    }
    @MainActor private func send() {
        guard canSend, let submitted = review else { return }
        let destination = destinationID
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
                let accepted = try await matrix.forwardMessage(submitted, to: destination)
                // Record the send first so a retry is never offered for it.
                queued = accepted
                sending = false
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
