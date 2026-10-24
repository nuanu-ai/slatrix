import SwiftUI

struct ReplyPreviewView: View {
    @Environment(\.metrics) private var m
    @ObservedObject var matrix: MatrixService
    let message: ChatMessage
    let preview: ChatReplyPreview
    let origin: MessageActionTarget?
    var onOpen: ((String) -> Void)?
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        HStack(spacing: m.sp8) {
            RoundedRectangle(cornerRadius: 2).fill(appearance.colors.muted.opacity(0.4)).frame(width: 3)
            if preview.state == .ready {
                Button {
                    onOpen?(preview.eventID)
                } label: {
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(preview.senderName).font(m.font(.caption, .semibold)).lineLimit(1)
                        Text(preview.body).font(m.font(.meta)).foregroundStyle(appearance.colors.muted).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.row).disabled(onOpen == nil).help("Show original message")
            } else {
                if preview.state == .pending { ProgressView().controlSize(.mini) }
                Text(preview.state == .failed ? "Original message unavailable" : "Loading…").font(
                    m.font(.meta)
                ).foregroundStyle(appearance.colors.muted)
                if preview.state == .failed {
                    Button("Retry") { [target = origin] in
                        guard let target else { return }
                        Task { await matrix.loadReplyPreview(for: target) }
                    }.buttonStyle(.link).font(m.font(.caption)).disabled(origin == nil)
                }
                Spacer(minLength: 0)
            }
        }.padding(.vertical, m.sp4).padding(.bottom, m.sp4).fixedSize(horizontal: false, vertical: true)
            .task(id: origin?.replyPreviewIdentity) { [target = origin] in
                guard !Task.isCancelled, preview.state == .unavailable, let target else { return }
                // SDK Pending replaces the row identity and cancels this view
                // task. Let the captured request finish so a thrown SDK error
                // can still replace Pending, even when no terminal diff arrives.
                Task { await matrix.loadReplyPreview(for: target) }
            }
    }
}
