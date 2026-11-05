import SwiftUI

struct ReplyPreviewView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let message: ChatMessage
    let preview: ChatReplyPreview
    let origin: MessageActionTarget?
    var onOpen: ((String) -> Void)?
    var onOpenThread: ((ChatMessage) -> Void)?
    @EnvironmentObject private var appearance: AppearanceStore
    /// The thread a channel's copy of a thread reply came from; nil while it loads.
    @State private var thread: (root: ChatMessage, preview: String)?
    /// A message that only looked like a copy: its quote isn't in a thread.
    @State private var notInThread = false

    var body: some View {
        HStack(spacing: m.sp8) {
            RoundedRectangle(cornerRadius: m(2)).fill(appearance.colors.textSecondary.opacity(0.4)).frame(width: m(3))
            // Every state takes the loaded preview's two lines, so the row keeps its height when the original lands.
            ZStack(alignment: .leading) {
                lines(sender: " ", body: " ").hidden()
                if message.repliedToThread && !notInThread {
                    // Slack's copy of a thread reply names its thread instead of quoting the same words.
                    Button {
                        if let thread { onOpenThread?(thread.root) }
                    } label: {
                        VStack(alignment: .leading, spacing: m.sp4) {
                            Text("replied to a thread:").font(m.font(.subheadline))
                                .foregroundStyle(appearance.colors.textSecondary)
                            Text(thread?.preview ?? " ").font(m.font(.subheadline, .medium))
                                .foregroundStyle(appearance.colors.accent)
                        }.lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.row).disabled(thread == nil || onOpenThread == nil).help("View thread")
                } else if preview.state == .ready {
                    Button {
                        onOpen?(preview.eventID)
                    } label: {
                        lines(sender: preview.senderName, body: preview.body).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).contentShape(Rectangle())
                    }.buttonStyle(.row).disabled(onOpen == nil).help("Show original message")
                } else if preview.state == .failed {
                    HStack(spacing: m.sp8) {
                        Text("Original message unavailable").font(m.font(.subheadline))
                            .foregroundStyle(appearance.colors.textSecondary)
                        Button("Retry") { [target = origin] in
                            guard let target else { return }
                            Task { await matrix.loadReplyPreview(for: target) }
                        }.buttonStyle(.textLink).font(m.font(.subheadline)).disabled(origin == nil)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .loadingInterval(.replyLoading, while: preview.state == .pending)
        }.padding(.vertical, m.sp4).padding(.bottom, m.sp4).fixedSize(horizontal: false, vertical: true)
            .task(id: origin?.replyPreviewIdentity) { [target = origin] in
                guard !Task.isCancelled, preview.state == .unavailable, let target else { return }
                // SDK Pending replaces the row identity and cancels this view
                // task. Let the captured request finish so a thrown SDK error
                // can still replace Pending, even when no terminal diff arrives.
                Task { await matrix.loadReplyPreview(for: target) }
            }
            .task(id: message.repliedToThread ? preview.eventID : nil) {
                guard message.repliedToThread else { return }
                let found = await matrix.threadOrigin(roomID: message.roomID, replyID: preview.eventID)
                guard !Task.isCancelled else { return }
                thread = found
                notInThread = found == nil
            }
    }

    private func lines(sender: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: m.sp4) {
            Text(sender).font(m.font(.subheadline, .semibold)).lineLimit(1)
            Text(body).font(m.font(.subheadline)).foregroundStyle(appearance.colors.textSecondary).lineLimit(1)
        }
    }
}
