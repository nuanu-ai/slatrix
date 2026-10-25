import SwiftUI

struct ReplyPreviewView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let message: ChatMessage
    let preview: ChatReplyPreview
    let origin: MessageActionTarget?
    var onOpen: ((String) -> Void)?
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        HStack(spacing: m.sp8) {
            RoundedRectangle(cornerRadius: 2).fill(appearance.colors.muted.opacity(0.4)).frame(width: 3)
            // Every state takes the loaded preview's two lines, so the row keeps its height when the original lands.
            ZStack(alignment: .leading) {
                lines(sender: " ", body: " ").hidden()
                if preview.state == .ready {
                    Button {
                        onOpen?(preview.eventID)
                    } label: {
                        lines(sender: preview.senderName, body: preview.body).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).contentShape(Rectangle())
                    }.buttonStyle(.row).disabled(onOpen == nil).help("Show original message")
                } else if preview.state == .failed {
                    HStack(spacing: m.sp8) {
                        Text("Original message unavailable").font(m.font(.meta))
                            .foregroundStyle(appearance.colors.muted)
                        Button("Retry") { [target = origin] in
                            guard let target else { return }
                            Task { await matrix.loadReplyPreview(for: target) }
                        }.buttonStyle(.link).font(m.font(.caption)).disabled(origin == nil)
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
    }

    private func lines(sender: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: m.sp4) {
            Text(sender).font(m.font(.caption, .semibold)).lineLimit(1)
            Text(body).font(m.font(.meta)).foregroundStyle(appearance.colors.muted).lineLimit(1)
        }
    }
}
