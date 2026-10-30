import SwiftUI

struct SavedMessagesView: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let saved: [SavedMessageReference]
    var onOpen: (SavedMessageReference) -> Void
    var onRemove: (SavedMessageReference) -> Void
    var onOpenProfile: (String, ChatUser?) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var refresh = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: m.sp8) {
                Spacer()
                Text("\(saved.count) \(saved.count == 1 ? "message" : "messages")").font(m.font(.caption))
                    .foregroundStyle(appearance.colors.textSecondary)
                IconButton(symbol: "arrow.clockwise", label: "Refresh", role: .body) { refresh = UUID() }
            }.padding(.horizontal, m.sp24).frame(height: m.control + m.sp16)
            Divider().overlay(appearance.colors.border)
            if saved.isEmpty {
                EmptyStateView(symbol: "bookmark", title: "Nothing saved for later")
            } else {
                ScrollView {
                    LazyVStack(spacing: m.sp16) {
                        ForEach(saved.sorted { $0.savedAt > $1.savedAt }) { reference in
                            SavedMessageCard(
                                matrix: matrix, reference: reference, refresh: refresh, onOpen: { onOpen(reference) },
                                onRemove: { onRemove(reference) }, onOpenProfile: onOpenProfile)
                        }
                    }.padding(m.sp24)
                }
            }
        }.background(appearance.colors.canvas)
    }
}

private struct SavedMessageCard: View {
    @Environment(\.metrics) private var m
    let matrix: MatrixService
    let reference: SavedMessageReference
    let refresh: UUID
    var onOpen: () -> Void
    var onRemove: () -> Void
    var onOpenProfile: (String, ChatUser?) -> Void
    @EnvironmentObject private var appearance: AppearanceStore
    @State private var message: ChatMessage?
    @State private var loading = true
    @State private var error: String?
    @State private var retry = UUID()
    private var colors: AppColors { appearance.colors }
    private var room: ChatRoom? { matrix.rooms.first { $0.id == reference.roomID } }

    var body: some View {
        VStack(alignment: .leading, spacing: m.sp16) {
            HStack(spacing: m.sp8) {
                Image(
                    systemName: room?.isDirect == true
                        ? "bubble.left.and.bubble.right" : room?.channelSymbol ?? "number"
                ).font(
                    m.font(.caption))
                Text(room?.name ?? "Conversation unavailable").font(m.font(.meta, .semibold)).lineLimit(1)
                Spacer()
                IconButton(symbol: "bookmark.fill", label: "Remove from Later", role: .body, action: onRemove)
            }.foregroundStyle(colors.textSecondary)
            if let message {
                HStack(alignment: .top, spacing: m.sp12) {
                    Button {
                        profile(message)
                    } label: {
                        AvatarView(name: message.senderName, size: m.avatar, matrix: matrix, source: message.avatarURL)
                    }.buttonStyle(.row).help("View profile")
                    VStack(alignment: .leading, spacing: m.sp8) {
                        HStack(spacing: m.sp8) {
                            Button {
                                profile(message)
                            } label: {
                                Text(message.senderName).font(m.font(.secondary, .semibold))
                            }.buttonStyle(.row)
                            Text(message.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute()).font(
                                m.font(.caption)
                            ).foregroundStyle(colors.textSecondary)
                            if message.isEdited {
                                Text("edited").font(m.font(.caption)).foregroundStyle(colors.textSecondary)
                            }
                        }
                        if message.isRedacted {
                            Text("This message was deleted.").italic().foregroundStyle(colors.textSecondary)
                        } else {
                            NativeMessageBody(
                                body: message.body, formattedBody: message.formattedBody, showsSpoilerControl: false
                            ).lineLimit(6)
                            if let attachment = message.attachment {
                                Label(attachment.name, systemImage: "paperclip").font(m.font(.meta))
                                    .foregroundStyle(colors.textSecondary).lineLimit(1)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if loading {
                HStack(spacing: m.sp8) {
                    DelayedProgress()
                    Text("Loading…").font(m.font(.meta)).foregroundStyle(colors.textSecondary)
                }.padding(.vertical, m.sp12)
            } else {
                HStack(alignment: .top, spacing: m.sp8) {
                    Image(systemName: "exclamationmark.bubble").foregroundStyle(colors.textSecondary)
                    VStack(alignment: .leading, spacing: m.sp4) {
                        Text(error ?? "Preview unavailable").font(m.font(.secondary, .medium))
                        Button("Retry") { retry = UUID() }.buttonStyle(.textLink).font(m.font(.caption))
                    }
                }.padding(.vertical, m.sp8)
            }
            HStack {
                Text("Saved \(reference.savedAt.formatted(.dateTime.month(.abbreviated).day()))").font(
                    m.font(.caption)
                ).foregroundStyle(colors.textSecondary)
                Spacer()
                Button(action: onOpen) {
                    HStack(spacing: m.sp8) {
                        Text("Open")
                        Image(systemName: "arrow.up.right").font(m.font(.caption, .semibold))
                    }.font(m.font(.meta, .semibold)).foregroundStyle(colors.accent)
                }.buttonStyle(.row).disabled(room?.membership != "join")
            }
        }.padding(m.sp20).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.raised, in: RoundedRectangle(cornerRadius: m.radiusLarge)).overlay(
                RoundedRectangle(cornerRadius: m.radiusLarge).stroke(colors.border)
            )
            .task(id: refresh.uuidString + retry.uuidString) { await load() }
            .onDisappear {
                message = nil
                error = nil
                loading = true
            }
    }

    private func profile(_ message: ChatMessage) {
        onOpenProfile(
            message.senderID, ChatUser(id: message.senderID, name: message.senderName, avatarURL: message.avatarURL))
    }
    private func load() async {
        loading = true
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
            loading = false
        } catch {
            guard !Task.isCancelled else { return }
            self.error = MatrixService.safeError(error)
            loading = false
        }
    }
}
