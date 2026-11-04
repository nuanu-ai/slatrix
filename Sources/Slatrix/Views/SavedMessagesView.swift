import SwiftUI

struct SavedMessagesView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let saved: [SavedMessageReference]
    var onOpen: (SavedMessageReference) -> Void
    var onRemove: (SavedMessageReference) -> Void
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("\(saved.count) \(saved.count == 1 ? "message" : "messages")").font(m.font(.caption))
                    .foregroundStyle(appearance.colors.textSecondary)
            }.padding(.horizontal, m.sp24).frame(height: m.control + m.sp16)
            Divider().overlay(appearance.colors.border)
            if saved.isEmpty {
                EmptyStateView(symbol: "bookmark", title: "Nothing saved for later")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(saved.sorted { $0.savedAt > $1.savedAt }) { reference in
                            SavedMessageRow(
                                matrix: matrix, reference: reference, onOpen: { onOpen(reference) },
                                onRemove: { onRemove(reference) })
                            Divider().overlay(appearance.colors.border)
                        }
                    }
                }
            }
        }.background(appearance.colors.canvas)
    }
}

/// One saved message, laid out like Slack's Later: the conversation, then the message; a click anywhere opens it.
private struct SavedMessageRow: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let reference: SavedMessageReference
    var onOpen: () -> Void
    var onRemove: () -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var message: ChatMessage?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var hovered = false
    private var colors: AppColors { appearance.colors }
    private var room: ChatRoom? { matrix.rooms.first { $0.id == reference.roomID } }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: m.sp8) {
                HStack(spacing: m.sp4) {
                    Image(
                        systemName: room?.isDirect == true
                            ? "bubble.left.and.bubble.right" : room?.channelSymbol ?? "number")
                    Text(room?.name ?? "Conversation unavailable").lineLimit(1)
                }.font(m.font(.caption, .semibold)).foregroundStyle(colors.textSecondary)
                HStack(alignment: .top, spacing: m.sp12) {
                    AvatarView(
                        name: message?.senderName ?? "", size: m.avatar, matrix: matrix, source: message?.avatarURL)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        HStack(spacing: m.sp8) {
                            Text(message?.senderName ?? "Placeholder name").font(m.font(.secondary, .semibold))
                                .foregroundStyle(colors.textPrimary)
                            Text(
                                message?.timestamp ?? reference.savedAt,
                                format: .dateTime.month(.abbreviated).day().hour().minute()
                            ).font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                        }
                        content
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                // Until the message arrives, its outline holds the row's place.
                .redacted(reason: message == nil && error == nil ? .placeholder : [])
            }.padding(.horizontal, m.sp24).padding(.vertical, m.sp12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? colors.hover : .clear)
        }.buttonStyle(.row).disabled(room?.membership != "join")
            .onHover { hovered = $0 }
            .overlay(alignment: .topTrailing) {
                if hovered {
                    IconButton(symbol: "bookmark.fill", label: "Remove from Later", role: .body, action: onRemove)
                        .padding(.trailing, m.sp16).padding(.top, m.sp8)
                }
            }
            .accessibilityAction(named: "Remove from Later", onRemove)
            .task(id: retry) { await load() }
            .onDisappear {
                message = nil
                error = nil
            }
    }

    @ViewBuilder private var content: some View {
        if let message {
            if message.isRedacted {
                Text("This message was deleted.").italic().foregroundStyle(colors.textSecondary)
            } else {
                // A text view keeps clicks for selecting; here a click anywhere opens the message, as in Slack.
                NativeMessageBody(body: message.body, formattedBody: message.formattedBody, showsSpoilerControl: false)
                    .lineLimit(3).allowsHitTesting(false)
                if let attachment = message.attachment {
                    Label(attachment.name, systemImage: "paperclip").font(m.font(.meta))
                        .foregroundStyle(colors.textSecondary).lineLimit(1)
                }
            }
        } else if let error {
            HStack(spacing: m.sp8) {
                Text(error).foregroundStyle(colors.textSecondary)
                Button("Retry") { retry = UUID() }.buttonStyle(.textLink)
            }.font(m.font(.meta))
        } else {
            Text("Placeholder for the message while it loads").font(m.font(.body))
        }
    }

    private func load() async {
        error = nil
        message = nil
        do {
            let current: ChatMessage
            if matrix.isPreview {
                guard
                    let sample = (matrix.messages + matrix.threadMessages).first(where: {
                        $0.roomID == reference.roomID && $0.eventID == reference.eventID
                    })
                else { throw MatrixServiceError.noRoom }
                current = sample
            } else {
                current = try await matrix.messagePreview(roomID: reference.roomID, eventID: reference.eventID)
            }
            guard !Task.isCancelled else { return }
            message = current
        } catch {
            guard !Task.isCancelled else { return }
            self.error = MatrixService.safeError(error)
        }
    }
}
