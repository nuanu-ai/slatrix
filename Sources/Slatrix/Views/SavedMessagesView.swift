import SwiftUI

struct SavedMessagesView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let saved: [SavedMessageReference]
    var onOpen: (SavedMessageReference) -> Void
    var onRemove: (SavedMessageReference) -> Void
    @EnvironmentObject private var appearance: AppearanceStore

    var body: some View {
        Group {
            if saved.isEmpty {
                EmptyStateView(symbol: "bookmark", title: "Nothing saved for later")
            } else {
                ScrollView {
                    LazyVStack(spacing: m.sp2) {
                        ForEach(saved.sorted { $0.savedAt > $1.savedAt }) { reference in
                            SavedMessageRow(
                                matrix: matrix, reference: reference, onOpen: { onOpen(reference) },
                                onRemove: { onRemove(reference) })
                        }
                    }.padding(.horizontal, m.sp12).padding(.vertical, m.sp4)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(appearance.colors.canvas)
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

    /// Where it was said: the channel, or a direct message.
    private var location: String {
        guard let room else { return "Conversation unavailable" }
        return room.isDirect ? "Direct message" : "#\(room.name)"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: m.sp12) {
                AvatarView(name: message?.senderName ?? "", size: m.avatar, matrix: matrix, source: message?.avatarURL)
                    .padding(.top, m.sp16 + m.sp2)
                VStack(alignment: .leading, spacing: m.sp2) {
                    Text(location).font(m.font(.subheadline, .semibold)).foregroundStyle(colors.textSecondary)
                        .lineLimit(1).frame(height: m.sp16)
                    HStack(alignment: .firstTextBaseline, spacing: m.sp8) {
                        Text(message?.senderName ?? "Placeholder name").font(m.font(.reading, .semibold))
                            .foregroundStyle(colors.textPrimary)
                        Text(
                            message?.timestamp ?? reference.savedAt,
                            format: .dateTime.month(.abbreviated).day().hour().minute()
                        ).font(m.font(.subheadline)).foregroundStyle(colors.textSecondary)
                    }.lineLimit(1)
                    content
                }
                // Room for the actions that show on hover, so they never cover the text.
                .padding(.trailing, m(120)).frame(maxWidth: .infinity, alignment: .leading)
            }
            // Until the message arrives, its outline holds the row's place.
            .redacted(reason: message == nil && error == nil ? .placeholder : [])
            .padding(m.sp12)
            .background(hovered ? colors.hover : .clear, in: RoundedRectangle(cornerRadius: m.radius))
            .contentShape(Rectangle())
        }.buttonStyle(.row).disabled(room?.membership != "join")
            .onHover { hovered = $0 }
            .overlay(alignment: .topTrailing) {
                if hovered {
                    ToolbarCapsule {
                        IconButton(symbol: "checkmark", label: "Remove from Later", role: .body, action: onRemove)
                    }.padding(.trailing, m.sp12).padding(.top, m.sp12)
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
                    Label(attachment.name, systemImage: "paperclip").font(m.font(.subheadline))
                        .foregroundStyle(colors.textSecondary).lineLimit(1)
                }
            }
        } else if let error {
            HStack(spacing: m.sp8) {
                Text(error).foregroundStyle(colors.textSecondary)
                Button("Retry") { retry = UUID() }.buttonStyle(.textLink)
            }.font(m.font(.subheadline))
        } else {
            Text("Placeholder for the message while it loads").font(m.font(.reading))
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
